#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="openbao-demo"

echo "Verifying namespace, secret, and deployment..."
kubectl get namespace "$NAMESPACE" >/dev/null
kubectl get secret openbao-approle -n "$NAMESPACE" >/dev/null
kubectl get deployment openbao-demo-app -n "$NAMESPACE" >/dev/null

echo "Verifying app pod is Ready..."
kubectl wait --for=condition=Ready pod \
  -l app=openbao-demo-app \
  -n "$NAMESPACE" \
  --timeout=120s

echo "Verify passed."
