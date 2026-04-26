#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-rabbitmq-demo}"
PUBLISHER_URL="${PUBLISHER_URL:-http://localhost:8080}"
SUBSCRIBER_URL="${SUBSCRIBER_URL:-http://localhost:8081}"
COMMAND="${1:-test}"
PUB_LOG="${PUB_LOG:-/tmp/rabbitmq-demo-pub-pf.log}"
SUB_LOG="${SUB_LOG:-/tmp/rabbitmq-demo-sub-pf.log}"

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
  rm -f "$PUB_LOG" "$SUB_LOG"
}
trap cleanup EXIT

rm -f "$PUB_LOG" "$SUB_LOG"

kubectl -n "$NAMESPACE" port-forward service/publisher 8080:8080  >"$PUB_LOG" 2>&1 &
PIDS+=("$!")
kubectl -n "$NAMESPACE" port-forward service/subscriber 8081:8080 >"$SUB_LOG" 2>&1 &
PIDS+=("$!")

echo "Waiting for port-forwards..."
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$PUBLISHER_URL/healthz"  >/dev/null 2>&1 \
  && curl -fsS "$SUBSCRIBER_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "Port-forwards did not become ready." >&2
  echo "--- publisher port-forward log ---"  >&2; cat "$PUB_LOG" >&2 || true
  echo "--- subscriber port-forward log ---" >&2; cat "$SUB_LOG" >&2 || true
  exit 1
fi

case "$COMMAND" in
  test|all)
    PUBLISHER_URL="$PUBLISHER_URL" SUBSCRIBER_URL="$SUBSCRIBER_URL" \
      ./scripts/07-test.sh
    ;;
esac
