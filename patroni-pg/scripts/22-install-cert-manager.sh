#!/usr/bin/env bash
set -euo pipefail

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set installCRDs=true \
  --wait \
  --timeout 240s

kubectl wait --for=condition=Available deployment/cert-manager --namespace cert-manager --timeout=180s
kubectl wait --for=condition=Available deployment/cert-manager-webhook --namespace cert-manager --timeout=180s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector --namespace cert-manager --timeout=180s

echo "Phase 11 cert-manager installed."
