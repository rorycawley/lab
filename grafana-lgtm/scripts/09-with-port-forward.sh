#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-grafana-lgtm-demo}"
APP_URL="${APP_URL:-http://localhost:8080}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
COMMAND="${1:-test}"
APP_PORT_FORWARD_LOG="${APP_PORT_FORWARD_LOG:-/tmp/grafana-lgtm-app-port-forward.log}"
GRAFANA_PORT_FORWARD_LOG="${GRAFANA_PORT_FORWARD_LOG:-/tmp/grafana-lgtm-grafana-port-forward.log}"

if [[ "$COMMAND" != "test" && "$COMMAND" != "traffic" && "$COMMAND" != "telemetry" && "$COMMAND" != "alerts" && "$COMMAND" != "all" ]]; then
  echo "Usage: $0 [test|traffic|telemetry|alerts|all]" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${APP_PORT_FORWARD_PID:-}" ]] && kill -0 "$APP_PORT_FORWARD_PID" >/dev/null 2>&1; then
    kill "$APP_PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$APP_PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${GRAFANA_PORT_FORWARD_PID:-}" ]] && kill -0 "$GRAFANA_PORT_FORWARD_PID" >/dev/null 2>&1; then
    kill "$GRAFANA_PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$GRAFANA_PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$APP_PORT_FORWARD_LOG" "$GRAFANA_PORT_FORWARD_LOG"
}
trap cleanup EXIT

rm -f "$APP_PORT_FORWARD_LOG" "$GRAFANA_PORT_FORWARD_LOG"
kubectl port-forward -n "$NAMESPACE" service/otel-demo-app 8080:8080 >"$APP_PORT_FORWARD_LOG" 2>&1 &
APP_PORT_FORWARD_PID="$!"
kubectl port-forward -n "$NAMESPACE" service/grafana-lgtm 3000:3000 >"$GRAFANA_PORT_FORWARD_LOG" 2>&1 &
GRAFANA_PORT_FORWARD_PID="$!"

echo "Waiting for app readiness at $APP_URL/healthz..."
app_ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$APP_URL/healthz" >/dev/null 2>&1; then
    app_ready=1
    break
  fi
  sleep 1
done
if [[ "$app_ready" != "1" ]]; then
  echo "App port-forward did not become ready. Logs:" >&2
  cat "$APP_PORT_FORWARD_LOG" >&2 || true
  exit 1
fi

echo "Waiting for Grafana readiness at $GRAFANA_URL/api/health..."
grafana_ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
    grafana_ready=1
    break
  fi
  sleep 1
done
if [[ "$grafana_ready" != "1" ]]; then
  echo "Grafana port-forward did not become ready. Logs:" >&2
  cat "$GRAFANA_PORT_FORWARD_LOG" >&2 || true
  exit 1
fi

case "$COMMAND" in
  test)
    APP_URL="$APP_URL" NAMESPACE="$NAMESPACE" ./scripts/08-test.sh
    ;;
  traffic)
    APP_URL="$APP_URL" ./scripts/10-generate-traffic.sh
    ;;
  telemetry)
    GRAFANA_URL="$GRAFANA_URL" ./scripts/11-verify-telemetry.sh
    ;;
  alerts)
    GRAFANA_URL="$GRAFANA_URL" ./scripts/12-verify-alerts.sh
    ;;
  all)
    APP_URL="$APP_URL" NAMESPACE="$NAMESPACE" ./scripts/08-test.sh
    APP_URL="$APP_URL" ./scripts/10-generate-traffic.sh
    GRAFANA_URL="$GRAFANA_URL" ./scripts/11-verify-telemetry.sh
    GRAFANA_URL="$GRAFANA_URL" ./scripts/12-verify-alerts.sh
    ;;
esac

echo
echo "Temporary app and Grafana port-forwards were used for the check and have now stopped."
echo "Run make port-forward-grafana to browse $GRAFANA_URL."
echo "The dashboard is provisioned as: Python App OTel Logs and Traces"
