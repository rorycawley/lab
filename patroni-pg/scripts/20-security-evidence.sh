#!/usr/bin/env bash
set -euo pipefail

namespace="demo"
selector="app.kubernetes.io/name=python-postgres-demo"
pod="$(kubectl get pod --namespace "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}')"
vault_pod="$(kubectl get pod --namespace vault -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"

request_app() {
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
    parsed = json.loads(response.read().decode())
print(json.dumps(parsed, indent=2, sort_keys=True))
' "$method" "$path" "$body"
}

echo "== Kubernetes identity =="
kubectl get pod "$pod" --namespace "$namespace" -o jsonpath='pod={.metadata.name} serviceAccount={.spec.serviceAccountName} containers={.spec.containers[*].name} initContainers={.spec.initContainers[*].name}{"\n"}'

echo ""
echo "== App secret surface =="
env_names="$(kubectl get deployment python-postgres-demo --namespace "$namespace" -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].env[*].name}')"
echo "app env names: $env_names"
if tr ' ' '\n' <<<"$env_names" | grep -qx "DB_PASSWORD"; then
  echo "DB_PASSWORD env: present"
else
  echo "DB_PASSWORD env: absent"
fi
kubectl exec --namespace "$namespace" "$pod" -c app -- sh -c 'printf "credential file: "; stat -c "%n mode=%a size=%s" /vault/secrets/db-creds'

echo ""
echo "== Application evidence =="
request_app POST /security/evidence '{}'

echo ""
echo "== Vault audit evidence =="
logs="$(kubectl logs --namespace vault "$vault_pod" --tail=300)"
printf 'kubernetes login audit entries: '
grep -c 'auth/kubernetes/login' <<<"$logs" || true
printf 'runtime credential audit entries: '
grep -c 'database/creds/demo-app-runtime' <<<"$logs" || true
printf 'denied/invalid audit entries: '
grep -Ec 'permission denied|invalid token' <<<"$logs" || true

echo ""
echo "== PostgreSQL runtime =="
docker compose --env-file .runtime/postgres.env ps postgres

echo ""
echo "Evidence command completed."
