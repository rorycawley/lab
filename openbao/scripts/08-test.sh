#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
LOG_DIR="${LOG_DIR:-logs}"
APP_LOG="$LOG_DIR/app.log"
NAMESPACE="${NAMESPACE:-openbao-demo}"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required"; exit 1; }

mkdir -p "$LOG_DIR"

echo "Waiting for $APP_URL/healthz..."
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$APP_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "App did not become ready at $APP_URL/healthz after 60s" >&2
  exit 1
fi

echo "Health: app + db connectivity."
curl -fsS "$APP_URL/db-healthz" | jq .

echo
echo "Static creds (KV v2): app fetches user/pass from kv/data/postgres."
static_response="$(curl -fsS "$APP_URL/query/static")"
echo "$static_response" | jq .
static_user="$(echo "$static_response" | jq -r '.current_user')"
if [[ "$static_user" != "appuser" ]]; then
  echo "Expected static current_user to be appuser, got '$static_user'" >&2
  exit 1
fi

echo
echo "Dynamic creds call #1: OpenBao mints a new short-lived Postgres user."
dyn1="$(curl -fsS "$APP_URL/query/dynamic")"
echo "$dyn1" | jq .
dyn1_user="$(echo "$dyn1" | jq -r '.current_user')"
dyn1_lease="$(echo "$dyn1" | jq -r '.lease_id')"

echo
echo "Dynamic creds call #2: should be a different user, different lease."
dyn2="$(curl -fsS "$APP_URL/query/dynamic")"
echo "$dyn2" | jq .
dyn2_user="$(echo "$dyn2" | jq -r '.current_user')"
dyn2_lease="$(echo "$dyn2" | jq -r '.lease_id')"

if [[ "$dyn1_user" == "$dyn2_user" || "$dyn1_lease" == "$dyn2_lease" ]]; then
  echo "Expected dynamic creds to be unique per request" >&2
  echo "  call#1: user=$dyn1_user lease=$dyn1_lease" >&2
  echo "  call#2: user=$dyn2_user lease=$dyn2_lease" >&2
  exit 1
fi

case "$dyn1_user" in
  v-approle-poc-role-*) ;;
  *)
    echo "Expected dynamic user to follow OpenBao naming pattern v-approle-poc-role-*, got '$dyn1_user'" >&2
    exit 1
    ;;
esac

echo
echo "Collecting application logs to $APP_LOG..."
kubectl logs -n "$NAMESPACE" deployment/openbao-demo-app > "$APP_LOG"
grep -q "APPROLE_LOGIN_OK" "$APP_LOG"

echo
echo "Smoke test passed."
echo "  static  user: $static_user"
echo "  dynamic user (call 1): $dyn1_user"
echo "  dynamic user (call 2): $dyn2_user"
