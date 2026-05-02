#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
mkdir -p logs

kubectl -n migrations-demo port-forward service/migrations-demo-api 8080:8080 > logs/port-forward.log 2>&1 &
pf_pid=$!
trap 'kill "$pf_pid" >/dev/null 2>&1 || true' EXIT

for _ in {1..40}; do
  if curl -fsS "$APP_URL/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if ! curl -fsS "$APP_URL/healthz" >/dev/null 2>&1; then
  echo "port-forward did not become ready" >&2
  cat logs/port-forward.log >&2 || true
  exit 1
fi

./scripts/09-test.sh

