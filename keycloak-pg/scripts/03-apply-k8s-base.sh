#!/usr/bin/env bash
set -euo pipefail

echo "Applying namespace and ExternalName services for keycloak + pg-proxy..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-external-pg-proxy-service.yaml
kubectl apply -f k8s/02-external-keycloak-service.yaml
