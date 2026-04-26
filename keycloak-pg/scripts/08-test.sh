#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
LOG_DIR="${LOG_DIR:-logs}"
APP_LOG="$LOG_DIR/app.log"
PROXY_LOG="$LOG_DIR/proxy.log"
NAMESPACE="${NAMESPACE:-keycloak-pg-demo}"
EXPECTED_ROLE="${EXPECTED_ROLE:-pgreader}"

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

echo
echo "Happy path: app fetches JWT from Keycloak, hands it to the proxy as the PG password."
good_response="$(curl -fsS "$APP_URL/query")"
echo "$good_response" | jq .
got_session="$(echo "$good_response" | jq -r '.session_user')"
got_user="$(echo "$good_response" | jq -r '.current_user')"
got_message="$(echo "$good_response" | jq -r '.message')"

# session_user = the login identity (the proxy's backend account)
# current_user = the effective role after the proxy's SET ROLE from the JWT claim
if [[ "$got_session" != "pgproxy" ]]; then
  echo "Expected session_user=pgproxy (the proxy's backend identity), got '$got_session'" >&2
  exit 1
fi
if [[ "$got_user" != "$EXPECTED_ROLE" ]]; then
  echo "Expected current_user=$EXPECTED_ROLE (from JWT pg_role claim via SET ROLE), got '$got_user'" >&2
  exit 1
fi
if [[ -z "$got_message" || "$got_message" == "null" ]]; then
  echo "Expected a row from messages, got '$got_message'" >&2
  exit 1
fi

echo
echo "Negative path: forged JWT must be rejected by the proxy."
bad_response="$(curl -fsS "$APP_URL/query/bad-token")"
echo "$bad_response" | jq .
rejected="$(echo "$bad_response" | jq -r '.rejected // false')"
err="$(echo "$bad_response" | jq -r '.error // ""')"
if [[ "$rejected" != "true" ]]; then
  echo "Expected the forged-token call to be rejected, but it succeeded" >&2
  exit 1
fi
if ! echo "$err" | grep -qi "jwt"; then
  echo "Rejection error did not mention JWT: $err" >&2
  exit 1
fi

echo
echo "Collecting logs to $LOG_DIR/..."
kubectl logs -n "$NAMESPACE" deployment/keycloak-pg-demo-app > "$APP_LOG"
docker compose logs --no-color pg-jwt-proxy > "$PROXY_LOG"

grep -q "TOKEN_FETCHED" "$APP_LOG"
grep -q "JWT_OK" "$PROXY_LOG"
grep -q "JWT_REJECTED" "$PROXY_LOG"

echo
echo "Smoke test passed."
echo "  /query        -> session_user=$got_session current_user=$got_user"
echo "  /query/bad    -> rejected=$rejected"
