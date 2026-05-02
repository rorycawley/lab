#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"

echo "Testing API at $APP_URL"

curl -fsS "$APP_URL/healthz"
echo
curl -fsS "$APP_URL/db-healthz"
echo
curl -fsS "$APP_URL/todos"
echo
curl -fsS -X POST "$APP_URL/todos" \
  -H 'content-type: application/json' \
  -d '{"title":"created by app_user"}'
echo
curl -fsS "$APP_URL/todos"
echo
curl -fsS -X POST "$APP_URL/prove/app-cannot-ddl"
echo

echo "API test passed."

