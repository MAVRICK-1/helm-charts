#!/bin/bash
# sync-controller-deployment.sh
#
# Fetches the controller manager deployment from the openeverest repo
# and transforms it into a Helm template for the everest-controller component.
#
# Uses the same fetch-and-replace pattern as sync-controller-webhook.sh:
# curl the raw manifest, then sed/awk to apply Helm-specific replacements.
# New upstream fields (args, probes, env, etc.) flow through automatically.
#
# Syncs:
#   config/manager/manager.yaml -> templates/everest-controller/deployment.yaml
#
# Usage:
#   OPENEVEREST_REPO_URL=https://github.com/openeverest/openeverest \
#   OPENEVEREST_VERSION=v2 \
#   OUTPUT_DIR=templates/everest-controller \
#     ./scripts/sync-controller-deployment.sh

set -euo pipefail

OPENEVEREST_REPO_URL="${OPENEVEREST_REPO_URL:?OPENEVEREST_REPO_URL is required}"
OPENEVEREST_VERSION="${OPENEVEREST_VERSION:?OPENEVEREST_VERSION is required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"

RAW_BASE="${OPENEVEREST_REPO_URL/github.com/raw.githubusercontent.com}/${OPENEVEREST_VERSION}"
SRC_URL="${RAW_BASE}/config/manager/manager.yaml"
DEST="${OUTPUT_DIR}/deployment.yaml"

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"

echo "Fetching manager deployment from ${OPENEVEREST_REPO_URL} @ ${OPENEVEREST_VERSION}..."
echo "  Syncing Deployment -> ${DEST}"

curl -sSfL "${SRC_URL}" > "${TMPDIR}/raw.yaml"

# -------------------------------------------------------------------------
# Step 1: Extract only the Deployment document (skip Namespace).
# -------------------------------------------------------------------------
awk 'BEGIN{n=0} /^---$/{n++; next} n==1' "${TMPDIR}/raw.yaml" > "${TMPDIR}/deploy.yaml"

# -------------------------------------------------------------------------
# Step 2: sed — simple text replacements.
#   - Strip TODO/boilerplate comments, annotations, seccompProfile
#   - Rename resources (names, namespace, labels)
#   - Template image and command
# -------------------------------------------------------------------------
sed -i \
    -e '/^      # TODO/d' \
    -e '/^      # Uncomment/d' \
    -e '/^      # according/d' \
    -e '/^      # It is considered/d' \
    -e '/^      # build your/d' \
    -e '/^      # affinity:/d' \
    -e '/^      #   nodeAffinity:/d' \
    -e '/^      #     requiredDuring/d' \
    -e '/^      #       nodeSelectorTerms:/d' \
    -e '/^      #         - matchExpressions:/d' \
    -e '/^      #           - key:/d' \
    -e '/^      #             operator:/d' \
    -e '/^      #             values:/d' \
    -e '/^      #               - /d' \
    -e '/^        # Projects are configured/d' \
    -e '/^        # This ensures/d' \
    -e '/^        # For more details/d' \
    -e '/^        # TODO/d' \
    -e '/^        # More info/d' \
    -e '/^      annotations:/d' \
    -e '/kubectl.kubernetes.io\/default-container/d' \
    -e '/seccompProfile:/d' \
    -e '/^          type: RuntimeDefault/d' \
    -e 's|name: controller-manager$|name: everest-controller|' \
    -e 's|namespace: system|namespace: {{ include "everest.namespace" . }}|' \
    -e 's|control-plane: controller-manager|app: everest-controller|g' \
    -e '/app.kubernetes.io\/name: openeverest/d' \
    -e '/app.kubernetes.io\/managed-by: kustomize/d' \
    -e 's|image: controller:latest|image: {{ (default .Values.server.image .Values.controller.image) }}:{{ .Chart.AppVersion }}|' \
    -e 's|- /everest-controller|- {{ .Values.controller.command }}|' \
    -e 's|serviceAccountName: controller-manager|serviceAccountName: everest-controller-manager|' \
    -e 's|"ALL"|ALL|' \
    "${TMPDIR}/deploy.yaml"

