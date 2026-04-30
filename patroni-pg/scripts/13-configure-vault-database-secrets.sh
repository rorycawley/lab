#!/usr/bin/env bash
set -euo pipefail

vault_namespace="vault"
vault_token="$(kubectl get secret vault-dev-root-token --namespace "$vault_namespace" -o jsonpath='{.data.token}' | base64 --decode)"
vault_pod="$(kubectl get pod --namespace "$vault_namespace" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"

random_password() {
  openssl rand -hex 24
}

vault_exec() {
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -- env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$vault_token" "$@"
}

mkdir -p .runtime

if [[ ! -f .runtime/vault-postgres.env ]]; then
  printf 'VAULT_POSTGRES_PASSWORD=%s\n' "$(random_password)" > .runtime/vault-postgres.env
  chmod 0600 .runtime/vault-postgres.env
fi

set -a
source .runtime/vault-postgres.env
set +a

vault_db_password="$VAULT_POSTGRES_PASSWORD"

docker compose --env-file .runtime/postgres.env exec -T postgres env VAULT_DB_PASSWORD="$vault_db_password" \
  psql -v ON_ERROR_STOP=1 -v vault_db_password="$vault_db_password" -U postgres -d demo_registry <<'SQL' >/dev/null
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vault_admin') THEN
    CREATE ROLE vault_admin WITH LOGIN CREATEROLE;
  END IF;
END
$$;

ALTER ROLE vault_admin WITH LOGIN CREATEROLE PASSWORD :'vault_db_password';
GRANT CONNECT ON DATABASE demo_registry TO vault_admin;
GRANT app_runtime TO vault_admin WITH ADMIN OPTION;
GRANT migration_runtime TO vault_admin WITH ADMIN OPTION;
SQL

if ! vault_exec vault secrets list -format=json | grep -q '"database/"'; then
  vault_exec vault secrets enable database >/dev/null
fi

vault_exec vault write database/config/demo-postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles=demo-app-runtime,demo-app-migrate \
  connection_url='postgresql://{{username}}:{{password}}@host.rancher-desktop.internal:5432/demo_registry?sslmode=verify-full&sslrootcert=/vault/postgres-ca/ca.crt' \
  username=vault_admin \
  password="$vault_db_password" >/dev/null

vault_exec vault write database/roles/demo-app-runtime \
  db_name=demo-postgres \
  default_ttl=15m \
  max_ttl=1h \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT app_runtime TO "{{name}}";' \
  revocation_statements='SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '"'"'{{name}}'"'"'; REVOKE app_runtime FROM "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' >/dev/null

vault_exec vault write database/roles/demo-app-migrate \
  db_name=demo-postgres \
  default_ttl=10m \
  max_ttl=30m \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT migration_runtime TO "{{name}}";' \
  revocation_statements='SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '"'"'{{name}}'"'"'; REVOKE migration_runtime FROM "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' >/dev/null

echo "Phase 6 Vault database secrets engine configured."
