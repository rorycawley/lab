#!/usr/bin/env bash
set -euo pipefail

namespace="demo"
selector="app.kubernetes.io/name=python-postgres-demo"
company_id="00000000-0000-0000-0000-000000000008"

pod="$(kubectl get pod --namespace "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}')"

kubectl wait --for=condition=Ready "pod/$pod" --namespace "$namespace" --timeout=120s >/dev/null
echo "ok: Python app Pod is Ready"

sidecar_count="$(kubectl get pod "$pod" --namespace "$namespace" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep -c '^vault-agent$' || true)"
if [[ "$sidecar_count" != "1" ]]; then
  echo "error: expected Vault Agent sidecar on Python app Pod"
  exit 1
fi
echo "ok: Python app Pod has Vault Agent sidecar"

if kubectl get deployment python-postgres-demo --namespace "$namespace" -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].env[*].name}' | tr ' ' '\n' | grep -qx "DB_PASSWORD"; then
  echo "error: app container environment contains DB_PASSWORD"
  exit 1
fi
echo "ok: app container environment does not contain DB_PASSWORD"

kubectl exec --namespace "$namespace" "$pod" -c app -- test -f /vault/secrets/db-creds
echo "ok: Python app can see rendered credential file"

request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  if [[ -n "$body" ]]; then
    kubectl exec --namespace "$namespace" "$pod" -c app -- python -c '
import json
import sys
import urllib.request

method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(
    "http://127.0.0.1:8080" + path,
    data=body.encode(),
    method=method,
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=10) as response:
    print(response.read().decode())
' "$method" "$path" "$body"
  else
    kubectl exec --namespace "$namespace" "$pod" -c app -- python -c '
import sys
import urllib.request

method, path = sys.argv[1], sys.argv[2]
req = urllib.request.Request("http://127.0.0.1:8080" + path, method=method)
with urllib.request.urlopen(req, timeout=10) as response:
    print(response.read().decode())
' "$method" "$path"
  fi
}

request GET /healthz | grep -q '"ok"'
echo "ok: /healthz works"

request GET /db-identity | grep -q '"current_user":"v-'
echo "ok: app connects with Vault-generated runtime database user"

request POST /companies "{\"id\":\"$company_id\",\"name\":\"Phase 8 Ltd\",\"status\":\"active\"}" | grep -q "$company_id"
echo "ok: app can INSERT company"

request GET "/companies/$company_id" | grep -q "Phase 8 Ltd"
echo "ok: app can SELECT company"

request PATCH "/companies/$company_id" '{"status":"inactive"}' | grep -q "inactive"
echo "ok: app can UPDATE company"

request DELETE "/companies/$company_id" | grep -q '"deleted":true'
echo "ok: app can DELETE company"

request POST /security/prove-denied '{}' | grep -q '"allowed":false'
echo "ok: app proves forbidden DB operations are denied"

echo "Phase 8 Python app verification passed."
