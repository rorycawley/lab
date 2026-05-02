#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-https://localhost:8443}"
IMAGE="${IMAGE:-network-zero-trust-app:demo}"
LOG_DIR="${LOG_DIR:-logs}"
mkdir -p "$LOG_DIR"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required"; exit 1; }

echo
echo "==> Alpha health over HTTPS"
curl -kfsS "$APP_URL/healthz" | jq .

echo
echo "==> Allowed path: alpha calls beta over mTLS"
RESP="$(curl -kfsS "$APP_URL/call-peer")"
echo "$RESP" | jq .
CALLER="$(echo "$RESP" | jq -r .caller)"
PEER_SERVICE="$(echo "$RESP" | jq -r .peer_response.service)"
CLIENT_CN="$(echo "$RESP" | jq -r .peer_response.client_cn)"
if [[ "$CALLER" != "alpha" || "$PEER_SERVICE" != "beta" ]]; then
  echo "Expected alpha to call beta, got caller=$CALLER peer=$PEER_SERVICE" >&2
  exit 1
fi
if [[ "$CLIENT_CN" != "alpha.network-zero-trust.local" ]]; then
  echo "Expected beta to see alpha client cert CN, got $CLIENT_CN" >&2
  exit 1
fi

echo
echo "==> Denied path: rogue pod in alpha tries to call beta"
set +e
ROGUE_OUTPUT="$(kubectl -n network-alpha run denied-client \
  --image="$IMAGE" \
  --restart=Never \
  --labels=app=denied-client \
  --rm -i \
  --command -- python -c "import ssl,urllib.request; urllib.request.urlopen('https://beta-app.network-beta.svc.cluster.local:8443/identity', context=ssl._create_unverified_context(), timeout=4)" 2>&1)"
ROGUE_STATUS=$?
set -e
echo "$ROGUE_OUTPUT"
if [[ "$ROGUE_STATUS" == "0" ]]; then
  echo "Expected denied-client to fail. It reached beta successfully." >&2
  exit 1
fi
if echo "$ROGUE_OUTPUT" | grep -qiE "timed out|No route|Network is unreachable|i/o timeout"; then
  echo "Denied-client failed at the network-policy layer: network-alpha default-deny egress plus the alpha-app-only egress allow rule block this pod."
else
  echo "Denied-client failed before a successful request completed; mTLS still protects beta if the CNI does not enforce NetworkPolicy."
fi

echo
echo "==> Collecting logs"
kubectl -n network-alpha logs deployment/alpha-app > "$LOG_DIR/alpha.log" 2>&1 || true
kubectl -n network-beta logs deployment/beta-app > "$LOG_DIR/beta.log" 2>&1 || true
grep -q "PEER_CALL_ALLOWED" "$LOG_DIR/alpha.log" || { echo "missing PEER_CALL_ALLOWED in alpha logs" >&2; exit 1; }
grep -q "IDENTITY_REQUEST" "$LOG_DIR/beta.log" || { echo "missing IDENTITY_REQUEST in beta logs" >&2; exit 1; }

echo
echo "Smoke test passed."
