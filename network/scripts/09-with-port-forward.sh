#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-network-alpha}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
APP_URL="${APP_URL:-https://localhost:${LOCAL_PORT}}"
IMAGE="${IMAGE:-network-zero-trust-app:demo}"
PF_LOG="${PF_LOG:-/tmp/network-zero-trust-pf.log}"

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
  rm -f "$PF_LOG"
}
trap cleanup EXIT

rm -f "$PF_LOG"
kubectl -n "$NAMESPACE" port-forward service/alpha-app "${LOCAL_PORT}:8443" >"$PF_LOG" 2>&1 &
PIDS+=("$!")

echo "Waiting for port-forward..."
ready=0
for _ in $(seq 1 60); do
  if curl -kfsS "$APP_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "Port-forward did not become ready." >&2
  echo "--- port-forward log ---" >&2
  cat "$PF_LOG" >&2 || true
  exit 1
fi

APP_URL="$APP_URL" IMAGE="$IMAGE" ./scripts/08-test.sh
