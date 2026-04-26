#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
ITERATIONS="${ITERATIONS:-20}"
SLEEP_SECONDS="${SLEEP_SECONDS:-1}"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }

echo "Generating $ITERATIONS rounds of demo traffic against $APP_URL..."
for i in $(seq 1 "$ITERATIONS"); do
  curl -fsS "$APP_URL/work" >/dev/null
  curl -fsS "$APP_URL/checkout?item=coffee&quantity=2" >/dev/null
  if (( i % 5 == 0 )); then
    curl -sS -o /dev/null -w "error_status=%{http_code}\n" "$APP_URL/error"
  fi
  sleep "$SLEEP_SECONDS"
done

echo "Traffic generation complete."
