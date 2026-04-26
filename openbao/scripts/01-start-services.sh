#!/usr/bin/env bash
set -euo pipefail

echo "Starting OpenBao (dev mode) and PostgreSQL via Docker Compose..."
docker compose up -d openbao postgres

echo "Waiting for PostgreSQL..."
until docker compose exec -T postgres pg_isready -U vaultadmin -d pocdb >/dev/null 2>&1; do
  sleep 1
done

echo "Waiting for OpenBao..."
until docker compose exec -T openbao bao status >/dev/null 2>&1; do
  sleep 1
done

echo "Services are ready."
echo "  OpenBao UI:  http://localhost:8200/ui  (root token: root)"
echo "  PostgreSQL:  localhost:5432            (vaultadmin/vaultadminpass)"
