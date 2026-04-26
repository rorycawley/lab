#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="redis-demo"

echo "Verifying namespace and deployment..."
kubectl get namespace "$NAMESPACE" >/dev/null
kubectl -n "$NAMESPACE" get deployment redis-demo-app >/dev/null

echo "Verifying app pod is Ready..."
kubectl wait --for=condition=Ready pod -l app=redis-demo-app -n "$NAMESPACE" --timeout=120s

echo "Verify passed."
