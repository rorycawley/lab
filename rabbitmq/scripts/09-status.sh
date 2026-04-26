#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-rabbitmq-demo}"

echo "Kubernetes namespace:"
kubectl get namespace "$NAMESPACE" --ignore-not-found

echo
echo "Kubernetes resources:"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl get all -n "$NAMESPACE"
else
  echo "No namespace named $NAMESPACE."
fi

echo
echo "Docker Compose containers:"
docker compose ps -a

echo
echo "Docker volumes:"
docker volume ls --filter name=rabbitmq --format '{{.Name}}'

echo
echo "Docker network:"
docker network ls --filter name=rabbitmq --format '{{.Name}}'

echo
echo "Demo images:"
docker images rabbitmq-demo-publisher  --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedSince}}'
docker images rabbitmq-demo-subscriber --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedSince}}'

echo
echo "Logs directory:"
if [[ -d logs ]]; then
  find logs -maxdepth 2 -type f -print
else
  echo "No logs/ directory."
fi

echo
echo "Port 8080 listener (publisher port-forward):"
lsof -nP -iTCP:8080 -sTCP:LISTEN || true

echo
echo "Port 8081 listener (subscriber port-forward):"
lsof -nP -iTCP:8081 -sTCP:LISTEN || true

echo
echo "Port 5672 listener (RabbitMQ AMQP):"
lsof -nP -iTCP:5672 -sTCP:LISTEN || true

echo
echo "Port 15672 listener (RabbitMQ UI):"
lsof -nP -iTCP:15672 -sTCP:LISTEN || true
