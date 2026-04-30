#!/usr/bin/env bash
set -euo pipefail

namespace="vault"

kubectl apply -f k8s/00-namespaces.yaml
kubectl apply -f k8s/01-demo-app-serviceaccount.yaml
kubectl apply -f k8s/08-vault-auth-rbac.yaml

kubectl apply -f k8s/07-vault-deployment.yaml
kubectl rollout status deployment/vault --namespace "$namespace" --timeout=180s

token="$(kubectl get secret vault-dev-root-token --namespace "$namespace" -o jsonpath='{.data.token}' | base64 --decode)"
pod="$(kubectl get pod --namespace "$namespace" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"

vault_exec() {
  kubectl exec --namespace "$namespace" "$pod" -- env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$token" "$@"
}

if ! vault_exec vault auth list -format=json | grep -q '"kubernetes/"'; then
  vault_exec vault auth enable kubernetes >/dev/null
fi

vault_exec vault write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}" \
  disable_iss_validation=true >/dev/null

vault_exec vault write auth/kubernetes/role/demo-app \
  bound_service_account_names=demo-app \
  bound_service_account_namespaces=demo \
  policies=default \
  ttl=15m >/dev/null

echo "Phase 4 Vault Kubernetes auth configured."
