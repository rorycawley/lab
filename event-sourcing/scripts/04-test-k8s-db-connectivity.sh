#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="event-sourcing-demo"

echo "Testing Kubernetes connectivity to Docker Compose PostgreSQL..."
kubectl run postgres-connectivity-check \
  --namespace "$NAMESPACE" \
  --rm \
  -i \
  --restart=Never \
  --image=postgres:18 \
  --env PGPASSWORD=tasks \
  --command -- sh -c '
    set -eu
    psql -h external-event-postgres -p 5432 -U tasks -d task_events -c "select current_database() as event_store;"
    psql -h external-read-postgres -p 5433 -U tasks -d task_read -c "select current_database() as read_store;"
  '
