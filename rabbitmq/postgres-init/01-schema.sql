-- Single-table outbox: domain_events doubles as the event store and the outbox.
-- A row with published_at IS NULL is "pending publish" to the broker.
-- The relay drains those rows in global_sequence order and stamps published_at
-- only after RabbitMQ confirms the publish.
CREATE TABLE IF NOT EXISTS domain_events (
    global_sequence BIGSERIAL PRIMARY KEY,
    event_id        UUID NOT NULL UNIQUE,
    stream_id       TEXT NOT NULL,
    stream_version  INTEGER NOT NULL,
    event_type      TEXT NOT NULL,
    event_data      JSONB NOT NULL,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at    TIMESTAMPTZ,
    CONSTRAINT domain_events_stream_version_unique
        UNIQUE (stream_id, stream_version)
);

CREATE INDEX IF NOT EXISTS idx_domain_events_unpublished
    ON domain_events (global_sequence)
    WHERE published_at IS NULL;

-- Command-side idempotency: same Idempotency-Key returns the cached response.
CREATE TABLE IF NOT EXISTS command_idempotency (
    idempotency_key TEXT PRIMARY KEY,
    event_id        UUID NOT NULL,
    response        JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Consumer-side dedup: subscriber records every event_id it has processed.
CREATE TABLE IF NOT EXISTS processed_events (
    event_id     UUID PRIMARY KEY,
    routing_key  TEXT NOT NULL,
    payload      JSONB NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
