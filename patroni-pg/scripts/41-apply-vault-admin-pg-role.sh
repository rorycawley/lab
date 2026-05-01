#!/usr/bin/env bash
set -euo pipefail

# Idempotently creates or updates the PostgreSQL `vault_admin` role using the
# password Terraform generated. Invoked by the null_resource.vault_admin_pg_role
# local-exec provisioner via terraform/database.tf, but is also a runnable
# standalone script.
#
# The password is read from VAULT_POSTGRES_PASSWORD in the environment.

if [[ -z "${VAULT_POSTGRES_PASSWORD:-}" ]]; then
  echo "error: VAULT_POSTGRES_PASSWORD must be set"
  exit 1
fi

if [[ ! -f .runtime/postgres.env ]]; then
  echo "error: .runtime/postgres.env not found; run make postgres first"
  exit 1
fi

docker compose --env-file .runtime/postgres.env exec -T postgres env \
  VAULT_DB_PASSWORD="$VAULT_POSTGRES_PASSWORD" \
  psql -v ON_ERROR_STOP=1 \
       -v vault_db_password="$VAULT_POSTGRES_PASSWORD" \
       -U postgres -d demo_registry <<'SQL' >/dev/null
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
-- Required so the Vault revocation_statements can terminate active sessions
-- of generated users before dropping the role. Without this, pg_terminate_backend
-- fails with "permission denied to terminate process" (SQLSTATE 42501) and the
-- role is never dropped, leaving stale credentials valid until manual cleanup.
GRANT pg_signal_backend TO vault_admin;
SQL

echo "vault_admin PostgreSQL role applied with the Terraform-generated password."
