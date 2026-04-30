#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/00-namespaces.yaml

random_password() {
  openssl rand -hex 24
}

if ! kubectl get secret postgres-bootstrap --namespace database >/dev/null 2>&1; then
  kubectl create secret generic postgres-bootstrap \
    --namespace database \
    --from-literal=POSTGRES_PASSWORD="$(random_password)" \
    --from-literal=PHASE2_APP_PASSWORD="$(random_password)" \
    --from-literal=PHASE2_MIGRATION_PASSWORD="$(random_password)"
fi

kubectl apply -f k8s/03-postgres-init-configmap.yaml
kubectl apply -f k8s/04-postgres-service.yaml
kubectl apply -f k8s/05-postgres-statefulset.yaml

kubectl rollout status statefulset/postgres --namespace database --timeout=180s

echo "Phase 2 PostgreSQL foundation applied."
