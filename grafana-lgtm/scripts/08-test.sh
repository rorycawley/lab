#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
NAMESPACE="${NAMESPACE:-grafana-lgtm-demo}"
LOG_DIR="${LOG_DIR:-logs}"
RESULTS_FILE="$LOG_DIR/test-results.json"
APP_LOG="$LOG_DIR/app.log"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required"; exit 1; }

mkdir -p "$LOG_DIR"

echo "Waiting for $APP_URL/healthz..."
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$APP_URL/healthz" >/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "App did not become ready at $APP_URL/healthz after 60s" >&2
  exit 1
fi

echo "Calling /work to emit nested spans, logs, and metrics."
work_response="$(curl -fsS "$APP_URL/work")"
echo "$work_response" | jq .

echo "Calling /checkout to emit business-style telemetry."
checkout_response="$(curl -fsS "$APP_URL/checkout?item=coffee&quantity=2")"
echo "$checkout_response" | jq .

echo "Calling /error to emit an error span and error log."
error_status="$(
  curl -sS -o "$LOG_DIR/error-response.json" -w '%{http_code}' "$APP_URL/error"
)"
if [[ "$error_status" != "500" ]]; then
  echo "Expected /error to return HTTP 500, got $error_status" >&2
  cat "$LOG_DIR/error-response.json" >&2
  exit 1
fi
cat "$LOG_DIR/error-response.json" | jq .

echo "Collecting application logs to $APP_LOG..."
kubectl logs -n "$NAMESPACE" deployment/otel-demo-app > "$APP_LOG"
grep -q "WORK_REQUEST accepted" "$APP_LOG"
grep -q "WORK_COMPLETE" "$APP_LOG"
grep -q "CHECKOUT_STARTED item=coffee quantity=2" "$APP_LOG"
grep -q "CHECKOUT_COMPLETE item=coffee quantity=2" "$APP_LOG"
grep -q "SIMULATED_ERROR message=simulated downstream failure" "$APP_LOG"
grep -q "$(echo "$work_response" | jq -r '.trace_id')" "$APP_LOG"
grep -q "$(echo "$checkout_response" | jq -r '.trace_id')" "$APP_LOG"

jq -n \
  --arg work_trace_id "$(echo "$work_response" | jq -r '.trace_id')" \
  --arg checkout_trace_id "$(echo "$checkout_response" | jq -r '.trace_id')" \
  --argjson error_status "$error_status" \
  '{
    status: "passed",
    work_trace_id: $work_trace_id,
    checkout_trace_id: $checkout_trace_id,
    error_status: $error_status,
    grafana_log_query: "{service_name=\"otel-demo-app\"}",
    grafana_traceql_query: "{ resource.service.name = \"otel-demo-app\" }"
  }' | tee "$RESULTS_FILE"

echo "Test passed. Results written to $RESULTS_FILE."
