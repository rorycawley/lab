#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="openbao-demo"

echo "Deploying the OpenBao demo API..."
kubectl apply -f k8s/03-app-deployment.yaml
kubectl apply -f k8s/04-app-service.yaml
kubectl rollout restart deployment/openbao-demo-app -n "$NAMESPACE"
kubectl rollout status deployment/openbao-demo-app -n "$NAMESPACE" --timeout=180s
