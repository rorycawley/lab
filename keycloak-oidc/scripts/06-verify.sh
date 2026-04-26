#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="keycloak-oidc-demo"

echo "Verifying namespace, secret, and deployment..."
kubectl get namespace "$NAMESPACE" >/dev/null
kubectl get secret oidc-client -n "$NAMESPACE" >/dev/null
kubectl get deployment keycloak-oidc-demo-app -n "$NAMESPACE" >/dev/null

echo "Verifying the app Deployment is Available..."
kubectl wait --for=condition=Available deployment/keycloak-oidc-demo-app \
  -n "$NAMESPACE" \
  --timeout=120s

echo "Verifying Keycloak and Postgres containers are running..."
docker compose ps keycloak --format json | grep -q '"State":"running"' \
  || { echo "keycloak is not running"; docker compose logs keycloak | tail -30; exit 1; }
docker compose ps postgres --format json | grep -q '"State":"running"' \
  || { echo "postgres is not running"; docker compose logs postgres | tail -30; exit 1; }

echo "Verify passed."
