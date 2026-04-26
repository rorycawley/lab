#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="event-sourcing-demo"

echo "Refreshing Flyway migration ConfigMaps from migrations/..."
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

echo "Deleting old Flyway Jobs if they exist..."
kubectl delete job event-store-db-migration -n "$NAMESPACE" --ignore-not-found=true
kubectl delete job read-store-db-migration -n "$NAMESPACE" --ignore-not-found=true

echo "Running event-store migration..."
kubectl apply -f k8s/04-event-store-flyway-job.yaml
kubectl wait --for=condition=complete job/event-store-db-migration -n "$NAMESPACE" --timeout=180s
kubectl logs job/event-store-db-migration -n "$NAMESPACE"

echo "Running read-store migration..."
kubectl apply -f k8s/05-read-store-flyway-job.yaml
kubectl wait --for=condition=complete job/read-store-db-migration -n "$NAMESPACE" --timeout=180s
kubectl logs job/read-store-db-migration -n "$NAMESPACE"

echo "Flyway migrations completed."
