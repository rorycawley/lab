#!/usr/bin/env bash
set -euo pipefail

echo "Starting Keycloak, PostgreSQL, and the PG-JWT proxy via Docker Compose..."
docker compose up -d keycloak postgres pg-jwt-proxy

echo "Waiting for PostgreSQL..."
until docker compose exec -T postgres pg_isready -U pgadmin -d pocdb >/dev/null 2>&1; do
  sleep 1
done

echo "Waiting for Keycloak (this can take 30-60s on first run)..."
deadline=$(( $(date +%s) + 180 ))
# /health/ready lives on the management port (9000) inside the container.
# We probe it via `docker compose exec` so we don't need to publish 9000.
until docker compose exec -T keycloak \
        bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000; printf "GET /health/ready HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3; grep -q "\"status\": \"UP\"" <&3' \
        >/dev/null 2>&1; do
  if (( $(date +%s) > deadline )); then
    echo "Keycloak did not become ready within 180s" >&2
    docker compose logs keycloak | tail -50 >&2
    exit 1
  fi
  sleep 2
done

echo "Services are ready."
echo "  Keycloak admin UI : http://localhost:8180/  (admin/admin)"
echo "  PostgreSQL        : localhost:5432           (pgadmin/pgadminpass)"
echo "  PG-JWT proxy      : localhost:6432           (use a Keycloak JWT as the password)"
