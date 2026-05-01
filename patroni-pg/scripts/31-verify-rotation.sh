#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

demo_namespace="demo"
vault_namespace="vault"
audit_dir=".runtime/audit"
mkdir -p "$audit_dir"

vault_init
app_init "$demo_namespace"
vault_pod="$VAULT_POD"
vault_token="$VAULT_TOKEN"
app_pod="$APP_POD"

echo "Phase 15 rotation drill."

if [[ ! -f .runtime/vault-postgres.env ]]; then
  echo "error: .runtime/vault-postgres.env not found; run make vault-db first"
  exit 1
fi

old_password="$(sed -n 's/^VAULT_POSTGRES_PASSWORD=//p' .runtime/vault-postgres.env)"
if [[ -z "$old_password" ]]; then
  echo "error: VAULT_POSTGRES_PASSWORD missing from .runtime/vault-postgres.env"
  exit 1
fi

app_request POST /companies '{"id":"00000000-0000-0000-0000-000000000031","name":"Phase 15 Pre","status":"active"}' >/dev/null
app_request DELETE /companies/00000000-0000-0000-0000-000000000031 >/dev/null
echo "ok: pre-rotation CRUD works"

before="$(audit_log_size)"
vault_exec vault write -force database/rotate-root/demo-postgres >/dev/null
sleep 1
echo "ok: vault wrote -force database/rotate-root/demo-postgres"

if docker compose --env-file .runtime/postgres.env exec -T postgres env \
    PGPASSWORD="$old_password" \
    PGSSLMODE=verify-full \
    PGSSLROOTCERT=/tls/postgres/ca.crt \
    psql -h 127.0.0.1 -U vault_admin -d demo_registry -Atc 'SELECT 1' \
    >/tmp/phase15-rotation-old.out 2>/tmp/phase15-rotation-old.err; then
  echo "error: vault_admin still authenticates with the OLD password after rotate-root"
  cat /tmp/phase15-rotation-old.out
  exit 1
fi
echo "ok: old vault_admin password no longer authenticates to PostgreSQL"

new_creds_json="$(vault_exec vault read -format=json database/creds/demo-app-runtime)"
new_username="$(jq -r '.data.username' <<<"$new_creds_json")"
new_lease="$(jq -r '.lease_id' <<<"$new_creds_json")"
if [[ -z "$new_username" || -z "$new_lease" || "$new_username" == "null" ]]; then
  echo "error: Vault did not issue a new runtime credential after rotation"
  exit 1
fi
vault_exec vault lease revoke "$new_lease" >/dev/null
echo "ok: Vault still issues runtime credentials post-rotation (issued $new_username, then revoked)"

app_request POST /pool/reload '{}' >/dev/null
sleep 1
identity="$(app_request GET /db-identity)"
current_user="$(jq -r '.current_user' <<<"$identity")"
if [[ "$current_user" != v-* ]]; then
  echo "error: app /db-identity returned unexpected user '$current_user'"
  exit 1
fi
echo "ok: app reconnected as $current_user post-rotation"

app_request POST /companies '{"id":"00000000-0000-0000-0000-000000000032","name":"Phase 15 Post","status":"active"}' >/dev/null
app_request GET /companies/00000000-0000-0000-0000-000000000032 | grep -q "Phase 15 Post"
app_request DELETE /companies/00000000-0000-0000-0000-000000000032 >/dev/null
echo "ok: post-rotation CRUD works"

kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
  sh -ec "tail -c +$((before + 1)) /vault/audit/audit.log" \
  | grep -E 'rotate-root|database/config/demo-postgres' >"$audit_dir/15-rotation.log" || true

if [[ ! -s "$audit_dir/15-rotation.log" ]]; then
  echo "error: rotation drill found no rotate-root entry in the Vault on-disk audit log"
  exit 1
fi
echo "ok: rotation event captured in $audit_dir/15-rotation.log"

echo "Phase 15 rotation drill passed."
