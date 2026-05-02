#!/usr/bin/env bash
set -euo pipefail

echo "Kubernetes resources:"
kubectl -n migrations-demo get pods,jobs,svc,networkpolicy 2>/dev/null || true

echo
echo "Docker Compose:"
docker compose ps

echo
echo "Images:"
docker image ls migrations-demo-api:demo migrations-demo-migrator:demo 2>/dev/null || true

