#!/usr/bin/env bash
set -euo pipefail

docker compose up -d

echo "Waiting for event-store PostgreSQL..."
until docker exec registry-event-postgres pg_isready -U registry -d registry_events >/dev/null 2>&1; do
  sleep 1
done

echo "Waiting for read-store PostgreSQL..."
until docker exec registry-read-postgres pg_isready -U registry -d registry_read >/dev/null 2>&1; do
  sleep 1
done

echo "Both PostgreSQL containers are ready."
echo "Event store: postgresql://registry:registry@localhost:5432/registry_events"
echo "Read store:  postgresql://registry:registry@localhost:5433/registry_read"
