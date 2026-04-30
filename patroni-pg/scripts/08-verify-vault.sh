#!/usr/bin/env bash
set -euo pipefail

namespace="vault"
pod="vault-0"
token="$(kubectl get secret vault-dev-root-token --namespace "$namespace" -o jsonpath='{.data.token}' | base64 --decode)"

vault_exec() {
  kubectl exec --namespace "$namespace" "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" "$@"
}

kubectl get service vault --namespace "$namespace" >/dev/null
kubectl rollout status statefulset/vault --namespace "$namespace" --timeout=60s >/dev/null
echo "ok: Vault StatefulSet and Service exist"

vault_exec vault status >/tmp/phase3-vault-status.out
grep -q "Initialized.*true" /tmp/phase3-vault-status.out
grep -q "Sealed.*false" /tmp/phase3-vault-status.out
echo "ok: Vault is initialized and unsealed"

if ! vault_exec vault audit list -format=json | grep -q '"file/"'; then
  vault_exec vault audit enable file file_path=stdout >/dev/null
fi
echo "ok: Vault file audit device is enabled"

vault_exec vault token lookup >/dev/null
echo "ok: allowed Vault request succeeded"

if kubectl exec --namespace "$namespace" "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=invalid-token vault token lookup >/tmp/phase3-vault-denied.out 2>/tmp/phase3-vault-denied.err; then
  echo "error: invalid Vault token unexpectedly succeeded"
  exit 1
fi
echo "ok: denied Vault request failed as expected"

sleep 1

logs="$(kubectl logs --namespace "$namespace" "$pod" --tail=200)"
echo "$logs" | grep -q '"type":"request"'
echo "$logs" | grep -q '"type":"response"'
echo "$logs" | grep -q 'permission denied'
echo "$logs" | grep -q 'invalid token'
echo "ok: Vault audit logs include allowed and denied request evidence"

echo "Phase 3 Vault foundation verification passed."
