#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

vault_init
vault_namespace="$VAULT_NS"
vault_pod="$VAULT_POD"

can_i() {
  kubectl auth can-i "$@" 2>/dev/null || true
}

login_with_jwt() {
  local jwt="$1"
  kubectl exec --namespace "$VAULT_NS" "$VAULT_POD" -- env VAULT_ADDR=http://127.0.0.1:8201 \
    vault write -format=json auth/kubernetes/login role=demo-app jwt="$jwt"
}

expect_login_success() {
  local label="$1"
  local jwt="$2"

  login_with_jwt "$jwt" >/tmp/phase4-login-success.json
  grep -q '"client_token"' /tmp/phase4-login-success.json
  echo "ok: $label authenticated to Vault"
}

expect_login_failure() {
  local label="$1"
  local jwt="$2"

  if login_with_jwt "$jwt" >/tmp/phase4-login-denied.out 2>/tmp/phase4-login-denied.err; then
    echo "error: $label unexpectedly authenticated to Vault"
    cat /tmp/phase4-login-denied.out
    exit 1
  fi

  echo "ok: $label rejected by Vault"
}

kubectl get serviceaccount vault-auth --namespace vault >/dev/null
can_i create tokenreviews.authentication.k8s.io --as system:serviceaccount:vault:vault-auth >/tmp/phase4-tokenreview.out
grep -qx "yes" /tmp/phase4-tokenreview.out
echo "ok: vault/vault-auth can create TokenReview requests"

can_i create tokenreviews.authentication.k8s.io --as system:serviceaccount:demo:demo-app >/tmp/phase4-demo-tokenreview.out
grep -qx "no" /tmp/phase4-demo-tokenreview.out
echo "ok: demo/demo-app does not have TokenReview permission"

vault_exec vault auth list -format=json | grep -q '"kubernetes/"'
echo "ok: Vault Kubernetes auth method is enabled"

vault_exec vault read auth/kubernetes/role/demo-app >/tmp/phase4-role.out
grep -q "bound_service_account_names.*demo-app" /tmp/phase4-role.out
grep -q "bound_service_account_namespaces.*demo" /tmp/phase4-role.out
echo "ok: Vault role is bound to demo/demo-app"

demo_app_jwt="$(kubectl create token demo-app --namespace demo --duration=10m)"
demo_default_jwt="$(kubectl create token default --namespace demo --duration=10m)"

other_namespace="phase4-other"
kubectl create namespace "$other_namespace" >/dev/null 2>&1 || true
kubectl create serviceaccount demo-app --namespace "$other_namespace" >/dev/null 2>&1 || true
other_demo_app_jwt="$(kubectl create token demo-app --namespace "$other_namespace" --duration=10m)"

expect_login_success "demo/demo-app" "$demo_app_jwt"
expect_login_failure "demo/default" "$demo_default_jwt"
expect_login_failure "$other_namespace/demo-app" "$other_demo_app_jwt"

kubectl delete namespace "$other_namespace" --ignore-not-found=true >/dev/null

echo "Phase 4 Vault Kubernetes auth verification passed."
