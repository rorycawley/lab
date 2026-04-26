#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="keycloak-pg-demo"

echo "Deploying the Keycloak demo API..."
kubectl apply -f k8s/03-app-deployment.yaml
kubectl apply -f k8s/04-app-service.yaml
kubectl rollout restart deployment/keycloak-pg-demo-app -n "$NAMESPACE"
kubectl rollout status deployment/keycloak-pg-demo-app -n "$NAMESPACE" --timeout=180s
