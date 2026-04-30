#!/usr/bin/env bash
set -euo pipefail

decode_secret_key() {
  local namespace="$1"
  local secret="$2"
  local key="$3"
  local destination="$4"

  local escaped_key="${key//./\\.}"
  kubectl get secret "$secret" --namespace "$namespace" -o "jsonpath={.data.$escaped_key}" | base64 --decode > "$destination"
}

configmap_from_file() {
  local namespace="$1"
  local name="$2"
  local source_file="$3"

  kubectl create configmap "$name" \
    --namespace "$namespace" \
    --from-file=ca.crt="$source_file" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
}

secret_from_file() {
  local namespace="$1"
  local name="$2"
  local source_file="$3"

  kubectl create secret generic "$name" \
    --namespace "$namespace" \
    --from-file=ca.crt="$source_file" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
}

kubectl apply -f k8s/00-namespaces.yaml
kubectl apply -f k8s/12-cert-manager-ca.yaml

kubectl wait --for=condition=Ready clusterissuer/demo-selfsigned-bootstrap --timeout=120s
kubectl wait --for=condition=Ready certificate/demo-root-ca --namespace cert-manager --timeout=120s
kubectl wait --for=condition=Ready clusterissuer/demo-ca --timeout=120s

kubectl apply -f k8s/13-service-certificates.yaml
kubectl wait --for=condition=Ready certificate/vault-tls --namespace vault --timeout=120s
kubectl wait --for=condition=Ready certificate/postgres-tls --namespace database --timeout=120s

mkdir -p .runtime/tls/postgres .runtime/tls/vault

decode_secret_key database postgres-tls ca.crt .runtime/tls/postgres/ca.crt
decode_secret_key database postgres-tls tls.crt .runtime/tls/postgres/tls.crt
decode_secret_key database postgres-tls tls.key .runtime/tls/postgres/tls.key
chmod 0644 .runtime/tls/postgres/ca.crt .runtime/tls/postgres/tls.crt
chmod 0600 .runtime/tls/postgres/tls.key

decode_secret_key vault vault-tls ca.crt .runtime/tls/vault/ca.crt
chmod 0644 .runtime/tls/vault/ca.crt

configmap_from_file demo postgres-ca .runtime/tls/postgres/ca.crt
configmap_from_file vault postgres-ca .runtime/tls/postgres/ca.crt
secret_from_file demo vault-ca .runtime/tls/vault/ca.crt

kubectl apply -f k8s/14-vault-tls-proxy-configmap.yaml

echo "Phase 11 cert-manager certificates issued and exported."
