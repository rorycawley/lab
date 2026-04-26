#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="rabbitmq-demo"

echo "Verifying namespace and deployments..."
kubectl get namespace "$NAMESPACE" >/dev/null
kubectl -n "$NAMESPACE" get deployment publisher >/dev/null
kubectl -n "$NAMESPACE" get deployment subscriber >/dev/null

echo "Verifying publisher pod is Ready..."
kubectl wait --for=condition=Ready pod -l app=publisher -n "$NAMESPACE" --timeout=120s

echo "Verifying subscriber pod is Ready..."
kubectl wait --for=condition=Ready pod -l app=subscriber -n "$NAMESPACE" --timeout=120s

echo "Verify passed."
