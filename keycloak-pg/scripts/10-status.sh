#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak-pg-demo}"
APP_IMAGE="${APP_IMAGE:-keycloak-pg-demo-app}"
PROXY_IMAGE="${PROXY_IMAGE:-keycloak-pg-demo-proxy}"

echo "Kubernetes namespace:"
kubectl get namespace "$NAMESPACE" --ignore-not-found

echo
echo "Kubernetes resources:"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl get all -n "$NAMESPACE"
  echo
  kubectl get secret keycloak-client -n "$NAMESPACE" --ignore-not-found
else
  echo "No namespace named $NAMESPACE."
fi

echo
echo "Docker Compose containers:"
docker compose ps -a

echo
echo "Docker volumes:"
docker volume ls --filter name=keycloak-pg --format '{{.Name}}'

echo
echo "Docker network:"
docker network ls --filter name=keycloak-pg --format '{{.Name}}'

echo
echo "Demo images:"
docker images "$APP_IMAGE" --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedSince}}'
docker images "$PROXY_IMAGE" --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedSince}}'

echo
echo "Logs directory:"
if [[ -d logs ]]; then
  find logs -maxdepth 2 -type f -print
else
  echo "No logs/ directory."
fi

echo
echo "Port 8080 listener (app port-forward):"
lsof -nP -iTCP:8080 -sTCP:LISTEN || true

echo
echo "Port 8180 listener (Keycloak):"
lsof -nP -iTCP:8180 -sTCP:LISTEN || true

echo
echo "Port 6432 listener (PG-JWT proxy):"
lsof -nP -iTCP:6432 -sTCP:LISTEN || true
