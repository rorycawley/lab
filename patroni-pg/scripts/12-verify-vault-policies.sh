#!/usr/bin/env bash
set -euo pipefail

vault_namespace="vault"
root_token="$(kubectl get secret vault-dev-root-token --namespace "$vault_namespace" -o jsonpath='{.data.token}' | base64 --decode)"
vault_pod="$(kubectl get pod --namespace "$vault_namespace" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"

vault_root() {
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -- env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$root_token" "$@"
}

login_token() {
  local role="$1"
  local jwt="$2"
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -- env VAULT_ADDR=http://127.0.0.1:8201 \
    vault write -field=token "auth/kubernetes/login" role="$role" jwt="$jwt"
}

capabilities() {
  local token="$1"
  local path="$2"
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -- env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$token" \
    vault token capabilities "$path"
}

expect_caps() {
  local label="$1"
  local token="$2"
  local path="$3"
  local expected="$4"

  capabilities "$token" "$path" >/tmp/phase5-caps.out
  if grep -qx "$expected" /tmp/phase5-caps.out; then
    echo "ok: $label has capabilities [$expected] on $path"
  else
    echo "error: $label expected capabilities [$expected] on $path"
    cat /tmp/phase5-caps.out
    exit 1
  fi
}

expect_read_denied() {
  local label="$1"
  local token="$2"
  local path="$3"

  if kubectl exec --namespace "$vault_namespace" "$vault_pod" -- env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$token" \
    vault read "$path" >/tmp/phase5-read.out 2>/tmp/phase5-read.err; then
    echo "error: $label unexpectedly read $path"
    cat /tmp/phase5-read.out
    exit 1
  fi

  echo "ok: $label cannot read $path"
}

kubectl get serviceaccount demo-app --namespace demo >/dev/null
kubectl get serviceaccount demo-migrate --namespace demo >/dev/null
echo "ok: runtime and migration ServiceAccounts exist"

vault_root vault policy read demo-app-runtime | grep -q 'database/creds/demo-app-runtime'
vault_root vault policy read demo-app-migrate | grep -q 'database/creds/demo-app-migrate'
echo "ok: Vault runtime and migration policies exist"

runtime_jwt="$(kubectl create token demo-app --namespace demo --duration=10m)"
migration_jwt="$(kubectl create token demo-migrate --namespace demo --duration=10m)"

runtime_token="$(login_token demo-app "$runtime_jwt")"
migration_token="$(login_token demo-migrate "$migration_jwt")"
echo "ok: runtime and migration identities authenticated to Vault"

expect_caps "runtime identity" "$runtime_token" "database/creds/demo-app-runtime" "read"
expect_caps "runtime identity" "$runtime_token" "database/creds/demo-app-migrate" "deny"
expect_caps "runtime identity" "$runtime_token" "sys/auth" "deny"
expect_read_denied "runtime identity" "$runtime_token" "sys/auth"

expect_caps "migration identity" "$migration_token" "database/creds/demo-app-migrate" "read"
expect_caps "migration identity" "$migration_token" "database/creds/demo-app-runtime" "deny"
expect_caps "migration identity" "$migration_token" "sys/auth" "deny"
expect_read_denied "migration identity" "$migration_token" "sys/auth"

if login_token demo-migrate "$runtime_jwt" >/tmp/phase5-wrong-role.out 2>/tmp/phase5-wrong-role.err; then
  echo "error: runtime ServiceAccount unexpectedly authenticated as migration role"
  exit 1
fi
echo "ok: runtime ServiceAccount cannot authenticate as migration role"

echo "Phase 5 Vault policy verification passed."
