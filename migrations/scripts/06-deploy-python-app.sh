#!/usr/bin/env bash
set -euo pipefail

echo "Deploying Python API..."
kubectl apply -f k8s/30-app-deployment.yaml
kubectl apply -f k8s/31-app-service.yaml
kubectl -n migrations-demo rollout status deployment/migrations-demo-api --timeout=120s

