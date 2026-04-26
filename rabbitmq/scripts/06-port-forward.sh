#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="rabbitmq-demo"

echo "Forwarding localhost:8080 -> publisher:8080"
echo "Forwarding localhost:8081 -> subscriber:8080"
echo "Press Ctrl+C to stop both."

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" port-forward service/publisher 8080:8080 &
PIDS+=("$!")
kubectl -n "$NAMESPACE" port-forward service/subscriber 8081:8080 &
PIDS+=("$!")

wait
