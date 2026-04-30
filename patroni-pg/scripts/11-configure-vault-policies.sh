#!/usr/bin/env bash
set -euo pipefail

namespace="vault"
pod="vault-0"
token="$(kubectl get secret vault-dev-root-token --namespace "$namespace" -o jsonpath='{.data.token}' | base64 --decode)"

vault_exec() {
  kubectl exec --namespace "$namespace" "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" "$@"
}

vault_policy_write() {
  local name="$1"
  kubectl exec --namespace "$namespace" -i "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" \
    vault policy write "$name" -
}

kubectl apply -f k8s/01-demo-app-serviceaccount.yaml

cat <<'POLICY' | vault_policy_write demo-app-runtime >/dev/null
path "database/creds/demo-app-runtime" {
  capabilities = ["read"]
}
POLICY

cat <<'POLICY' | vault_policy_write demo-app-migrate >/dev/null
path "database/creds/demo-app-migrate" {
  capabilities = ["read"]
}
POLICY

vault_exec vault write auth/kubernetes/role/demo-app \
  bound_service_account_names=demo-app \
  bound_service_account_namespaces=demo \
  policies=demo-app-runtime \
  ttl=15m >/dev/null

vault_exec vault write auth/kubernetes/role/demo-migrate \
  bound_service_account_names=demo-migrate \
  bound_service_account_namespaces=demo \
  policies=demo-app-migrate \
  ttl=10m >/dev/null

echo "Phase 5 Vault policies configured."

