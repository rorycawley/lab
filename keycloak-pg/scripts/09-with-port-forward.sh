#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak-pg-demo}"
APP_URL="${APP_URL:-http://localhost:8080}"
COMMAND="${1:-test}"
PORT_FORWARD_LOG="${PORT_FORWARD_LOG:-/tmp/keycloak-pg-demo-port-forward.log}"

if [[ "$COMMAND" != "test" && "$COMMAND" != "all" ]]; then
  echo "Usage: $0 [test|all]" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]] && kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$PORT_FORWARD_LOG"
}
trap cleanup EXIT

rm -f "$PORT_FORWARD_LOG"
kubectl port-forward -n "$NAMESPACE" service/keycloak-pg-demo-app 8080:8080 >"$PORT_FORWARD_LOG" 2>&1 &
PORT_FORWARD_PID="$!"

echo "Waiting for port-forward and app readiness at $APP_URL/healthz..."
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$APP_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "Port-forward did not become ready. Logs:" >&2
  cat "$PORT_FORWARD_LOG" >&2 || true
  exit 1
fi

case "$COMMAND" in
  test|all)
    APP_URL="$APP_URL" ./scripts/08-test.sh
    ;;
esac
