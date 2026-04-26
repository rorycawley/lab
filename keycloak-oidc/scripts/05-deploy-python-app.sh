#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="keycloak-oidc-demo"

echo "Deploying the OIDC BFF demo app..."
kubectl apply -f k8s/03-app-deployment.yaml
kubectl apply -f k8s/04-app-service.yaml
kubectl rollout restart deployment/keycloak-oidc-demo-app -n "$NAMESPACE"
kubectl rollout status deployment/keycloak-oidc-demo-app -n "$NAMESPACE" --timeout=180s
