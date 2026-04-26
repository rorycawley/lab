#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="event-sourcing-demo"

echo "Kubernetes resources:"
kubectl get all -n "$NAMESPACE"

echo
echo "Flyway history tables:"
docker compose exec -T event-postgres psql -U tasks -d task_events -c "select installed_rank, version, description, success from flyway_schema_history order by installed_rank;"
docker compose exec -T read-postgres psql -U tasks -d task_read -c "select installed_rank, version, description, success from flyway_schema_history order by installed_rank;"

echo
echo "Event store tables:"
docker compose exec -T event-postgres psql -U tasks -d task_events -c "\dt"

echo
echo "Read store tables:"
docker compose exec -T read-postgres psql -U tasks -d task_read -c "\dt"
