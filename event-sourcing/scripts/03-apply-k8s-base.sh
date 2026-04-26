#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="event-sourcing-demo"

echo "Applying namespace, database services, and secrets..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-external-event-postgres-service.yaml
kubectl apply -f k8s/02-external-read-postgres-service.yaml
kubectl apply -f k8s/03-db-secret.yaml

echo "Creating Flyway migration ConfigMaps from migrations/..."
kubectl create configmap event-store-flyway-migrations \
  --namespace "$NAMESPACE" \
  --from-file=migrations/event-store \
  --dry-run=client \
  -o yaml | kubectl apply -f -

kubectl create configmap read-store-flyway-migrations \
  --namespace "$NAMESPACE" \
  --from-file=migrations/read-store \
  --dry-run=client \
  -o yaml | kubectl apply -f -
