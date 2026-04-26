#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"
IMAGE_NAME="otel-demo-app:demo"

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

echo "Removing local demo application image..."
docker image rm -f "$IMAGE_NAME" >/dev/null 2>&1 || true

echo "Deleting local logs and temporary port-forward logs..."
rm -rf logs
rm -f /tmp/grafana-lgtm-app-port-forward.log /tmp/grafana-lgtm-grafana-port-forward.log

echo "Verifying cleanup..."
assert_empty "Kubernetes namespace $NAMESPACE" "$(kubectl get namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true)"
assert_empty "Docker image $IMAGE_NAME" "$(docker images "$IMAGE_NAME" --format '{{.Repository}}:{{.Tag}} {{.ID}}' || true)"
if [[ -d logs ]]; then
  echo "Cleanup verification failed: logs/ still exists" >&2
  failures=$((failures + 1))
fi
if [[ -e /tmp/grafana-lgtm-app-port-forward.log ]]; then
  echo "Cleanup verification failed: /tmp/grafana-lgtm-app-port-forward.log still exists" >&2
  failures=$((failures + 1))
fi
if [[ -e /tmp/grafana-lgtm-grafana-port-forward.log ]]; then
  echo "Cleanup verification failed: /tmp/grafana-lgtm-grafana-port-forward.log still exists" >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  exit 1
fi

echo "Cleanup complete. Demo runtime state is gone."
