#!/usr/bin/env bash
set -euo pipefail

echo "Running migration Job..."
kubectl -n migrations-demo delete job db-migrate --ignore-not-found=true
kubectl apply -f k8s/20-migration-job.yaml

kubectl -n migrations-demo wait --for=condition=complete job/db-migrate --timeout=120s
echo "Migration logs:"
kubectl -n migrations-demo logs job/db-migrate

