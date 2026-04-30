#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/00-namespaces.yaml

helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null

helm upgrade --install vault-agent-injector hashicorp/vault \
  --version 0.32.0 \
  --namespace vault \
  --set server.enabled=false \
  --set csi.enabled=false \
  --set injector.enabled=true \
  --set global.externalVaultAddr=http://vault.vault.svc.cluster.local:8200 \
  --set injector.agentImage.repository=hashicorp/vault \
  --set injector.agentImage.tag=1.17.6 \
  --force-conflicts \
  --wait \
  --timeout 180s

kubectl delete pod vault-injector-smoke --namespace demo --ignore-not-found=true >/dev/null
kubectl apply -f k8s/09-vault-injector-smoke-pod.yaml
kubectl wait --for=condition=Ready pod/vault-injector-smoke --namespace demo --timeout=180s

echo "Phase 7 Vault Agent Injector installed and smoke Pod created."
