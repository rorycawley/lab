#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/08-python-app-deployment.yaml
kubectl apply -f k8s/09-python-app-service.yaml
kubectl rollout status deployment/registry-python-app -n registry-poc --timeout=180s

echo "Python app deployed."
echo "Run this in a separate terminal to access it:"
echo "  kubectl port-forward -n registry-poc svc/registry-python-app 8080:8080"
