#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak-oidc-demo}"
APP_IMAGE="${APP_IMAGE:-keycloak-oidc-demo-app}"

echo "Kubernetes namespace:"
kubectl get namespace "$NAMESPACE" --ignore-not-found

echo
echo "Kubernetes resources:"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl get all -n "$NAMESPACE"
  echo
  kubectl get secret oidc-client -n "$NAMESPACE" --ignore-not-found
else
  echo "No namespace named $NAMESPACE."
fi

echo
echo "Docker Compose containers:"
docker compose ps -a

echo
echo "Docker volumes:"
docker volume ls --filter name=keycloak-oidc --format '{{.Name}}'

echo
echo "Docker network:"
docker network ls --filter name=keycloak-oidc --format '{{.Name}}'

echo
echo "Demo image:"
docker images "$APP_IMAGE" --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedSince}}'

echo
echo "Logs directory:"
if [[ -d logs ]]; then
  find logs -maxdepth 2 -type f -print
else
  echo "No logs/ directory."
fi

echo
echo "Port 8080 listener (BFF port-forward):"
lsof -nP -iTCP:8080 -sTCP:LISTEN || true

echo
echo "Port 8180 listener (Keycloak):"
lsof -nP -iTCP:8180 -sTCP:LISTEN || true

echo
echo "Port 5432 listener (Postgres):"
lsof -nP -iTCP:5432 -sTCP:LISTEN || true
