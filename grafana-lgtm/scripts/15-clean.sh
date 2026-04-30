#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"
IMAGE_NAMES=("otel-demo-app:demo" "payment-service:demo")
NAMESPACE_DELETE_TIMEOUT_SECONDS=420

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

show_namespace_blockers() {
  echo "Namespace $NAMESPACE is still terminating. Remaining resources:"
  kubectl get all,pvc,ingress,configmap,secret,serviceaccount,role,rolebinding \
    -n "$NAMESPACE" \
    --ignore-not-found 2>/dev/null || true
}

echo "Deleting Kubernetes namespace..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --wait=false

echo "Waiting for Kubernetes namespace deletion..."
for second in $(seq 1 "$NAMESPACE_DELETE_TIMEOUT_SECONDS"); do
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    break
  fi
  if (( second % 15 == 0 )); then
    show_namespace_blockers
  fi
  sleep 1
done

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace $NAMESPACE is still terminating after ${NAMESPACE_DELETE_TIMEOUT_SECONDS}s." >&2
  echo "Check finalizers with: kubectl get namespace $NAMESPACE -o yaml" >&2
  exit 1
fi

echo "Removing local demo application images..."
for image in "${IMAGE_NAMES[@]}"; do
  docker image rm -f "$image" >/dev/null 2>&1 || true
done

echo "Deleting local logs and temporary port-forward logs..."
rm -rf logs
rm -f /tmp/grafana-lgtm-app-port-forward.log /tmp/grafana-lgtm-grafana-port-forward.log

echo "Verifying cleanup..."
assert_empty "Kubernetes namespace $NAMESPACE" "$(kubectl get namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true)"
for image in "${IMAGE_NAMES[@]}"; do
  assert_empty "Docker image $image" "$(docker images "$image" --format '{{.Repository}}:{{.Tag}} {{.ID}}' || true)"
done
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
