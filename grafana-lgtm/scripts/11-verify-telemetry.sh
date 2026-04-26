#!/usr/bin/env bash
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_AUTH="${GRAFANA_AUTH:-admin:admin}"
LOG_DIR="${LOG_DIR:-logs}"
RESULTS_FILE="${RESULTS_FILE:-$LOG_DIR/test-results.json}"
TELEMETRY_FILE="$LOG_DIR/telemetry-verification.json"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

mkdir -p "$LOG_DIR"

if [[ ! -f "$RESULTS_FILE" ]]; then
  echo "$RESULTS_FILE does not exist. Run make test-with-port-forward or make test-all first." >&2
  exit 1
fi

work_trace_id="$(jq -r '.work_trace_id' "$RESULTS_FILE")"
checkout_trace_id="$(jq -r '.checkout_trace_id' "$RESULTS_FILE")"
if [[ -z "$work_trace_id" || "$work_trace_id" == "null" || -z "$checkout_trace_id" || "$checkout_trace_id" == "null" ]]; then
  echo "Expected work_trace_id and checkout_trace_id in $RESULTS_FILE" >&2
  exit 1
fi

echo "Waiting for Grafana at $GRAFANA_URL/api/health..."
grafana_ready=0
for _ in $(seq 1 60); do
  if curl -fsS -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
    grafana_ready=1
    break
  fi
  sleep 1
done
if [[ "$grafana_ready" != "1" ]]; then
  echo "Grafana did not become ready at $GRAFANA_URL/api/health after 60s" >&2
  exit 1
fi

echo "Querying Loki for application logs..."
loki_count=0
for _ in $(seq 1 60); do
  loki_response="$(
    curl -fsS -u "$GRAFANA_AUTH" --get \
      --data-urlencode 'query={service_name="otel-demo-app"}' \
      --data-urlencode 'limit=100' \
      "$GRAFANA_URL/api/datasources/proxy/uid/loki/loki/api/v1/query_range"
  )"
  loki_count="$(echo "$loki_response" | jq '[.data.result[].values[]? | select(.[1] | contains("WORK_COMPLETE") or contains("CHECKOUT_COMPLETE") or contains("SIMULATED_ERROR"))] | length')"
  if (( loki_count > 0 )); then
    break
  fi
  sleep 2
done
if (( loki_count == 0 )); then
  echo "Expected Loki to contain demo application logs." >&2
  echo "$loki_response" | jq . >&2
  exit 1
fi

echo "Querying Tempo for emitted trace IDs..."
tempo_work_found=0
tempo_checkout_found=0
tempo_k8s_metadata_found=0
for _ in $(seq 1 60); do
  tempo_work_response="$(
    curl -fsS -u "$GRAFANA_AUTH" --get \
      --data-urlencode 'q={ name = "demo.work" }' \
      --data-urlencode 'limit=20' \
      "$GRAFANA_URL/api/datasources/proxy/uid/tempo/api/search"
  )"
  if echo "$tempo_work_response" | jq -e '.traces | length > 0' >/dev/null; then
    tempo_work_found=1
  fi
  tempo_checkout_response="$(
    curl -fsS -u "$GRAFANA_AUTH" --get \
      --data-urlencode 'q={ name = "demo.checkout" }' \
      --data-urlencode 'limit=20' \
      "$GRAFANA_URL/api/datasources/proxy/uid/tempo/api/search"
  )"
  if echo "$tempo_checkout_response" | jq -e '.traces | length > 0' >/dev/null; then
    tempo_checkout_found=1
  fi
  tempo_k8s_metadata_response="$(
    curl -fsS -u "$GRAFANA_AUTH" --get \
      --data-urlencode 'q={ resource.k8s.namespace.name = "grafana-lgtm-demo" && resource.k8s.deployment.name = "otel-demo-app" }' \
      --data-urlencode 'limit=20' \
      "$GRAFANA_URL/api/datasources/proxy/uid/tempo/api/search"
  )"
  if echo "$tempo_k8s_metadata_response" | jq -e '.traces | length > 0' >/dev/null; then
    tempo_k8s_metadata_found=1
  fi
  if [[ "$tempo_work_found" == "1" && "$tempo_checkout_found" == "1" && "$tempo_k8s_metadata_found" == "1" ]]; then
    break
  fi
  sleep 2
