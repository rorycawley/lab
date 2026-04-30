#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

kubectl apply -f k8s/01-python-app.yaml
kubectl apply -f k8s/02-payment-service.yaml
kubectl rollout restart deployment/otel-demo-app deployment/payment-service -n "$NAMESPACE"
kubectl rollout status deployment/payment-service -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/otel-demo-app -n "$NAMESPACE" --timeout=180s
