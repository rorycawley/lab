#!/usr/bin/env bash
set -euo pipefail

namespace="vault"
token="$(kubectl get secret vault-dev-root-token --namespace "$namespace" -o jsonpath='{.data.token}' | base64 --decode)"
pod="$(kubectl get pod --namespace "$namespace" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"

vault_exec() {
  kubectl exec --namespace "$namespace" "$pod" -- env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$token" "$@"
}

kubectl get service vault --namespace "$namespace" >/dev/null
kubectl rollout status deployment/vault --namespace "$namespace" --timeout=60s >/dev/null
echo "ok: Vault Deployment and Service exist"

vault_exec vault status >/tmp/phase3-vault-status.out
grep -q "Initialized.*true" /tmp/phase3-vault-status.out
grep -q "Sealed.*false" /tmp/phase3-vault-status.out
echo "ok: Vault is initialized and unsealed"

if ! vault_exec vault audit list -format=json | grep -q '"file/"'; then
  vault_exec vault audit enable file file_path=stdout >/dev/null
fi
echo "ok: Vault stdout audit device is enabled"

if ! vault_exec vault audit list -format=json | grep -q '"file_disk/"'; then
  vault_exec vault audit enable -path=file_disk file file_path=/vault/audit/audit.log >/dev/null
fi
echo "ok: Vault on-disk audit device at /vault/audit/audit.log is enabled"

vault_exec vault token lookup >/dev/null
echo "ok: allowed Vault request succeeded"

if kubectl exec --namespace "$namespace" "$pod" -- env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN=invalid-token vault token lookup >/tmp/phase3-vault-denied.out 2>/tmp/phase3-vault-denied.err; then
  echo "error: invalid Vault token unexpectedly succeeded"
  exit 1
fi
echo "ok: denied Vault request failed as expected"

sleep 1

logs="$(kubectl logs --namespace "$namespace" "$pod" --tail=200)"
grep -q '"type":"request"' <<<"$logs"
grep -q '"type":"response"' <<<"$logs"
grep -q 'permission denied' <<<"$logs"
grep -q 'invalid token' <<<"$logs"
echo "ok: Vault audit logs include allowed and denied request evidence"

echo "Phase 3 Vault foundation verification passed."
