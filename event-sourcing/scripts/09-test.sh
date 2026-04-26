#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
NAMESPACE="${NAMESPACE:-event-sourcing-demo}"
LOG_DIR="${LOG_DIR:-logs}"
APP_LOG="$LOG_DIR/app.log"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required"; exit 1; }

mkdir -p "$LOG_DIR"

request_json() {
  local method="$1"
  local path="$2"
  local idempotency_key="${3:-}"
  local body="${4:-}"
  local output

  output="$(mktemp)"
  if [[ -n "$body" ]]; then
    http_status="$(
      curl -sS -o "$output" -w "%{http_code}" -X "$method" "$APP_URL$path" \
        -H 'Content-Type: application/json' \
        ${idempotency_key:+-H "Idempotency-Key: $idempotency_key"} \
        -d "$body"
    )"
  else
    http_status="$(
      curl -sS -o "$output" -w "%{http_code}" -X "$method" "$APP_URL$path" \
        ${idempotency_key:+-H "Idempotency-Key: $idempotency_key"}
    )"
  fi

  cat "$output"
  rm -f "$output"
  echo "$http_status" > "$LOG_DIR/last-status"
}

assert_status() {
  local expected="$1"
  local actual
  actual="$(cat "$LOG_DIR/last-status")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected HTTP $expected, got HTTP $actual" >&2
    exit 1
  fi
}

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

echo "Query: database connectivity."
curl -fsS "$APP_URL/db-healthz" | jq .

run_id="$(date +%s)-$$"
create_key="create-$run_id"
rename_key="rename-$run_id"
complete_key="complete-$run_id"
reopen_key="reopen-$run_id"
stale_key="stale-complete-$run_id"
missing_version_key="missing-version-$run_id"
bad_reuse_key="bad-reuse-$run_id"

echo "Command: create task with an idempotency key."
create_response="$(request_json POST /commands/tasks "$create_key" '{"title":"Learn event sourcing","assigned_to":"Rory"}')"
assert_status 201
echo "$create_response" | jq .
task_id="$(echo "$create_response" | jq -r '.event.event_data.task_id')"
stream_id="task-$task_id"

echo "Command: repeat create with the same key; it must replay the same event."
create_replay="$(request_json POST /commands/tasks "$create_key" '{"title":"Learn event sourcing","assigned_to":"Rory"}')"
assert_status 201
echo "$create_replay" | jq .
replay_sequence="$(echo "$create_replay" | jq -r '.event.global_sequence')"
original_sequence="$(echo "$create_response" | jq -r '.event.global_sequence')"
replay_flag="$(echo "$create_replay" | jq -r '.event.idempotent')"
if [[ "$replay_sequence" != "$original_sequence" || "$replay_flag" != "true" ]]; then
  echo "Expected idempotent create replay to return the original event" >&2
  exit 1
fi

echo "Command: reuse an idempotency key with different data; it must fail."
request_json POST /commands/tasks "$create_key" '{"title":"Different title","assigned_to":"Rory"}' | jq .
assert_status 409

echo "Query: event store has the create event before projection."
events_after_create="$(curl -fsS "$APP_URL/queries/events")"
echo "$events_after_create" | jq .
created_count="$(echo "$events_after_create" | jq --arg stream "$stream_id" '[.events[] | select(.stream_id == $stream and .event_type == "task-created")] | length')"
if [[ "$created_count" != "1" ]]; then
  echo "Expected exactly one task-created event for $stream_id after idempotent replay" >&2
  exit 1
fi

echo "Query: read model is stale before projection."
before_count="$(curl -fsS "$APP_URL/queries/tasks" | jq --arg id "$task_id" '[.tasks[] | select(.task_id == $id)] | length')"
if [[ "$before_count" != "0" ]]; then
  echo "Expected the new task to be absent from the read model before projection" >&2
  exit 1
fi

