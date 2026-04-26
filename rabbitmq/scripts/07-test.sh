#!/usr/bin/env bash
set -euo pipefail

PUBLISHER_URL="${PUBLISHER_URL:-http://localhost:8080}"
SUBSCRIBER_URL="${SUBSCRIBER_URL:-http://localhost:8081}"
LOG_DIR="${LOG_DIR:-logs}"
PUB_LOG="$LOG_DIR/publisher.log"
SUB_LOG="$LOG_DIR/subscriber.log"
NAMESPACE="${NAMESPACE:-rabbitmq-demo}"

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

wait_for "$PUBLISHER_URL/healthz"
wait_for "$SUBSCRIBER_URL/healthz"

echo
echo "==> Health: publisher + subscriber readiness"
curl -fsS "$PUBLISHER_URL/readyz" | jq .
curl -fsS "$SUBSCRIBER_URL/readyz" | jq .

KEY1="key-$(uuidgen)"

echo
echo "==> Step 1: POST /tasks (Idempotency-Key: $KEY1)"
RESP1="$(curl -fsS -X POST "$PUBLISHER_URL/tasks" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $KEY1" \
  -d '{"title":"first task"}')"
echo "$RESP1" | jq .
TASK_ID="$(echo "$RESP1" | jq -r .task_id)"
EVENT_ID="$(echo "$RESP1" | jq -r .event_id)"

echo
echo "==> Step 2: relay drains the outbox"
drained=0
for _ in $(seq 1 30); do
  pending="$(curl -fsS "$PUBLISHER_URL/outbox/pending" | jq '.count')"
  if [[ "$pending" == "0" ]]; then drained=1; break; fi
  sleep 1
done
if [[ "$drained" != "1" ]]; then
  echo "Outbox did not drain in 30s" >&2
  curl -fsS "$PUBLISHER_URL/outbox/pending" | jq . >&2
  exit 1
fi
echo "Outbox is empty."
curl -fsS "$PUBLISHER_URL/events?limit=5" | jq '.events[0] | {event_id, event_type, published_at}'

echo
echo "==> Step 3: subscriber records the event"
seen=0
for _ in $(seq 1 30); do
  count="$(curl -fsS "$SUBSCRIBER_URL/processed/$EVENT_ID/count" | jq '.count')"
  if [[ "$count" == "1" ]]; then seen=1; break; fi
  sleep 1
done
if [[ "$seen" != "1" ]]; then
  echo "Subscriber did not process $EVENT_ID in 30s" >&2
  curl -fsS "$SUBSCRIBER_URL/stats" | jq . >&2
  exit 1
fi
echo "Subscriber processed event $EVENT_ID."

echo
echo "==> Step 4: same Idempotency-Key returns same task, no new event"
EVENTS_BEFORE="$(curl -fsS "$PUBLISHER_URL/events?limit=200" | jq '.count')"
RESP2="$(curl -fsS -X POST "$PUBLISHER_URL/tasks" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $KEY1" \
  -d '{"title":"first task (retry)"}')"
echo "$RESP2" | jq .
TASK_ID2="$(echo "$RESP2" | jq -r .task_id)"
EVENT_ID2="$(echo "$RESP2" | jq -r .event_id)"
EVENTS_AFTER="$(curl -fsS "$PUBLISHER_URL/events?limit=200" | jq '.count')"
if [[ "$TASK_ID" != "$TASK_ID2" || "$EVENT_ID" != "$EVENT_ID2" ]]; then
  echo "Idempotency broken: same key produced different task/event" >&2
  echo "  first:  task=$TASK_ID  event=$EVENT_ID"  >&2
  echo "  second: task=$TASK_ID2 event=$EVENT_ID2" >&2
  exit 1
fi
if [[ "$EVENTS_BEFORE" != "$EVENTS_AFTER" ]]; then
  echo "Idempotency broken: events count grew from $EVENTS_BEFORE to $EVENTS_AFTER" >&2
  exit 1
fi
echo "Idempotency holds: same task_id, same event_id, no new event row."

echo
echo "==> Step 5: republish same event, subscriber must dedup"
PROCESSED_BEFORE="$(curl -fsS "$SUBSCRIBER_URL/stats" | jq '.processed_in_db')"
DEDUP_BEFORE="$(curl -fsS "$SUBSCRIBER_URL/stats" | jq '.dedup_hits_session')"
curl -fsS -X POST "$PUBLISHER_URL/admin/republish/$EVENT_ID" | jq .

dedup_seen=0
for _ in $(seq 1 30); do
  DEDUP_AFTER="$(curl -fsS "$SUBSCRIBER_URL/stats" | jq '.dedup_hits_session')"
  if (( DEDUP_AFTER > DEDUP_BEFORE )); then dedup_seen=1; break; fi
  sleep 1
done
PROCESSED_AFTER="$(curl -fsS "$SUBSCRIBER_URL/stats" | jq '.processed_in_db')"
COUNT_FOR_EVENT="$(curl -fsS "$SUBSCRIBER_URL/processed/$EVENT_ID/count" | jq '.count')"
if [[ "$dedup_seen" != "1" ]]; then
  echo "Subscriber did not register a dedup hit after republish" >&2
  curl -fsS "$SUBSCRIBER_URL/stats" | jq . >&2
  exit 1
fi
if [[ "$COUNT_FOR_EVENT" != "1" ]]; then
  echo "Expected processed_events count for $EVENT_ID = 1, got $COUNT_FOR_EVENT" >&2
  exit 1
fi
if [[ "$PROCESSED_BEFORE" != "$PROCESSED_AFTER" ]]; then
  echo "Expected processed_events table count unchanged after republish: $PROCESSED_BEFORE -> $PROCESSED_AFTER" >&2
  exit 1
fi
echo "Consumer dedup holds: dedup_hits incremented, processed_events unchanged."

echo
echo "==> Collecting logs"
kubectl -n "$NAMESPACE" logs deployment/publisher  > "$PUB_LOG" 2>&1 || true
kubectl -n "$NAMESPACE" logs deployment/subscriber > "$SUB_LOG" 2>&1 || true
grep -q "RELAY_PUBLISHED"  "$PUB_LOG" || { echo "missing RELAY_PUBLISHED in publisher log"  >&2; exit 1; }
grep -q "EVENT_PROCESSED"  "$SUB_LOG" || { echo "missing EVENT_PROCESSED in subscriber log" >&2; exit 1; }
grep -q "DEDUP_HIT"        "$SUB_LOG" || { echo "missing DEDUP_HIT in subscriber log"      >&2; exit 1; }

echo
echo "Smoke test passed."
echo "  task_id          = $TASK_ID"
echo "  event_id         = $EVENT_ID"
echo "  processed_in_db  = $PROCESSED_AFTER"
echo "  dedup hits seen  = yes"
