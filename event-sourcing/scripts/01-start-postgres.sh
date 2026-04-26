#!/usr/bin/env bash
set -euo pipefail

echo "Starting the two PostgreSQL 18 databases..."
docker compose up -d event-postgres read-postgres

echo "Waiting for event store..."
until docker compose exec -T event-postgres pg_isready -U tasks -d task_events >/dev/null; do
  sleep 1
done

echo "Waiting for read store..."
until docker compose exec -T read-postgres pg_isready -U tasks -d task_read >/dev/null; do
  sleep 1
done

echo "PostgreSQL is ready."
