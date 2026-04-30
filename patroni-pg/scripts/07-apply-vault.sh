#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/00-namespaces.yaml
kubectl apply -f k8s/08-vault-auth-rbac.yaml

if ! kubectl get secret vault-dev-root-token --namespace vault >/dev/null 2>&1; then
  kubectl create secret generic vault-dev-root-token \
    --namespace vault \
    --from-literal=token="root-$(openssl rand -hex 24)"
fi

kubectl apply -f k8s/06-vault-service.yaml
kubectl apply -f k8s/14-vault-tls-proxy-configmap.yaml
kubectl apply -f k8s/07-vault-deployment.yaml

kubectl rollout status deployment/vault --namespace vault --timeout=180s

echo "Phase 3 dev-mode Vault foundation applied."
