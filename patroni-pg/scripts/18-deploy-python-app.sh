#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/10-python-app-deployment.yaml
kubectl apply -f k8s/11-python-app-service.yaml

kubectl rollout restart deployment/python-postgres-demo --namespace demo >/dev/null
kubectl rollout status deployment/python-postgres-demo --namespace demo --timeout=180s

echo "Phase 8 Python app deployed."
