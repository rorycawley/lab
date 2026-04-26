#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
LOG_DIR="${LOG_DIR:-logs}"
RESULTS_FILE="$LOG_DIR/stress.json"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

mkdir -p "$LOG_DIR"

echo "Waiting for $APP_URL/healthz..."
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$APP_URL/healthz" >/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "App did not become ready at $APP_URL/healthz after 60s" >&2
  exit 1
fi

run_id="stress-$(date +%s)-$$"
create_key="$run_id-create"
body='{"title":"Stress idempotency","assigned_to":"Verifier"}'

echo "Stress: create once, then replay the same command 20 times."
first="$(
  curl -fsS -X POST "$APP_URL/commands/tasks" \
    -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $create_key" \
    -d "$body"
)"
task_id="$(echo "$first" | jq -r '.event.event_data.task_id')"
stream_id="task-$task_id"
first_sequence="$(echo "$first" | jq -r '.event.global_sequence')"

for i in $(seq 1 20); do
  replay="$(
    curl -fsS -X POST "$APP_URL/commands/tasks" \
      -H 'Content-Type: application/json' \
      -H "Idempotency-Key: $create_key" \
      -d "$body"
  )"
  sequence="$(echo "$replay" | jq -r '.event.global_sequence')"
  idempotent="$(echo "$replay" | jq -r '.event.idempotent')"
  if [[ "$sequence" != "$first_sequence" || "$idempotent" != "true" ]]; then
    echo "Idempotency replay failed on attempt $i: sequence=$sequence idempotent=$idempotent" >&2
    exit 1
  fi
done

echo "Stress: reuse the same idempotency key with different data."
bad_status="$(
  curl -sS -o "$LOG_DIR/bad-idempotency-reuse.json" -w '%{http_code}' \
    -X POST "$APP_URL/commands/tasks" \
    -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $create_key" \
    -d '{"title":"Different","assigned_to":"Verifier"}'
)"
if [[ "$bad_status" != "409" ]]; then
  echo "Expected idempotency key payload mismatch to return 409, got $bad_status" >&2
  cat "$LOG_DIR/bad-idempotency-reuse.json" >&2
  exit 1
fi

echo "Stress: send 15 stale-version rename commands to one stream."
successes=0
conflicts=0
for i in $(seq 1 15); do
  status="$(
    curl -sS -o "$LOG_DIR/concurrency-$i.json" -w '%{http_code}' \
      -X POST "$APP_URL/commands/tasks/$task_id/rename?expected_version=1" \
      -H 'Content-Type: application/json' \
      -H "Idempotency-Key: $run_id-rename-$i" \
      -d "{\"title\":\"Concurrent rename $i\"}"
  )"
  if [[ "$status" == "200" ]]; then
    successes=$((successes + 1))
  elif [[ "$status" == "409" ]]; then
    conflicts=$((conflicts + 1))
  else
    echo "Unexpected status from concurrency attempt $i: $status" >&2
    cat "$LOG_DIR/concurrency-$i.json" >&2
    exit 1
  fi
done

curl -fsS -X POST "$APP_URL/projector/run" >/dev/null
summary="$(
  curl -fsS "$APP_URL/queries/events" \
    | jq --arg stream "$stream_id" \
      '{stream_events: [.events[] | select(.stream_id == $stream)]}'
)"
created_count="$(echo "$summary" | jq '[.stream_events[] | select(.event_type == "task-created")] | length')"
renamed_count="$(echo "$summary" | jq '[.stream_events[] | select(.event_type == "task-renamed")] | length')"
max_version="$(echo "$summary" | jq '[.stream_events[].stream_version] | max')"

if [[ "$created_count" != "1" || "$renamed_count" != "1" || "$max_version" != "2" || "$successes" != "1" || "$conflicts" != "14" ]]; then
  echo "Stress validation failed" >&2
  echo "successes=$successes conflicts=$conflicts created_count=$created_count renamed_count=$renamed_count max_version=$max_version" >&2
  echo "$summary" | jq . >&2
  exit 1
fi

jq -n \
  --arg task_id "$task_id" \
  --arg stream_id "$stream_id" \
  --argjson idempotent_replays 20 \
  --argjson concurrency_successes "$successes" \
  --argjson concurrency_conflicts "$conflicts" \
  --argjson created_events "$created_count" \
  --argjson renamed_events "$renamed_count" \
  --argjson max_stream_version "$max_version" \
  '{
    status: "passed",
    task_id: $task_id,
    stream_id: $stream_id,
    idempotent_replays: $idempotent_replays,
    concurrency_successes: $concurrency_successes,
    concurrency_conflicts: $concurrency_conflicts,
    created_events: $created_events,
    renamed_events: $renamed_events,
    max_stream_version: $max_stream_version
  }' | tee "$RESULTS_FILE"

echo "Stress test passed. Results written to $RESULTS_FILE."
