#!/usr/bin/env bash
set -euo pipefail

echo "Applying namespace and ExternalName services for postgres + openbao..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-external-postgres-service.yaml
kubectl apply -f k8s/02-external-openbao-service.yaml
