CREATE TABLE IF NOT EXISTS command_idempotency (
    idempotency_key TEXT PRIMARY KEY,
    request_hash TEXT NOT NULL,
    event_id UUID NOT NULL UNIQUE REFERENCES domain_events (event_id),
    global_sequence BIGINT NOT NULL UNIQUE REFERENCES domain_events (global_sequence),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE command_idempotency IS
'Maps each command idempotency key to the event created by the first successful request.';

COMMENT ON COLUMN command_idempotency.request_hash IS
'Hash of the command payload. Reusing a key with a different payload is rejected.';
