#!/usr/bin/env bash
set -euo pipefail

db="demo_registry"
app_user="phase2_app_user"
migration_user="phase2_migration_user"

set -a
source .runtime/postgres.env
set +a

app_password="$PHASE2_APP_PASSWORD"
migration_password="$PHASE2_MIGRATION_PASSWORD"

psql_as() {
  local user="$1"
  local password="$2"
  local sql="$3"

  docker compose --env-file .runtime/postgres.env exec -T postgres env \
    PGPASSWORD="$password" \
    PGSSLMODE=verify-full \
    PGSSLROOTCERT=/tls/postgres/ca.crt \
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$user" -d "$db" -Atc "$sql"
}

expect_success() {
  local label="$1"
  local user="$2"
  local password="$3"
  local sql="$4"

  psql_as "$user" "$password" "$sql" >/dev/null
  echo "ok: $label"
}

expect_failure() {
  local label="$1"
  local user="$2"
  local password="$3"
  local sql="$4"

  if psql_as "$user" "$password" "$sql" >/tmp/phase2-denied.out 2>/tmp/phase2-denied.err; then
    echo "error: $label unexpectedly succeeded"
    cat /tmp/phase2-denied.out
    exit 1
  fi

  echo "ok: $label denied"
}

docker compose --env-file .runtime/postgres.env exec -T postgres pg_isready -U postgres >/dev/null
echo "ok: PostgreSQL is running and ready"

expect_success "app_runtime can INSERT" "$app_user" "$app_password" \
  "INSERT INTO registry.company (id, name, status) VALUES ('00000000-0000-0000-0000-000000000001', 'Acme Ltd', 'active') ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, status = EXCLUDED.status;"

expect_success "app_runtime can SELECT" "$app_user" "$app_password" \
  "SELECT id FROM registry.company WHERE id = '00000000-0000-0000-0000-000000000001';"

expect_success "app_runtime can UPDATE" "$app_user" "$app_password" \
  "UPDATE registry.company SET status = 'inactive' WHERE id = '00000000-0000-0000-0000-000000000001';"

expect_success "app_runtime can DELETE" "$app_user" "$app_password" \
  "DELETE FROM registry.company WHERE id = '00000000-0000-0000-0000-000000000001';"

expect_failure "app_runtime cannot DROP TABLE" "$app_user" "$app_password" \
  "DROP TABLE registry.company;"

expect_failure "app_runtime cannot CREATE TABLE" "$app_user" "$app_password" \
  "CREATE TABLE registry.bad_idea (id uuid);"

expect_failure "app_runtime cannot CREATE ROLE" "$app_user" "$app_password" \
  "CREATE ROLE attacker;"

expect_failure "app_runtime cannot CREATE DATABASE" "$app_user" "$app_password" \
  "CREATE DATABASE attacker_db;"

expect_success "migration_runtime can create controlled migration table" "$migration_user" "$migration_password" \
  "CREATE TABLE IF NOT EXISTS registry.phase2_migration_check (id uuid PRIMARY KEY);"

expect_success "migration_runtime can clean up controlled migration table" "$migration_user" "$migration_password" \
  "DROP TABLE registry.phase2_migration_check;"

echo "Phase 2 PostgreSQL permission verification passed."
