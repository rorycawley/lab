#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="registry-poc"

echo "Testing Kubernetes -> event-store PostgreSQL..."
kubectl run pg-event-test \
  -n "$NAMESPACE" \
  --rm -i \
  --restart=Never \
  --image=postgres:16 \
  -- psql "postgresql://registry:registry@external-event-postgres:5432/registry_events" \
  -c "select 'event store reachable' as result;"

echo "Testing Kubernetes -> read-store PostgreSQL..."
kubectl run pg-read-test \
  -n "$NAMESPACE" \
  --rm -i \
  --restart=Never \
  --image=postgres:16 \
  -- psql "postgresql://registry:registry@external-read-postgres:5433/registry_read" \
  -c "select 'read store reachable' as result;"
