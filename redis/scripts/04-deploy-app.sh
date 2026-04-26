#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="redis-demo"

echo "Deploying app..."
kubectl apply -f k8s/02-app-deployment.yaml
kubectl apply -f k8s/03-app-service.yaml

kubectl -n "$NAMESPACE" rollout restart deployment/redis-demo-app
kubectl -n "$NAMESPACE" rollout status deployment/redis-demo-app --timeout=180s
