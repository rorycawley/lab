#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao-demo}"
IMAGE_NAME="${IMAGE_NAME:-openbao-demo-app}"

echo "Kubernetes namespace:"
kubectl get namespace "$NAMESPACE" --ignore-not-found

echo
echo "Kubernetes resources:"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl get all -n "$NAMESPACE"
  echo
  kubectl get secret openbao-approle -n "$NAMESPACE" --ignore-not-found
else
  echo "No namespace named $NAMESPACE."
fi

echo
echo "Docker Compose containers:"
docker compose ps -a

echo
echo "Docker volumes:"
docker volume ls --filter name=openbao --format '{{.Name}}'

echo
echo "Docker network:"
docker network ls --filter name=openbao --format '{{.Name}}'

echo
echo "Demo image:"
docker images "$IMAGE_NAME" --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedSince}}'

echo
echo "Logs directory:"
if [[ -d logs ]]; then
  find logs -maxdepth 2 -type f -print
else
  echo "No logs/ directory."
fi

echo
echo "Port 8080 listener:"
lsof -nP -iTCP:8080 -sTCP:LISTEN || true

echo
echo "Port 8200 listener (OpenBao):"
lsof -nP -iTCP:8200 -sTCP:LISTEN || true
