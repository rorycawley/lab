#!/usr/bin/env bash
set -euo pipefail

echo "Verifying Postgres roles, TLS, migration history, and Kubernetes RBAC..."

docker compose exec -T postgres psql \
  "sslmode=verify-full host=localhost port=5432 dbname=appdb user=app_user password=app_password sslrootcert=/certs/ca.crt sslcert=/certs/app.crt sslkey=/certs/app.key" \
  -v ON_ERROR_STOP=1 \
  -c "SELECT current_user, (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()) AS tls;" \
  -c "SELECT id, title, created_by FROM app.todos ORDER BY id;" \
  -c "DO \$\$ BEGIN CREATE TABLE app.app_should_not_create(id bigint); RAISE EXCEPTION 'app_user unexpectedly created table'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'app_user DDL denied as expected'; END \$\$;"

docker compose exec -T postgres psql \
  "sslmode=verify-full host=localhost port=5432 dbname=appdb user=migrator_user password=migrator_password sslrootcert=/certs/ca.crt sslcert=/certs/migrator.crt sslkey=/certs/migrator.key" \
  -v ON_ERROR_STOP=1 \
  -c "SELECT current_user, (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()) AS tls;" \
  -c "SELECT version, applied_by FROM app.schema_migrations ORDER BY version;" \
  -c "DO \$\$ BEGIN CREATE ROLE migrator_should_not_create; RAISE EXCEPTION 'migrator_user unexpectedly created role'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'migrator_user admin action denied as expected'; END \$\$;"

echo "Checking ServiceAccounts cannot read Secrets through the Kubernetes API..."
app_can_read_migrator="$(kubectl -n migrations-demo auth can-i get secret/migrator-db-credentials \
  --as system:serviceaccount:migrations-demo:app || true)"
migrator_can_read_app="$(kubectl -n migrations-demo auth can-i get secret/app-db-credentials \
  --as system:serviceaccount:migrations-demo:migrator || true)"

[[ "$app_can_read_migrator" == "no" ]]
[[ "$migrator_can_read_app" == "no" ]]

echo "Checking the app pod does not mount the migrator Secret..."
kubectl -n migrations-demo get deployment migrations-demo-api -o jsonpath='{.spec.template.spec.volumes[*].secret.secretName}' | grep -q app-db-credentials
if kubectl -n migrations-demo get deployment migrations-demo-api -o jsonpath='{.spec.template.spec.volumes[*].secret.secretName}' | grep -q migrator-db-credentials; then
  echo "app Deployment unexpectedly mounts migrator Secret" >&2
  exit 1
fi

echo "Verification passed."
