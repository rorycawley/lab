#!/usr/bin/env bash
set -euo pipefail

echo "Event store: event counts by type."
docker compose exec -T event-postgres psql -U tasks -d task_events \
  -c "select event_type, count(*) from domain_events group by event_type order by event_type;"

echo
echo "Event store: idempotency key count."
docker compose exec -T event-postgres psql -U tasks -d task_events \
  -c "select count(*) as idempotency_keys from command_idempotency;"

echo
echo "Event store: stream versions."
docker compose exec -T event-postgres psql -U tasks -d task_events \
  -c "select stream_id, max(stream_version) as current_version, count(*) as events from domain_events group by stream_id order by stream_id;"

echo
echo "Read store: projected task state."
docker compose exec -T read-postgres psql -U tasks -d task_read \
  -c "select task_id, title, status, version, last_event_sequence from task_read_model order by updated_at desc, task_id;"

echo
echo "Read store: projection checkpoint."
docker compose exec -T read-postgres psql -U tasks -d task_read \
  -c "select projection_name, last_global_sequence, updated_at from projection_checkpoint order by projection_name;"
