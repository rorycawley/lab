#!/usr/bin/env bash
# Common helpers sourced by verify and drill scripts.
# Source via:   source "$(dirname "$0")/lib/common.sh"

# Apply a PSA-restricted-conformant Pod for verify/drill tests. Used wherever
# a script needs a short-lived "tester" Pod in the demo namespace under PSA
# enforce=restricted. Without conformant securityContext the API server
# rejects the Pod at admission, so this helper centralises the boilerplate.
#
# Usage:
#   apply_psa_test_pod NAME NAMESPACE LABEL [IMAGE] [UID] [GID]
#
# Args:
#   NAME       — pod name (also used as container name)
#   NAMESPACE  — target namespace
#   LABEL      — value for the app.kubernetes.io/name label
#   IMAGE      — container image (default: busybox:1.36)
#   UID        — runAsUser   (default: 1000)
#   GID        — runAsGroup  (default: same as UID)
#
# Defaults are chosen to satisfy busybox-class tests; pass UID=100 GID=1000
# for the hashicorp/vault image which has its own non-root user.
apply_psa_test_pod() {
  local name="$1"
  local namespace="$2"
  local label="$3"
  local image="${4:-busybox:1.36}"
  local uid="${5:-1000}"
  local gid="${6:-$uid}"

  kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ${label}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: ${uid}
    runAsGroup: ${gid}
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: ${name}
      image: ${image}
      command: ["sh", "-c", "sleep 120"]
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: ${uid}
        runAsGroup: ${gid}
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
      resources:
        requests: { cpu: 25m, memory: 32Mi }
        limits:   { cpu: 100m, memory: 64Mi }
YAML
}
