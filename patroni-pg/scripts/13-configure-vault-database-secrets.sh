#!/usr/bin/env bash
set -euo pipefail

db_namespace="database"
db_pod="postgres-0"
vault_namespace="vault"
vault_pod="vault-0"
vault_token="$(kubectl get secret vault-dev-root-token --namespace "$vault_namespace" -o jsonpath='{.data.token}' | base64 --decode)"

random_password() {
  openssl rand -hex 24
}

vault_exec() {
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$vault_token" "$@"
}

if ! kubectl get secret vault-postgres-admin --namespace "$db_namespace" >/dev/null 2>&1; then
  kubectl create secret generic vault-postgres-admin \
    --namespace "$db_namespace" \
    --from-literal=password="$(random_password)"
fi

vault_db_password="$(kubectl get secret vault-postgres-admin --namespace "$db_namespace" -o jsonpath='{.data.password}' | base64 --decode)"

kubectl exec --namespace "$db_namespace" -i "$db_pod" -- env VAULT_DB_PASSWORD="$vault_db_password" \
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
  connection_url='postgresql://{{username}}:{{password}}@postgres.database.svc.cluster.local:5432/demo_registry?sslmode=disable' \
  username=vault_admin \
  password="$vault_db_password" >/dev/null

vault_exec vault write database/roles/demo-app-runtime \
  db_name=demo-postgres \
  default_ttl=15m \
  max_ttl=1h \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT app_runtime TO "{{name}}";' \
  revocation_statements='REVOKE app_runtime FROM "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' >/dev/null

vault_exec vault write database/roles/demo-app-migrate \
  db_name=demo-postgres \
  default_ttl=10m \
  max_ttl=30m \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT migration_runtime TO "{{name}}";' \
  revocation_statements='REVOKE migration_runtime FROM "{{name}}"; DROP ROLE IF EXISTS "{{name}}";' >/dev/null

echo "Phase 6 Vault database secrets engine configured."
