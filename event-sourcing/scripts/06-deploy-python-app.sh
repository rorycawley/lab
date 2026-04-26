#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="event-sourcing-demo"

echo "Deploying the Python API..."
kubectl apply -f k8s/06-python-app-deployment.yaml
kubectl apply -f k8s/07-python-app-service.yaml
kubectl rollout restart deployment/task-event-sourcing-api -n "$NAMESPACE"
kubectl rollout status deployment/task-event-sourcing-api -n "$NAMESPACE" --timeout=180s
