#!/usr/bin/env bash
set -euo pipefail

kubectl delete namespace demo vault database phase4-other --ignore-not-found=true
if [[ -f .runtime/postgres.env ]]; then
  docker compose --env-file .runtime/postgres.env down -v --remove-orphans
else
  docker compose down -v --remove-orphans
fi

rm -rf .runtime/audit

echo "Kubernetes namespaces, Docker Compose state, and audit artifacts removed."
