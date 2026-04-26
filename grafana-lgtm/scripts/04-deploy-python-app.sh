#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

echo "Deploying the OpenTelemetry Python API..."
kubectl apply -f k8s/03-python-app-deployment.yaml
kubectl rollout restart deployment/otel-demo-app -n "$NAMESPACE"
kubectl rollout status deployment/otel-demo-app -n "$NAMESPACE" --timeout=180s

echo "Python API is ready."
