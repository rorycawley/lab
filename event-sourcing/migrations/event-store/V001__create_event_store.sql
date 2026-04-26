CREATE TABLE IF NOT EXISTS domain_events (
    global_sequence BIGSERIAL PRIMARY KEY,
    event_id UUID NOT NULL UNIQUE,
    stream_id TEXT NOT NULL,
    stream_version INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    event_data JSONB NOT NULL,
    correlation_id UUID NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT domain_events_stream_version_unique
        UNIQUE (stream_id, stream_version)
);

CREATE INDEX IF NOT EXISTS idx_domain_events_stream_id
ON domain_events (stream_id);

CREATE INDEX IF NOT EXISTS idx_domain_events_event_type
ON domain_events (event_type);

COMMENT ON TABLE domain_events IS
'The append-only event store. Each row is one immutable business fact.';

COMMENT ON COLUMN domain_events.global_sequence IS
'Global ordering for all events. Projectors use this as their cursor.';

COMMENT ON COLUMN domain_events.stream_id IS
'Aggregate stream identifier, for example task-<uuid>.';

COMMENT ON COLUMN domain_events.stream_version IS
'Per-stream optimistic concurrency version.';

COMMENT ON COLUMN domain_events.event_type IS
'The kind of fact that happened, for example task-created.';

COMMENT ON COLUMN domain_events.event_data IS
'The event payload as JSONB. This is the source of truth for rebuilding state.';
