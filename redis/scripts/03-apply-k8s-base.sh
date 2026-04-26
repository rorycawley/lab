#!/usr/bin/env bash
set -euo pipefail

echo "Applying namespace and ExternalName service..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-external-redis-service.yaml
