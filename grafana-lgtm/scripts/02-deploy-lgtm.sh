#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

echo "Deploying Grafana LGTM..."
kubectl apply -f k8s/02-grafana-lgtm-deployment.yaml
kubectl rollout restart deployment/grafana-lgtm -n "$NAMESPACE"
kubectl rollout status deployment/grafana-lgtm -n "$NAMESPACE" --timeout=300s

echo "Grafana LGTM is ready."
