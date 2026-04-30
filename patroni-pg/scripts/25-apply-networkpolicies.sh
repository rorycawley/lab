#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/15-networkpolicies.yaml

kubectl wait --for=condition=Ready pod \
  --selector=app.kubernetes.io/name=python-postgres-demo \
  --namespace demo --timeout=120s >/dev/null

kubectl wait --for=condition=Ready pod \
  --selector=app.kubernetes.io/name=vault \
  --namespace vault --timeout=120s >/dev/null

echo "Phase 12 NetworkPolicies applied."
