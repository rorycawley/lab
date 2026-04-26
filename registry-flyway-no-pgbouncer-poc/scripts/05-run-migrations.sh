#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="registry-poc"

echo "Deleting old Flyway Jobs if they exist..."
kubectl delete job event-store-db-migration -n "$NAMESPACE" --ignore-not-found=true
kubectl delete job read-store-db-migration -n "$NAMESPACE" --ignore-not-found=true

echo "Running event-store migration..."
kubectl apply -f k8s/06-event-store-flyway-job.yaml
kubectl wait --for=condition=complete job/event-store-db-migration -n "$NAMESPACE" --timeout=180s
kubectl logs job/event-store-db-migration -n "$NAMESPACE"

echo "Running read-store migration..."
kubectl apply -f k8s/07-read-store-flyway-job.yaml
kubectl wait --for=condition=complete job/read-store-db-migration -n "$NAMESPACE" --timeout=180s
kubectl logs job/read-store-db-migration -n "$NAMESPACE"

echo "Migrations completed."
