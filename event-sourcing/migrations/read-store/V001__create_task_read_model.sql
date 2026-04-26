CREATE TABLE IF NOT EXISTS task_read_model (
    task_id UUID PRIMARY KEY,
    title TEXT NOT NULL,
    assigned_to TEXT,
    status TEXT NOT NULL,
    version INTEGER NOT NULL,
    last_event_sequence BIGINT NOT NULL,
    completed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS projection_checkpoint (
    projection_name TEXT PRIMARY KEY,
    last_global_sequence BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO projection_checkpoint (projection_name, last_global_sequence)
VALUES ('task_read_model', 0)
ON CONFLICT (projection_name) DO NOTHING;

COMMENT ON TABLE task_read_model IS
'The CQRS read model. It is derived from events and optimized for queries.';

COMMENT ON TABLE projection_checkpoint IS
'Records the last event sequence processed by each projector.';
