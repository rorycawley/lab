#!/usr/bin/env bash
set -euo pipefail

vault_namespace="vault"
local_port="${VAULT_LOCAL_PORT:-18200}"
demo_db="${POSTGRES_DATABASE:-demo_registry}"

if ! command -v terraform >/dev/null; then
  echo "error: terraform is not installed; run scripts/38-doctor.sh for the full preflight"
  exit 1
fi

kubectl rollout status deployment/vault --namespace "$vault_namespace" --timeout=120s >/dev/null

vault_token="$(kubectl get secret vault-dev-root-token --namespace "$vault_namespace" -o jsonpath='{.data.token}' | base64 --decode)"

kubectl port-forward --namespace "$vault_namespace" deployment/vault "${local_port}:8201" >/tmp/phase16-pf.log 2>&1 &
pf_pid=$!
cleanup() {
  kill "$pf_pid" >/dev/null 2>&1 || true
  wait "$pf_pid" 2>/dev/null || true
}
trap cleanup EXIT

ready=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if (echo >"/dev/tcp/127.0.0.1/${local_port}") >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if ! $ready; then
  echo "error: kubectl port-forward to vault:8201 did not open localhost:${local_port}"
  cat /tmp/phase16-pf.log >&2 || true
  exit 1
fi

export VAULT_ADDR="http://127.0.0.1:${local_port}"
export VAULT_TOKEN="$vault_token"

(
  cd terraform
  if [[ ! -d .terraform ]]; then
    terraform init -input=false >/dev/null
  fi
  terraform apply -input=false -auto-approve
)

if [[ ! -f .runtime/vault-postgres.env ]]; then
  echo "error: terraform did not produce .runtime/vault-postgres.env"
  exit 1
fi

echo "Phase 16 Vault configuration applied via Terraform."
