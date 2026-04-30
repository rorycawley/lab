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

vault_read_json() {
  local token="$1"
  local path="$2"
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -- env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$token" \
    vault read -format=json "$path"
}

json_string_field() {
  local field="$1"
  sed -n 's/.*"'$field'": *"\([^"]*\)".*/\1/p' | head -n 1
}

psql_as() {
  local user="$1"
  local password="$2"
  local sql="$3"
  docker compose --env-file .runtime/postgres.env exec -T postgres env \
    PGPASSWORD="$password" \
    PGSSLMODE=verify-full \
    PGSSLROOTCERT=/tls/postgres/ca.crt \
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$user" -d demo_registry -Atc "$sql"
}

expect_sql_success() {
  local label="$1"
  local user="$2"
  local password="$3"
  local sql="$4"
  psql_as "$user" "$password" "$sql" >/dev/null
  echo "ok: $label"
}

expect_sql_failure() {
  local label="$1"
  local user="$2"
  local password="$3"
  local sql="$4"
  if psql_as "$user" "$password" "$sql" >/tmp/phase6-sql.out 2>/tmp/phase6-sql.err; then
    echo "error: $label unexpectedly succeeded"
    cat /tmp/phase6-sql.out
    exit 1
  fi
  echo "ok: $label denied"
}

expect_vault_read_failure() {
  local label="$1"
  local token="$2"
  local path="$3"
  if vault_read_json "$token" "$path" >/tmp/phase6-vault-read.out 2>/tmp/phase6-vault-read.err; then
    echo "error: $label unexpectedly read $path"
    cat /tmp/phase6-vault-read.out
    exit 1
  fi
  echo "ok: $label cannot read $path"
}

vault_root vault secrets list -format=json >/tmp/phase6-secrets-list.json
grep -q '"database/"' /tmp/phase6-secrets-list.json
vault_root vault read database/config/demo-postgres >/dev/null
vault_root vault read database/roles/demo-app-runtime >/dev/null
vault_root vault read database/roles/demo-app-migrate >/dev/null
echo "ok: Vault database secrets engine, connection, and roles exist"

runtime_jwt="$(kubectl create token demo-app --namespace demo --duration=10m)"
migration_jwt="$(kubectl create token demo-migrate --namespace demo --duration=10m)"
runtime_token="$(login_token demo-app "$runtime_jwt")"
migration_token="$(login_token demo-migrate "$migration_jwt")"
echo "ok: runtime and migration identities authenticated to Vault"

runtime_json="$(vault_read_json "$runtime_token" database/creds/demo-app-runtime)"
runtime_user="$(printf '%s\n' "$runtime_json" | json_string_field username)"
runtime_password="$(printf '%s\n' "$runtime_json" | json_string_field password)"
runtime_lease="$(printf '%s\n' "$runtime_json" | json_string_field lease_id)"

if [[ -z "$runtime_user" || -z "$runtime_password" || -z "$runtime_lease" ]]; then
  echo "error: runtime credential response did not include username, password, and lease_id"
  printf '%s\n' "$runtime_json"
  exit 1
fi
echo "ok: runtime identity received leased dynamic PostgreSQL credentials"

expect_vault_read_failure "runtime identity" "$runtime_token" database/creds/demo-app-migrate

expect_sql_success "runtime generated user can INSERT" "$runtime_user" "$runtime_password" \
  "INSERT INTO registry.company (id, name, status) VALUES ('00000000-0000-0000-0000-000000000006', 'Vault Runtime Ltd', 'active') ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, status = EXCLUDED.status;"
expect_sql_success "runtime generated user can SELECT" "$runtime_user" "$runtime_password" \
  "SELECT id FROM registry.company WHERE id = '00000000-0000-0000-0000-000000000006';"
expect_sql_success "runtime generated user can UPDATE" "$runtime_user" "$runtime_password" \
  "UPDATE registry.company SET status = 'inactive' WHERE id = '00000000-0000-0000-0000-000000000006';"
expect_sql_success "runtime generated user can DELETE" "$runtime_user" "$runtime_password" \
  "DELETE FROM registry.company WHERE id = '00000000-0000-0000-0000-000000000006';"
expect_sql_failure "runtime generated user cannot DROP TABLE" "$runtime_user" "$runtime_password" \
  "DROP TABLE registry.company;"
expect_sql_failure "runtime generated user cannot CREATE ROLE" "$runtime_user" "$runtime_password" \
  "CREATE ROLE attacker;"

migration_json="$(vault_read_json "$migration_token" database/creds/demo-app-migrate)"
migration_user="$(printf '%s\n' "$migration_json" | json_string_field username)"
migration_password="$(printf '%s\n' "$migration_json" | json_string_field password)"
migration_lease="$(printf '%s\n' "$migration_json" | json_string_field lease_id)"

if [[ -z "$migration_user" || -z "$migration_password" || -z "$migration_lease" ]]; then
  echo "error: migration credential response did not include username, password, and lease_id"
  printf '%s\n' "$migration_json"
  exit 1
fi
echo "ok: migration identity received leased dynamic PostgreSQL credentials"

expect_vault_read_failure "migration identity" "$migration_token" database/creds/demo-app-runtime

expect_sql_success "migration generated user can create controlled table" "$migration_user" "$migration_password" \
  "CREATE TABLE IF NOT EXISTS registry.phase6_migration_check (id uuid PRIMARY KEY);"
expect_sql_success "migration generated user can clean up controlled table" "$migration_user" "$migration_password" \
  "DROP TABLE registry.phase6_migration_check;"

vault_root vault lease revoke "$runtime_lease" >/dev/null
expect_sql_failure "revoked runtime generated user cannot connect/use old credentials" "$runtime_user" "$runtime_password" \
  "SELECT 1;"

vault_root vault lease revoke "$migration_lease" >/dev/null
expect_sql_failure "revoked migration generated user cannot connect/use old credentials" "$migration_user" "$migration_password" \
  "SELECT 1;"

echo "Phase 6 Vault database secrets verification passed."
