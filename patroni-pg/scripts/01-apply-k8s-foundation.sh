#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/00-namespaces.yaml
kubectl apply -f k8s/01-demo-app-serviceaccount.yaml

echo "Phase 1 Kubernetes foundation applied."

