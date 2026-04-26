#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
LOG_DIR="${LOG_DIR:-logs}"
APP_LOG="$LOG_DIR/app.log"
NAMESPACE="${NAMESPACE:-redis-demo}"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required"; exit 1; }

mkdir -p "$LOG_DIR"

wait_for() {
  local url="$1"
  for _ in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "Timed out waiting for $url" >&2
  return 1
}

wait_for "$APP_URL/healthz"

echo
echo "==> Health: app readyz (Redis ping)"
curl -fsS "$APP_URL/readyz" | jq .

echo
echo "==> Step 0: start from a clean cache"
curl -fsS -X DELETE "$APP_URL/cache" | jq .

echo
echo "==> Step 1: cold GET /items/1 (expect source=origin, slow)"
RESP1="$(curl -fsS "$APP_URL/items/1?ttl_seconds=60")"
echo "$RESP1" | jq .
SRC1="$(echo "$RESP1" | jq -r .source)"
ELAPSED1="$(echo "$RESP1" | jq -r .elapsed_ms)"
if [[ "$SRC1" != "origin" ]]; then
  echo "Expected source=origin on cold call, got $SRC1" >&2
  exit 1
fi

echo
echo "==> Step 2: warm GET /items/1 (expect source=cache, fast)"
RESP2="$(curl -fsS "$APP_URL/items/1")"
echo "$RESP2" | jq .
SRC2="$(echo "$RESP2" | jq -r .source)"
ELAPSED2="$(echo "$RESP2" | jq -r .elapsed_ms)"
if [[ "$SRC2" != "cache" ]]; then
  echo "Expected source=cache on warm call, got $SRC2" >&2
  exit 1
fi
faster=$(awk -v a="$ELAPSED1" -v b="$ELAPSED2" 'BEGIN{print (b < a) ? 1 : 0}')
if [[ "$faster" != "1" ]]; then
  echo "Expected warm call faster than cold ($ELAPSED2 ms vs $ELAPSED1 ms)" >&2
  exit 1
fi
echo "Warm call faster: cold=${ELAPSED1}ms warm=${ELAPSED2}ms"

echo
echo "==> Step 3: stats show >= 1 hit and >= 1 miss"
STATS="$(curl -fsS "$APP_URL/stats")"
echo "$STATS" | jq .
HITS="$(echo "$STATS" | jq '.hits')"
MISSES="$(echo "$STATS" | jq '.misses')"
if (( HITS < 1 || MISSES < 1 )); then
  echo "Expected hits >= 1 and misses >= 1, got hits=$HITS misses=$MISSES" >&2
  exit 1
fi

echo
echo "==> Step 4: GET /cache/1 shows raw stored value + TTL"
INSPECT="$(curl -fsS "$APP_URL/cache/1")"
echo "$INSPECT" | jq .
PRESENT="$(echo "$INSPECT" | jq -r .present)"
TTL_REMAINING="$(echo "$INSPECT" | jq -r .ttl_remaining)"
if [[ "$PRESENT" != "true" ]]; then
  echo "Expected key item:1 to be present in Redis" >&2
  exit 1
fi
if (( TTL_REMAINING <= 0 || TTL_REMAINING > 60 )); then
  echo "Expected 0 < ttl_remaining <= 60, got $TTL_REMAINING" >&2
  exit 1
fi

echo
echo "==> Step 5: invalidate item:1, next GET goes to origin again"
curl -fsS -X DELETE "$APP_URL/cache/1" | jq .
RESP3="$(curl -fsS "$APP_URL/items/1")"
echo "$RESP3" | jq .
SRC3="$(echo "$RESP3" | jq -r .source)"
if [[ "$SRC3" != "origin" ]]; then
  echo "Expected source=origin after invalidation, got $SRC3" >&2
  exit 1
fi

echo
echo "==> Step 6: short-TTL key expires"
RESP4="$(curl -fsS "$APP_URL/items/2?ttl_seconds=2")"
echo "$RESP4" | jq .
SRC4="$(echo "$RESP4" | jq -r .source)"
if [[ "$SRC4" != "origin" ]]; then
  echo "Expected first call to /items/2 source=origin, got $SRC4" >&2
  exit 1
fi
RESP5="$(curl -fsS "$APP_URL/items/2")"
SRC5="$(echo "$RESP5" | jq -r .source)"
if [[ "$SRC5" != "cache" ]]; then
  echo "Expected immediate re-call source=cache, got $SRC5" >&2
  exit 1
fi
echo "Sleeping 3s for the 2s TTL to expire..."
sleep 3
RESP6="$(curl -fsS "$APP_URL/items/2")"
echo "$RESP6" | jq .
SRC6="$(echo "$RESP6" | jq -r .source)"
if [[ "$SRC6" != "origin" ]]; then
  echo "Expected source=origin after TTL expiry, got $SRC6" >&2
  exit 1
fi

echo
echo "==> Collecting logs"
kubectl -n "$NAMESPACE" logs deployment/redis-demo-app > "$APP_LOG" 2>&1 || true
grep -q "CACHE_MISS"        "$APP_LOG" || { echo "missing CACHE_MISS in app log"        >&2; exit 1; }
grep -q "CACHE_HIT"         "$APP_LOG" || { echo "missing CACHE_HIT in app log"         >&2; exit 1; }
grep -q "CACHE_INVALIDATED" "$APP_LOG" || { echo "missing CACHE_INVALIDATED in app log" >&2; exit 1; }

FINAL_STATS="$(curl -fsS "$APP_URL/stats")"
echo
echo "Smoke test passed."
echo "  cold elapsed_ms     = $ELAPSED1"
echo "  warm elapsed_ms     = $ELAPSED2"
echo "  final stats         = $(echo "$FINAL_STATS" | jq -c .)"
