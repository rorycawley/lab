#!/usr/bin/env bash
set -euo pipefail

echo "Deleting Kubernetes namespace..."
kubectl delete namespace migrations-demo --ignore-not-found=true

echo "Stopping PostgreSQL and removing volumes..."
docker compose down -v --remove-orphans

echo "Removing local images..."
docker image rm -f migrations-demo-api:demo migrations-demo-migrator:demo >/dev/null 2>&1 || true

echo "Removing generated files..."
rm -rf generated logs
find app migrator -name __pycache__ -type d -prune -exec rm -rf {} +

echo "Clean complete."
