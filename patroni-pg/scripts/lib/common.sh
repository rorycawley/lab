#!/usr/bin/env bash
# Common helpers sourced by verify and drill scripts.
# Source via:   source "$(dirname "$0")/lib/common.sh"
#
# After sourcing, callers typically do:
#   vault_init                    # sets VAULT_NS, VAULT_POD, VAULT_TOKEN
#   vault_exec vault status       # exec into the Vault Pod
#   app_init                      # sets APP_NS, APP_POD
#   app_request GET /db-identity  # call the app's localhost endpoint

# --- Vault helpers ---------------------------------------------------------

# Resolve the running Vault Pod and dev root token. Sets VAULT_NS, VAULT_POD,
# VAULT_TOKEN as global variables for subsequent vault_exec / audit_log_*
# calls.
vault_init() {
  VAULT_NS="${1:-vault}"
  VAULT_POD="$(kubectl get pod --namespace "$VAULT_NS" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
  VAULT_TOKEN="$(kubectl get secret vault-dev-root-token --namespace "$VAULT_NS" -o jsonpath='{.data.token}' | base64 --decode)"
  export VAULT_NS VAULT_POD VAULT_TOKEN
}

# Run a `vault` CLI command inside the Vault container as the dev root token.
# Requires vault_init to have run.
vault_exec() {
  kubectl exec --namespace "$VAULT_NS" "$VAULT_POD" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$VAULT_TOKEN" "$@"
}

# Byte size of the on-disk Vault audit log. Used to capture a "before" point
# and then diff with audit_log_diff to extract events emitted by a drill.
audit_log_size() {
  kubectl exec --namespace "$VAULT_NS" "$VAULT_POD" -c vault -- \
    sh -ec 'wc -c </vault/audit/audit.log 2>/dev/null || echo 0' | tr -d '[:space:]'
}

# Print the audit log content emitted since `before` bytes.
audit_log_diff() {
  local before="$1"
  kubectl exec --namespace "$VAULT_NS" "$VAULT_POD" -c vault -- \
    sh -ec "tail -c +$((before + 1)) /vault/audit/audit.log"
}

# --- App helpers -----------------------------------------------------------

# Resolve the running Python app Pod. Sets APP_NS, APP_POD globally.
app_init() {
  APP_NS="${1:-demo}"
  APP_POD="$(kubectl get pod --namespace "$APP_NS" -l app.kubernetes.io/name=python-postgres-demo -o jsonpath='{.items[0].metadata.name}')"
  export APP_NS APP_POD
}

# Call the app's HTTP endpoint via kubectl exec. Prints the response body.
# Throws on non-2xx.
#
# Usage: app_request METHOD PATH [BODY]
app_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  kubectl exec --namespace "$APP_NS" "$APP_POD" -c app -- python -c '
import json
import sys
import urllib.request

method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
data = body.encode() if body else None
headers = {"Content-Type": "application/json"} if body else {}
req = urllib.request.Request(
    "http://127.0.0.1:8080" + path,
    data=data,
    method=method,
    headers=headers,
)
with urllib.request.urlopen(req, timeout=10) as response:
    print(response.read().decode())
' "$method" "$path" "$body"
}

# Same as app_request but never throws — prints just the HTTP status code
# (or "0" on connection error). Used by drills that need to see a specific
# failure response.
app_request_status() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  kubectl exec --namespace "$APP_NS" "$APP_POD" -c app -- python -c '
import sys
import urllib.error
import urllib.request

method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
data = body.encode() if body else None
headers = {"Content-Type": "application/json"} if body else {}
req = urllib.request.Request(
    "http://127.0.0.1:8080" + path,
    data=data,
    method=method,
    headers=headers,
)
try:
    with urllib.request.urlopen(req, timeout=10) as response:
        print(response.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
except Exception:
    print("0")
' "$method" "$path" "$body"
}

# --- PSA test pod helper (existing) ---------------------------------------

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
