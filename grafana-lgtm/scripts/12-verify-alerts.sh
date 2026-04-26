#!/usr/bin/env bash
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_AUTH="${GRAFANA_AUTH:-admin:admin}"
LOG_DIR="${LOG_DIR:-logs}"
ALERTS_FILE="$LOG_DIR/alert-verification.json"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

mkdir -p "$LOG_DIR"

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

echo "Checking provisioned Grafana alert rules..."
rules_response="$(curl -fsS -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/v1/provisioning/alert-rules")"
error_rule_count="$(echo "$rules_response" | jq '[.[] | select(.uid == "otel-demo-error-rate")] | length')"
latency_rule_count="$(echo "$rules_response" | jq '[.[] | select(.uid == "otel-demo-average-latency")] | length')"

if [[ "$error_rule_count" != "1" || "$latency_rule_count" != "1" ]]; then
  echo "Expected provisioned alert rules to be present." >&2
  echo "$rules_response" | jq '[.[] | {uid, title, folderUID, ruleGroup}]' >&2
  exit 1
fi

states_response="$(curl -fsS -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/prometheus/grafana/api/v1/rules")"
demo_state_count="$(
  echo "$states_response" \
    | jq '[.data.groups[]?.rules[]? | select(.labels.demo == "grafana-lgtm")] | length'
)"

if (( demo_state_count < 2 )); then
  echo "Expected Grafana alert evaluator to list the demo alert rules." >&2
  echo "$states_response" | jq . >&2
  exit 1
fi

jq -n \
  --argjson provisioned_rules 2 \
  --argjson evaluator_rules "$demo_state_count" \
  '{
    status: "passed",
    provisioned_rules: $provisioned_rules,
    evaluator_rules: $evaluator_rules,
    alerts: [
      "otel-demo-error-rate",
      "otel-demo-average-latency"
    ]
  }' | tee "$ALERTS_FILE"

echo "Alert verification passed. Results written to $ALERTS_FILE."