echo "Projection: run projector and query the read model."
curl -fsS -X POST "$APP_URL/projector/run" | jq .
after_count="$(curl -fsS "$APP_URL/queries/tasks" | jq --arg id "$task_id" '[.tasks[] | select(.task_id == $id)] | length')"
if [[ "$after_count" != "1" ]]; then
  echo "Expected the new task to be present after projection" >&2
  exit 1
fi

echo "Command: rename task with expected_version=1."
rename_response="$(request_json POST "/commands/tasks/$task_id/rename?expected_version=1" "$rename_key" '{"title":"Learn CQRS projections"}')"
assert_status 200
echo "$rename_response" | jq .

echo "Command: stale complete with expected_version=1 must prove optimistic concurrency."
request_json POST "/commands/tasks/$task_id/complete?expected_version=1" "$stale_key" | jq .
assert_status 409

echo "Command: update without expected_version must fail."
request_json POST "/commands/tasks/$task_id/complete" "$missing_version_key" | jq .
assert_status 422

echo "Command: complete task with expected_version=2."
complete_response="$(request_json POST "/commands/tasks/$task_id/complete?expected_version=2" "$complete_key")"
assert_status 200
echo "$complete_response" | jq .

echo "Command: repeat complete with same key; it must be idempotent even though task is already complete."
complete_replay="$(request_json POST "/commands/tasks/$task_id/complete?expected_version=2" "$complete_key")"
assert_status 200
echo "$complete_replay" | jq .
if [[ "$(echo "$complete_replay" | jq -r '.event.idempotent')" != "true" ]]; then
  echo "Expected complete replay to be idempotent" >&2
  exit 1
fi

echo "Projection: project rename and complete events."
curl -fsS -X POST "$APP_URL/projector/run" | jq .
projected_status="$(curl -fsS "$APP_URL/queries/tasks/$task_id" | jq -r '.task.status')"
projected_title="$(curl -fsS "$APP_URL/queries/tasks/$task_id" | jq -r '.task.title')"
if [[ "$projected_status" != "completed" || "$projected_title" != "Learn CQRS projections" ]]; then
  echo "Expected projected task to be completed and renamed" >&2
  exit 1
fi

echo "Command: reopen task with expected_version=3."
reopen_response="$(request_json POST "/commands/tasks/$task_id/reopen?expected_version=3" "$reopen_key")"
assert_status 200
echo "$reopen_response" | jq .
curl -fsS -X POST "$APP_URL/projector/run" | jq .
final_status="$(curl -fsS "$APP_URL/queries/tasks/$task_id" | jq -r '.task.status')"
if [[ "$final_status" != "open" ]]; then
  echo "Expected projected task status to be open after task-reopened" >&2
  exit 1
fi

echo "Query: projection checkpoint."
curl -fsS "$APP_URL/queries/projection" | jq .

echo "Assert: this single stream has multiple event types."
events_final="$(curl -fsS "$APP_URL/queries/events")"
event_type_count="$(echo "$events_final" | jq --arg stream "$stream_id" '[.events[] | select(.stream_id == $stream) | .event_type] | unique | length')"
if (( event_type_count < 2 )); then
  echo "Expected at least two event types for $stream_id" >&2
  exit 1
fi

echo "Collecting application logs to $APP_LOG..."
kubectl logs -n "$NAMESPACE" deployment/task-event-sourcing-api > "$APP_LOG"
grep -q "COMMAND_APPEND event_type=task-created" "$APP_LOG"
grep -q "COMMAND_APPEND event_type=task-renamed" "$APP_LOG"
grep -q "COMMAND_APPEND event_type=task-completed" "$APP_LOG"
grep -q "COMMAND_APPEND event_type=task-reopened" "$APP_LOG"
grep -q "IDEMPOTENT_REPLAY" "$APP_LOG"
grep -q "OPTIMISTIC_CONCURRENCY_CONFLICT" "$APP_LOG"
grep -q "PROJECTOR_RUN" "$APP_LOG"
grep -q "QUERY tasks" "$APP_LOG"

rm -f "$LOG_DIR/last-status"
echo "Smoke test passed. Application log captured at $APP_LOG."
