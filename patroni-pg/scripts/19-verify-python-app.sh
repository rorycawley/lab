#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

namespace="demo"
company_id="00000000-0000-0000-0000-000000000008"

app_init "$namespace"
pod="$APP_POD"

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
  app_request "$@"
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