# -------------------------------------------------------------------------
# Step 3: awk — multi-line transformations.
#   Follows upstream field order. Injects Helm-specific additions at the
#   right points. Unknown/new upstream fields pass through unchanged.
# -------------------------------------------------------------------------
awk '
BEGIN { in_args = 0; in_resources = 0 }

# --- Args block ---
# Must be checked first: when in_args is true, we need to detect end-of-block
# before any other rule matches the current line.
in_args {
    # Arg lines have deeper indent (10-space in upstream). Normalize to 8-space
    # and template known args. Unknown args pass through (future-proof).
    if ($0 ~ /^          - --/) {
        if ($0 ~ /--leader-elect/) {
            print "        {{- if .Values.controller.leaderElection.enabled }}"
            print "        - --leader-elect"
            print "        {{- end }}"
        } else if ($0 ~ /--health-probe-bind-address/) {
            print "        - --health-probe-bind-address={{ .Values.controller.healthProbeBindAddress }}"
        } else {
            # New upstream arg — pass through, normalizing indent.
            sub(/^          /, "        ")
            print
        }
        next
    }
    # Current line is NOT an arg — end of args block.
    # Inject Helm-only args before leaving.
    print "        - --metrics-bind-address={{ .Values.controller.metricsBindAddress }}"
    print "        - --webhook-cert-path=/tmp/k8s-webhook-server/serving-certs"
    in_args = 0
    # Fall through to let the current line be handled below.
}

# --- Resources block ---
# Must also be checked early to consume indented child lines.
in_resources {
    if ($0 ~ /^          /) next  # consume limits/requests/etc.
    # End of resources block — inject env support.
    in_resources = 0
    print "        {{- if .Values.controller.env }}"
    print "        env:"
    print "        {{- toYaml .Values.controller.env | nindent 8 }}"
    print "        {{- end }}"
    # Fall through for current line.
}

# Start of args block.
/^        args:$/ {
    in_args = 1
    print
    next
}

# Start of resources block — replace with Helm template.
/^        resources:$/ {
    in_resources = 1
    print "        resources: {{ toYaml .Values.controller.resources | nindent 10 }}"
    next
}

# After image line, inject imagePullPolicy.
/image:.*\.Values\./ {
    print
    print "        imagePullPolicy: IfNotPresent"
    next
}

# Replace empty ports with webhook health port.
/^        ports: \[\]/ {
    print "        ports:"
    print "        - containerPort: 8081"
    print "          name: health"
    print "          protocol: TCP"
    next
}

# After port in httpGet probes, inject scheme.
/^            port: [0-9]+/ {
    print
    print "            scheme: HTTP"
    next
}

# After periodSeconds in probes, inject failureThreshold and timeoutSeconds.
/^          periodSeconds:/ {
    print
    print "          failureThreshold: 3"
    print "          timeoutSeconds: 1"
    next
}

# Replace empty volumeMounts with webhook cert mount.
/^        volumeMounts: \[\]/ {
    print "        volumeMounts:"
    print "        - mountPath: /tmp/k8s-webhook-server/serving-certs"
    print "          name: everest-controller-webhook-server-cert"
    print "          readOnly: true"
    next
}

# Replace empty volumes with webhook cert secret volume.
/^      volumes: \[\]/ {
    print "      volumes:"
    print "      - name: everest-controller-webhook-server-cert"
    print "        secret:"
    print "          secretName: everest-controller-webhook-server-cert"
    next
}

# After replicas, inject revisionHistoryLimit.
/^  replicas:/ {
    print
    print "  revisionHistoryLimit: 1"
    next
}

# Before template, inject strategy.
/^  template:/ {
    print "  strategy:"
    print "    rollingUpdate:"
    print "      maxSurge: 25%"
    print "      maxUnavailable: 25%"
    print "    type: RollingUpdate"
    print
    next
}

# Before serviceAccountName, inject dnsPolicy and restartPolicy.
/^      serviceAccountName:/ {
    print "      dnsPolicy: ClusterFirst"
    print "      restartPolicy: Always"
    print
    next
}

# Default: pass through unchanged.
{ print }
' "${TMPDIR}/deploy.yaml" \
  | { echo '{{- if .Values.controller.enabled }}'; cat; echo '{{- end }}'; } \
  > "${DEST}"

echo ""
echo "Deployment sync complete. File written to ${DEST}."
