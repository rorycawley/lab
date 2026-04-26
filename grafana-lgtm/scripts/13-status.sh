#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-grafana-lgtm-demo}"
IMAGE_NAME="${IMAGE_NAME:-otel-demo-app}"

echo "Kubernetes namespace:"
kubectl get namespace "$NAMESPACE" --ignore-not-found

echo
echo "Kubernetes resources:"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl get all -n "$NAMESPACE"
  echo
  echo "Recent app logs:"
  kubectl logs -n "$NAMESPACE" deployment/otel-demo-app --tail=30 || true
else
  echo "No namespace named $NAMESPACE."
fi

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
echo "Port 3000 listener:"
lsof -nP -iTCP:3000 -sTCP:LISTEN || true

echo
echo "Port 8080 listener:"
lsof -nP -iTCP:8080 -sTCP:LISTEN || true
