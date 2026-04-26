#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="keycloak-pg-demo"

echo "Verifying namespace, secret, and deployment..."
kubectl get namespace "$NAMESPACE" >/dev/null
kubectl get secret keycloak-client -n "$NAMESPACE" >/dev/null
kubectl get deployment keycloak-pg-demo-app -n "$NAMESPACE" >/dev/null

echo "Verifying the app Deployment is Available..."
kubectl wait --for=condition=Available deployment/keycloak-pg-demo-app \
  -n "$NAMESPACE" \
  --timeout=120s

echo "Verifying the PG-JWT proxy container is running..."
docker compose ps pg-jwt-proxy --format json | grep -q '"State":"running"' \
  || { echo "pg-jwt-proxy is not running"; docker compose logs pg-jwt-proxy | tail -30; exit 1; }

echo "Verify passed."