done
if [[ "$tempo_work_found" != "1" || "$tempo_checkout_found" != "1" || "$tempo_k8s_metadata_found" != "1" ]]; then
  echo "Expected Tempo to contain demo.work, demo.checkout, and Kubernetes resource metadata." >&2
  echo "work_trace_id=$work_trace_id demo.work_found=$tempo_work_found" >&2
  echo "checkout_trace_id=$checkout_trace_id demo.checkout_found=$tempo_checkout_found" >&2
  echo "k8s_metadata_found=$tempo_k8s_metadata_found" >&2
  exit 1
fi

echo "Querying Mimir for demo request metrics..."
mimir_value=""
error_rate_value=""
latency_value=""
for _ in $(seq 1 60); do
  mimir_response="$(
    curl -fsS -u "$GRAFANA_AUTH" --get \
      --data-urlencode 'query=sum(demo_requests_total)' \
      "$GRAFANA_URL/api/datasources/proxy/uid/mimir/api/v1/query"
  )"
  mimir_value="$(echo "$mimir_response" | jq -r '.data.result[0].value[1] // empty')"
  if [[ -n "$mimir_value" ]] && awk "BEGIN { exit !($mimir_value > 0) }"; then
    break
  fi
  sleep 2
done
if [[ -z "$mimir_value" ]] || ! awk "BEGIN { exit !($mimir_value > 0) }"; then
  echo "Expected Mimir to contain demo_requests_total > 0." >&2
  echo "$mimir_response" | jq . >&2
  exit 1
fi

error_rate_response="$(
  curl -fsS -u "$GRAFANA_AUTH" --get \
    --data-urlencode 'query=sum(rate(demo_errors_total[5m]))' \
    "$GRAFANA_URL/api/datasources/proxy/uid/mimir/api/v1/query"
)"
error_rate_value="$(echo "$error_rate_response" | jq -r '.data.result[0].value[1] // empty')"
if [[ -z "$error_rate_value" ]] || ! awk "BEGIN { exit !($error_rate_value > 0) }"; then
  echo "Expected Mimir to contain demo_errors_total error-rate data." >&2
  echo "$error_rate_response" | jq . >&2
  exit 1
fi

latency_response="$(
  curl -fsS -u "$GRAFANA_AUTH" --get \
    --data-urlencode 'query=sum(demo_request_duration_ms_milliseconds_sum) / sum(demo_request_duration_ms_milliseconds_count)' \
    "$GRAFANA_URL/api/datasources/proxy/uid/mimir/api/v1/query"
)"
latency_value="$(echo "$latency_response" | jq -r '.data.result[0].value[1] // empty')"
if [[ -z "$latency_value" ]] || ! awk "BEGIN { exit !($latency_value >= 0) }"; then
  echo "Expected Mimir to contain demo_request_duration_ms latency data." >&2
  echo "$latency_response" | jq . >&2
  exit 1
fi

jq -n \
  --argjson loki_matching_log_lines "$loki_count" \
  --arg work_trace_id "$work_trace_id" \
  --arg checkout_trace_id "$checkout_trace_id" \
  --arg mimir_demo_requests_total "$mimir_value" \
  --arg mimir_demo_error_rate "$error_rate_value" \
  --arg mimir_demo_average_latency_ms "$latency_value" \
  '{
    status: "passed",
    loki_matching_log_lines: $loki_matching_log_lines,
    tempo_traces: [$work_trace_id, $checkout_trace_id],
    tempo_k8s_metadata: {
      namespace: "grafana-lgtm-demo",
      deployment: "otel-demo-app"
    },
    mimir_demo_requests_total: $mimir_demo_requests_total,
    mimir_demo_error_rate: $mimir_demo_error_rate,
    mimir_demo_average_latency_ms: $mimir_demo_average_latency_ms
  }' | tee "$TELEMETRY_FILE"

echo "Telemetry verification passed. Results written to $TELEMETRY_FILE."
