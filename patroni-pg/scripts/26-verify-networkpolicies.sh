#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

demo_namespace="demo"
vault_namespace="vault"
test_pod="netpol-denied-test"

cleanup() {
  kubectl delete pod "$test_pod" --namespace "$demo_namespace" \
    --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Phase 12 NetworkPolicy verification."

required_demo_policies=(
  default-deny-all
  allow-dns
  demo-egress-vault
  demo-egress-postgres
  app-ingress-http
)
for policy in "${required_demo_policies[@]}"; do
  kubectl get networkpolicy "$policy" --namespace "$demo_namespace" >/dev/null
done

required_vault_policies=(
  default-deny-all
  allow-dns
  vault-ingress-demo
  vault-egress-apiserver-and-postgres
  vault-injector-webhook
)
for policy in "${required_vault_policies[@]}"; do
  kubectl get networkpolicy "$policy" --namespace "$vault_namespace" >/dev/null
done
echo "ok: all required NetworkPolicies are installed in demo and vault"

app_pod="$(kubectl get pod --namespace "$demo_namespace" \
  -l app.kubernetes.io/name=python-postgres-demo \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl wait --for=condition=Ready "pod/$app_pod" \
  --namespace "$demo_namespace" --timeout=120s >/dev/null
echo "ok: Python app Pod is still Ready under NetworkPolicy"

kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- \
  test -f /vault/secrets/db-creds
echo "ok: Vault Agent sidecar still renders /vault/secrets/db-creds"

kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- python -c '
import json
import urllib.request

with urllib.request.urlopen("http://127.0.0.1:8080/db-identity", timeout=10) as response:
    payload = json.loads(response.read().decode())
assert payload["current_user"].startswith("v-"), payload
print(payload["current_user"])
' | grep -q '^v-'
echo "ok: app still reaches PostgreSQL with Vault-issued runtime credentials"

postgres_host_ip="$(kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- \
  python -c 'import socket; print(socket.gethostbyname("host.rancher-desktop.internal"))')"

apply_psa_test_pod "$test_pod" "$demo_namespace" netpol-denied-test
kubectl wait --for=condition=Ready "pod/$test_pod" \
  --namespace "$demo_namespace" --timeout=60s >/dev/null

kubectl exec --namespace "$demo_namespace" "$test_pod" -- \
  nslookup vault.vault.svc.cluster.local >/dev/null
echo "ok: denied test Pod can resolve cluster DNS (proves later denials are L4, not DNS)"

if kubectl exec --namespace "$demo_namespace" "$test_pod" -- \
  sh -c 'nc -z -w 3 vault.vault.svc.cluster.local 8200' >/dev/null 2>&1; then
  echo "error: Pod without the demo's part-of label unexpectedly reached Vault:8200"
  exit 1
fi
echo "ok: Pod without the demo's part-of label cannot reach Vault:8200"

if kubectl exec --namespace "$demo_namespace" "$test_pod" -- \
  sh -c "nc -z -w 3 ${postgres_host_ip} 5432" >/dev/null 2>&1; then
  echo "error: Pod that is not python-postgres-demo unexpectedly reached PostgreSQL:5432"
  exit 1
fi
echo "ok: Pod that is not python-postgres-demo cannot reach PostgreSQL:5432"

echo "Phase 12 NetworkPolicy verification passed."
