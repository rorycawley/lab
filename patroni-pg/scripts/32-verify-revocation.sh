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

echo "Phase 15 revocation drill."

# The security claim of "vault lease revoke -prefix" is: every outstanding
# credential of that class stops working. We test that directly: capture the
# current credentials, revoke the prefix, then try the OLD credentials. They
# must be rejected by PostgreSQL. Whether the app's pool flips to a new user
# is an availability concern handled separately.

before_user="$(app_request GET /db-identity | jq -r '.current_user')"
if [[ "$before_user" != v-* ]]; then
  echo "error: pre-revoke user '$before_user' is not a Vault-issued v-... user"
  exit 1
fi

before_creds_file="$(kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- cat /vault/secrets/db-creds)"
before_password="$(grep '^DB_PASSWORD=' <<<"$before_creds_file" | cut -d= -f2-)"
if [[ -z "$before_password" ]]; then
  echo "error: could not read DB_PASSWORD from /vault/secrets/db-creds"
  exit 1
fi
echo "ok: pre-revoke user is $before_user"

app_request POST /companies '{"id":"00000000-0000-0000-0000-000000000033","name":"Phase 15 Revoke","status":"active"}' >/dev/null
app_request DELETE /companies/00000000-0000-0000-0000-000000000033 >/dev/null
echo "ok: pre-revoke CRUD works"

before="$(audit_log_size)"
# -sync waits for revocation_statements to finish; without it Vault queues the
# revoke and returns immediately, and any failure inside the SQL (e.g.
# pg_terminate_backend permission denied) is silently swallowed.
vault_exec vault lease revoke -sync -prefix database/creds/demo-app-runtime >/dev/null
echo "ok: vault lease revoke -sync -prefix database/creds/demo-app-runtime issued"

authenticated=true
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if OLD_USER="$before_user" OLD_PASS="$before_password" \
    kubectl exec --stdin --namespace "$demo_namespace" "$app_pod" -c app -- \
      env OLD_USER="$before_user" OLD_PASS="$before_password" python -c '
import os, psycopg
conn = psycopg.connect(
    host="host.rancher-desktop.internal",
    port=5432,
    dbname="demo_registry",
    user=os.environ["OLD_USER"],
    password=os.environ["OLD_PASS"],
    sslmode="verify-full",
    sslrootcert="/etc/postgres-ca/ca.crt",
    connect_timeout=5,
)
conn.close()
' >/tmp/phase15-revoke-old.out 2>&1; then
    sleep 2
    continue
  fi
  authenticated=false
  break
done

if $authenticated; then
  echo "error: old credentials still authenticate to PostgreSQL after prefix-revoke (waited 20s)"
  cat /tmp/phase15-revoke-old.out
  exit 1
fi
echo "ok: pre-revoke credentials no longer authenticate to PostgreSQL"

# Recovery: leave the app in a healthy state for the next drill.
# Vault Agent in the app pod will detect the dead lease and re-render the
# credential file with a fresh user. Poll /pool/reload + /db-identity until a
# DIFFERENT v-... user appears. If Vault Agent doesn't re-render fast enough,
# rollout-restart the app deployment to force a fresh sidecar render.
recovered=false
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  app_request POST /pool/reload '{}' >/dev/null 2>&1 || true
  sleep 2
  current_identity="$(app_request GET /db-identity 2>/dev/null || true)"
  current_user="$(jq -r '.current_user // ""' <<<"$current_identity" 2>/dev/null || true)"
  if [[ "$current_user" == v-* && "$current_user" != "$before_user" ]]; then
    recovered=true
    break
  fi
done

if ! $recovered; then
  echo "warning: app pool did not auto-recover within 30s; rolling out the deployment"
  kubectl rollout restart deployment/python-postgres-demo --namespace "$demo_namespace" >/dev/null
  kubectl rollout status  deployment/python-postgres-demo --namespace "$demo_namespace" --timeout=180s >/dev/null
  app_init "$demo_namespace"
  app_pod="$APP_POD"
  current_user=""
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    current_identity="$(app_request GET /db-identity 2>/dev/null || true)"
    current_user="$(jq -r '.current_user // ""' <<<"$current_identity" 2>/dev/null || true)"
    if [[ "$current_user" == v-* ]]; then
      break
    fi
    sleep 3
  done
fi

if [[ "$current_user" != v-* ]]; then
  echo "error: app did not recover with a Vault-issued user (got '$current_user')"
  exit 1
fi
echo "ok: app recovered as new user $current_user"

kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
  sh -ec "tail -c +$((before + 1)) /vault/audit/audit.log" \
  | grep -E 'sys/leases/revoke-prefix|database/creds/demo-app-runtime' >"$audit_dir/16-revocation.log" || true

if [[ ! -s "$audit_dir/16-revocation.log" ]]; then
  echo "error: revocation drill found no prefix-revoke entries in the Vault on-disk audit log"
  exit 1
fi
echo "ok: revocation event captured in $audit_dir/16-revocation.log"

echo "Phase 15 revocation drill passed."
