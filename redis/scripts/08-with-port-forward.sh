#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-redis-demo}"
APP_URL="${APP_URL:-http://localhost:8080}"
COMMAND="${1:-test}"
PF_LOG="${PF_LOG:-/tmp/redis-demo-pf.log}"

if [[ "$COMMAND" != "test" && "$COMMAND" != "all" ]]; then
  echo "Usage: $0 [test|all]" >&2
  exit 1
fi

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

kubectl -n "$NAMESPACE" port-forward service/redis-demo-app 8080:8080 >"$PF_LOG" 2>&1 &
PIDS+=("$!")

echo "Waiting for port-forward..."
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$APP_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "Port-forward did not become ready." >&2
  echo "--- port-forward log ---" >&2; cat "$PF_LOG" >&2 || true
  exit 1
fi

case "$COMMAND" in
  test|all)
    APP_URL="$APP_URL" ./scripts/07-test.sh
    ;;
esac
