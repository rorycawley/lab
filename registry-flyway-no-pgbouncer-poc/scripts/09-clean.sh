#!/usr/bin/env bash
set -euo pipefail

kubectl delete namespace registry-poc --ignore-not-found=true
docker compose down -v

echo "Deleted Kubernetes namespace and Docker PostgreSQL volumes."
