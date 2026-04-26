#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-external-event-postgres-service.yaml
kubectl apply -f k8s/02-external-read-postgres-service.yaml
kubectl apply -f k8s/03-db-secret.yaml
kubectl apply -f k8s/04-event-store-flyway-migrations-configmap.yaml
kubectl apply -f k8s/05-read-store-flyway-migrations-configmap.yaml

echo "Base Kubernetes resources applied."
