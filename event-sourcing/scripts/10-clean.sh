#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="event-sourcing-demo"
IMAGE_NAME="task-event-sourcing-api:demo"
PROJECT_NAME="event-sourcing"

failures=0

assert_empty() {
  local description="$1"
  local output="$2"
  if [[ -n "$output" ]]; then
    echo "Cleanup verification failed: $description remains:" >&2
    echo "$output" >&2
    failures=$((failures + 1))
  fi
}

echo "Deleting Kubernetes namespace..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

echo "Waiting for Kubernetes namespace deletion..."
for _ in $(seq 1 60); do
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "Stopping Docker Compose databases and removing volumes..."
docker compose down -v --remove-orphans

echo "Removing local demo application image..."
docker image rm -f "$IMAGE_NAME" >/dev/null 2>&1 || true

echo "Deleting local logs..."
rm -rf logs
rm -f /tmp/event-sourcing-port-forward.log

echo "Verifying cleanup..."
assert_empty "Kubernetes namespace $NAMESPACE" "$(kubectl get namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true)"
assert_empty "Docker Compose containers for $PROJECT_NAME" "$(docker compose ps -a --format json 2>/dev/null | sed '/^$/d' || true)"
assert_empty "Docker volumes for $PROJECT_NAME" "$(docker volume ls --filter "name=${PROJECT_NAME}" --format '{{.Name}}' || true)"
assert_empty "Docker network for $PROJECT_NAME" "$(docker network ls --filter "name=${PROJECT_NAME}" --format '{{.Name}}' || true)"
assert_empty "Docker image $IMAGE_NAME" "$(docker images "$IMAGE_NAME" --format '{{.Repository}}:{{.Tag}} {{.ID}}' || true)"
if [[ -d logs ]]; then
  echo "Cleanup verification failed: logs/ still exists" >&2
  failures=$((failures + 1))
fi
if [[ -e /tmp/event-sourcing-port-forward.log ]]; then
  echo "Cleanup verification failed: /tmp/event-sourcing-port-forward.log still exists" >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  exit 1
fi

echo "Cleanup complete. Demo runtime state is gone."
