#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f generated/certs/ca.crt || ! -f generated/certs/postgres.crt || ! -f generated/certs/app.crt || ! -f generated/certs/migrator.crt ]]; then
  ./scripts/01-generate-certs.sh
else
  echo "Using existing certificates in generated/certs"
fi

echo "Starting PostgreSQL with TLS required..."
docker compose up -d postgres

echo "Waiting for PostgreSQL..."
for _ in {1..60}; do
  if docker compose exec -T postgres pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    echo "PostgreSQL is ready on localhost:55432"
    exit 0
  fi
  sleep 1
done

docker compose logs postgres
echo "PostgreSQL did not become ready" >&2
exit 1
