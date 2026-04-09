#!/bin/bash
# sync-controller-deployment.sh
#
# Fetches the controller manager deployment from the openeverest repo
# and generates the Helm deployment template for the everest-controller component.
#
# Structural values (security contexts, probe paths/ports/timing,
# terminationGracePeriodSeconds) are sourced from upstream. Helm-specific
# fields (image, resources, env, args, volumes) are fixed in the template.
#
# Syncs:
#   config/manager/manager.yaml -> templates/everest-controller/deployment.yaml
#
# Usage:
#   OPENEVEREST_REPO_URL=https://github.com/openeverest/openeverest \
#   OPENEVEREST_VERSION=v2 \
#   OUTPUT_DIR=templates/everest-controller \
#     ./scripts/sync-controller-deployment.sh
#
# This script is designed to be called by the helm-charts Makefile's
# `controller-deployment-gen` target.

set -euo pipefail

OPENEVEREST_REPO_URL="${OPENEVEREST_REPO_URL:?OPENEVEREST_REPO_URL is required}"
OPENEVEREST_VERSION="${OPENEVEREST_VERSION:?OPENEVEREST_VERSION is required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"

RAW_BASE="${OPENEVEREST_REPO_URL/github.com/raw.githubusercontent.com}/${OPENEVEREST_VERSION}"

mkdir -p "${OUTPUT_DIR}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

MANAGER_YAML="${WORK_DIR}/manager.yaml"
DEST="${OUTPUT_DIR}/deployment.yaml"

echo "Fetching manager deployment from ${OPENEVEREST_REPO_URL} @ ${OPENEVEREST_VERSION}..."
curl -sSfL "${RAW_BASE}/config/manager/manager.yaml" > "${MANAGER_YAML}"

echo "  Syncing Deployment -> ${DEST}"

python3 - "${MANAGER_YAML}" "${DEST}" <<'PYEOF'
import sys, yaml

src_file  = sys.argv[1]
dest_file = sys.argv[2]

with open(src_file) as f:
    docs = list(yaml.safe_load_all(f))

deployment = next(d for d in docs if d and d.get('kind') == 'Deployment')
spec       = deployment['spec']['template']['spec']
pod_sc     = spec.get('securityContext', {})
container  = next(c for c in spec['containers'] if c['name'] == 'manager')
c_sc       = container.get('securityContext', {})
liveness   = container.get('livenessProbe', {})
readiness  = container.get('readinessProbe', {})

run_as_user    = pod_sc.get('runAsUser', 65532)
term_grace     = spec.get('terminationGracePeriodSeconds', 10)
l_path         = liveness.get('httpGet', {}).get('path', '/healthz')
l_port         = liveness.get('httpGet', {}).get('port', 8081)
l_initial      = liveness.get('initialDelaySeconds', 15)
l_period       = liveness.get('periodSeconds', 20)
r_path         = readiness.get('httpGet', {}).get('path', '/readyz')
r_port         = readiness.get('httpGet', {}).get('port', 8081)
r_initial      = readiness.get('initialDelaySeconds', 5)
r_period       = readiness.get('periodSeconds', 10)
run_as_non_root = str(pod_sc.get('runAsNonRoot', True)).lower()
allow_priv_esc  = str(c_sc.get('allowPrivilegeEscalation', False)).lower()
read_only_root  = str(c_sc.get('readOnlyRootFilesystem', True)).lower()

template = f"""\
{{{{- if .Values.controller.enabled }}}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: everest-controller
  namespace: {{{{ include "everest.namespace" . }}}}
  labels:
    app: everest-controller
spec:
  replicas: 1
  revisionHistoryLimit: 1
  selector:
    matchLabels:
      app: everest-controller
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: everest-controller
    spec:
      containers:
      - name: manager
        image: {{{{ (default .Values.server.image .Values.controller.image) }}}}:{{{{ .Chart.AppVersion }}}}
        imagePullPolicy: IfNotPresent
        command:
        - {{{{ .Values.controller.command }}}}
        args:
        {{{{- if .Values.controller.leaderElection.enabled }}}}
        - --leader-elect
        {{{{- end }}}}
        - --metrics-bind-address={{{{ .Values.controller.metricsBindAddress }}}}
        - --health-probe-bind-address={{{{ .Values.controller.healthProbeBindAddress }}}}
        - --webhook-cert-path=/tmp/k8s-webhook-server/serving-certs
        ports:
        - containerPort: {l_port}
          name: health
          protocol: TCP
        livenessProbe:
          httpGet:
            path: {l_path}
            port: {l_port}
            scheme: HTTP
          initialDelaySeconds: {l_initial}
          periodSeconds: {l_period}
          failureThreshold: 3
          timeoutSeconds: 1
        readinessProbe:
          httpGet:
            path: {r_path}
            port: {r_port}
            scheme: HTTP
          initialDelaySeconds: {r_initial}
          periodSeconds: {r_period}
          failureThreshold: 3
          timeoutSeconds: 1
        resources: {{{{ toYaml .Values.controller.resources | nindent 10 }}}}
        {{{{- if .Values.controller.env }}}}
        env:
        {{{{- toYaml .Values.controller.env | nindent 8 }}}}
        {{{{- end }}}}
        securityContext:
          allowPrivilegeEscalation: {allow_priv_esc}
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: {read_only_root}
        volumeMounts:
        - mountPath: /tmp/k8s-webhook-server/serving-certs
          name: everest-controller-webhook-server-cert
          readOnly: true
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      securityContext:
        runAsNonRoot: {run_as_non_root}
        # 65532 is the standard non-root UID used by distroless/nonroot images.
        # The manager image is built FROM scratch with no USER directive, so it
        # defaults to root (UID 0). Setting runAsUser here explicitly overrides
        # that default to satisfy the runAsNonRoot constraint.
        runAsUser: {run_as_user}
      serviceAccountName: everest-controller-manager
      terminationGracePeriodSeconds: {term_grace}
      volumes:
      - name: everest-controller-webhook-server-cert
        secret:
          secretName: everest-controller-webhook-server-cert
{{{{- end }}}}
"""

with open(dest_file, 'w') as f:
    f.write(template)
PYEOF

echo ""
echo "Deployment sync complete. File written to ${DEST}."
echo "Note: image, resources, env, args, and volumes are Helm-specific"
echo "      and not sourced directly from openeverest — do not remove them."
