#!/usr/bin/env bash
set -euo pipefail

vault_namespace="vault"
local_port="${VAULT_LOCAL_PORT:-18200}"
demo_namespace="demo"

echo "Phase 16 IaC drift check."

required_demo_policies=(
  default-deny-all
  allow-dns
  demo-egress-vault
  demo-egress-postgres
  app-ingress-http
)
required_vault_policies=(
  default-deny-all
  allow-dns
  vault-ingress-demo
  vault-egress-apiserver-and-postgres
  vault-injector-webhook
)

missing=()
for policy in "${required_demo_policies[@]}"; do
  if ! kubectl get networkpolicy "$policy" --namespace "$demo_namespace" >/dev/null 2>&1; then
    missing+=("demo/$policy")
  fi
done
for policy in "${required_vault_policies[@]}"; do
  if ! kubectl get networkpolicy "$policy" --namespace "$vault_namespace" >/dev/null 2>&1; then
    missing+=("vault/$policy")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "error: NetworkPolicy drift detected; the following declared policies are missing from the cluster:"
  for entry in "${missing[@]}"; do
    echo "  - $entry"
  done
  echo "Re-apply the manifest with: kubectl apply -f k8s/15-networkpolicies.yaml"
  exit 2
fi
echo "ok: every NetworkPolicy in k8s/15-networkpolicies.yaml is present in the cluster"

if ! kubectl diff -f k8s/15-networkpolicies.yaml >/tmp/phase16-netpol-diff.out 2>&1; then
  if [[ -s /tmp/phase16-netpol-diff.out ]]; then
    echo "error: NetworkPolicy drift detected; live state differs from k8s/15-networkpolicies.yaml:"
    cat /tmp/phase16-netpol-diff.out
    echo "Re-apply with: kubectl apply -f k8s/15-networkpolicies.yaml"
    exit 2
  fi
fi
echo "ok: live NetworkPolicies match k8s/15-networkpolicies.yaml"

if ! command -v terraform >/dev/null; then
  echo "error: terraform is not installed"
  exit 1
fi

if [[ ! -d terraform/.terraform ]]; then
  (cd terraform && terraform init -input=false >/dev/null)
fi

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
  exit 1
fi

export VAULT_ADDR="http://127.0.0.1:${local_port}"
export VAULT_TOKEN="$vault_token"

set +e
(cd terraform && terraform plan -detailed-exitcode -input=false -refresh=true -lock=false) >/tmp/phase16-tfplan.out 2>&1
plan_exit=$?
set -e

case "$plan_exit" in
  0)
    echo "ok: terraform plan reports no Vault configuration drift"
    ;;
  1)
    echo "error: terraform plan errored"
    cat /tmp/phase16-tfplan.out
    exit 1
    ;;
  2)
    echo "error: Vault configuration drift detected by terraform plan."
    echo "Run: make vault-config   # to reconcile to declared state"
    echo "Or:  cd terraform && terraform plan   # to see the drift"
    grep -E "^[~+-]|will be|must be replaced" /tmp/phase16-tfplan.out | head -40 || true
    exit 2
    ;;
  *)
    echo "error: terraform plan exited with unexpected code $plan_exit"
    exit 1
    ;;
esac

echo "Phase 16 IaC drift check passed."
