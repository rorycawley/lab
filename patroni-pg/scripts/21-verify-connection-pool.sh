#!/usr/bin/env bash
set -euo pipefail

namespace="demo"
selector="app.kubernetes.io/name=python-postgres-demo"
pod="$(kubectl get pod --namespace "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}')"
company_id="00000000-0000-0000-0000-000000000010"

request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  kubectl exec --namespace "$namespace" "$pod" -c app -- python -c '
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

json_field() {
  local field="$1"
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    data = data[part]
print(data)
' "$field"
}

before="$(request GET /pool/status)"
echo "$before" >/tmp/phase10-pool-before.json

grep -q '"pool_enabled":true' /tmp/phase10-pool-before.json
grep -q '"current_user":"v-' /tmp/phase10-pool-before.json

max_lifetime="$(json_field pool_max_lifetime_seconds </tmp/phase10-pool-before.json)"
generation_before="$(json_field pool_generation </tmp/phase10-pool-before.json)"

if (( max_lifetime >= 900 )); then
  echo "error: expected pool max lifetime below the 15 minute Vault runtime default TTL"
  cat /tmp/phase10-pool-before.json
  exit 1
fi
echo "ok: pool is enabled and max lifetime is below Vault runtime TTL"

request POST /companies "{\"id\":\"$company_id\",\"name\":\"Phase 10 Pool Ltd\",\"status\":\"active\"}" | grep -q "$company_id"
request GET "/companies/$company_id" | grep -q "Phase 10 Pool Ltd"
request DELETE "/companies/$company_id" | grep -q '"deleted":true'
echo "ok: pooled app connections can perform CRUD"

after_reload="$(request POST /pool/reload '{}')"
echo "$after_reload" >/tmp/phase10-pool-after.json
generation_after="$(json_field pool_generation </tmp/phase10-pool-after.json)"

if (( generation_after <= generation_before )); then
  echo "error: expected pool generation to increase after reload"
  cat /tmp/phase10-pool-before.json
  cat /tmp/phase10-pool-after.json
  exit 1
fi
echo "ok: app can rebuild the connection pool from the rendered credential file"

request GET /db-identity | grep -q '"current_user":"v-'
echo "ok: app still connects with Vault-generated credentials after pool rebuild"

echo "Phase 10 connection pool verification passed."
