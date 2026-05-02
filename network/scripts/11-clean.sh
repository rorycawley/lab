#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-network-zero-trust-app:demo}"
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

echo "Deleting Kubernetes namespaces..."
kubectl delete namespace network-alpha network-beta --ignore-not-found=true

echo "Waiting for namespace deletion..."
for ns in network-alpha network-beta; do
  for _ in $(seq 1 60); do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
done

echo "Removing local demo image..."
docker image rm -f "$IMAGE" >/dev/null 2>&1 || true

echo "Deleting generated certs and logs..."
rm -rf generated logs
rm -f /tmp/network-zero-trust-pf.log

echo "Verifying cleanup..."
assert_empty "namespace network-alpha" "$(kubectl get namespace network-alpha --ignore-not-found 2>/dev/null || true)"
assert_empty "namespace network-beta" "$(kubectl get namespace network-beta --ignore-not-found 2>/dev/null || true)"
assert_empty "Docker image $IMAGE" "$(docker images "$IMAGE" --format '{{.Repository}}:{{.Tag}} {{.ID}}' || true)"

if [[ -d generated || -d logs ]]; then
  echo "Cleanup verification failed: generated/ or logs/ still exists" >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  exit 1
fi

echo "Cleanup complete. Demo runtime state is gone."
