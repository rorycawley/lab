#!/usr/bin/env bash
set -euo pipefail

vault_namespace="vault"
demo_namespace="demo"

kubectl get crd certificates.cert-manager.io >/dev/null
kubectl get clusterissuer demo-ca >/dev/null
kubectl wait --for=condition=Ready certificate/vault-tls --namespace vault --timeout=120s >/dev/null
kubectl wait --for=condition=Ready certificate/postgres-tls --namespace database --timeout=120s >/dev/null
echo "ok: cert-manager issued Vault and PostgreSQL certificates"

kubectl get secret vault-tls --namespace vault -o jsonpath='{.data.ca\.crt}' | grep -q .
kubectl get secret postgres-tls --namespace database -o jsonpath='{.data.ca\.crt}' | grep -q .
echo "ok: issued certificate Secrets include CA material"

vault_pod="$(kubectl get pod --namespace "$vault_namespace" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"

kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
  sh -ec 'VAULT_ADDR=https://vault.vault.svc.cluster.local:8200 VAULT_CACERT=/vault/tls/ca.crt vault status >/dev/null'
echo "ok: Vault HTTPS endpoint verifies with the cert-manager CA"

if kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
  sh -ec 'VAULT_ADDR=https://vault.vault.svc.cluster.local:8200 VAULT_SKIP_VERIFY=false vault status >/dev/null' 2>/tmp/phase11-vault-no-ca.err; then
  echo "error: Vault HTTPS verification unexpectedly worked without a trusted CA"
  exit 1
fi
echo "ok: Vault HTTPS endpoint requires the demo CA to verify"

docker compose --env-file .runtime/postgres.env exec -T postgres env \
  PGPASSWORD="$(sed -n 's/^POSTGRES_PASSWORD=//p' .runtime/postgres.env)" \
  PGSSLMODE=verify-full \
  PGSSLROOTCERT=/tls/postgres/ca.crt \
  psql -h 127.0.0.1 -U postgres -d demo_registry -Atc "SHOW ssl;" | grep -qx "on"
echo "ok: PostgreSQL accepts verify-full TLS connections"

if docker compose --env-file .runtime/postgres.env exec -T postgres env \
  PGPASSWORD="$(sed -n 's/^POSTGRES_PASSWORD=//p' .runtime/postgres.env)" \
  PGSSLMODE=disable \
  psql -h 127.0.0.1 -U postgres -d demo_registry -Atc "SELECT 1;" >/tmp/phase11-plain-postgres.out 2>/tmp/phase11-plain-postgres.err; then
  echo "error: plaintext PostgreSQL connection unexpectedly succeeded"
  exit 1
fi
echo "ok: PostgreSQL rejects plaintext TCP connections"

app_pod="$(kubectl get pod --namespace "$demo_namespace" -l app.kubernetes.io/name=python-postgres-demo -o jsonpath='{.items[0].metadata.name}')"
kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- test -f /etc/postgres-ca/ca.crt
kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- python -c '
import json
import urllib.request

with urllib.request.urlopen("http://127.0.0.1:8080/pool/status", timeout=10) as response:
    payload = json.loads(response.read().decode())
assert payload["sslmode"] == "verify-full", payload
print(payload["current_user"])
' | grep -q '^v-'
echo "ok: Python app uses verify-full PostgreSQL TLS with Vault-generated credentials"

echo "Phase 11 TLS verification passed."
