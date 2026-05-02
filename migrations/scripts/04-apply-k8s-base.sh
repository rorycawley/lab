#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${CERT_DIR:-generated/certs}"

if [[ ! -f "$CERT_DIR/ca.crt" ]]; then
  echo "Missing $CERT_DIR/ca.crt; run make postgres first" >&2
  exit 1
fi

echo "Applying namespace, ServiceAccounts, ExternalName Service, and NetworkPolicies..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-serviceaccounts.yaml
kubectl apply -f k8s/02-external-postgres-service.yaml
kubectl apply -f k8s/10-network-policies.yaml

echo "Applying distinct database Secrets..."
kubectl -n migrations-demo create secret generic postgres-ca \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n migrations-demo create secret generic app-db-credentials \
  --from-literal=database_url='postgresql://app_user:app_password@external-pg:55432/appdb?sslmode=verify-full&sslrootcert=/var/run/postgres-ca/ca.crt&sslcert=/var/run/postgres-client/tls.crt&sslkey=/var/run/postgres-client/tls.key' \
  --from-file=tls.crt="$CERT_DIR/app.crt" \
  --from-file=tls.key="$CERT_DIR/app.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n migrations-demo create secret generic migrator-db-credentials \
  --from-literal=database_url='postgresql://migrator_user:migrator_password@external-pg:55432/appdb?sslmode=verify-full&sslrootcert=/var/run/postgres-ca/ca.crt&sslcert=/var/run/postgres-client/tls.crt&sslkey=/var/run/postgres-client/tls.key' \
  --from-file=tls.crt="$CERT_DIR/migrator.crt" \
  --from-file=tls.key="$CERT_DIR/migrator.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Kubernetes base is ready."

