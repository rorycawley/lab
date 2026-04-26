-- BFF service account.
--
-- Auth happens at the OIDC layer (Keycloak issues an ID token, the BFF
-- validates it). Postgres only ever sees the BFF's service identity.
-- The user's identity reaches the database as a TEXT column (`sub`),
-- not as a Postgres role.
CREATE ROLE bffapp WITH LOGIN PASSWORD 'bffpass';
GRANT CONNECT ON DATABASE pocdb TO bffapp;

-- User profile, keyed by Keycloak's `sub` claim. The BFF upserts a row
-- on every successful login. There are no credentials here.
CREATE TABLE user_profile (
    sub                 TEXT PRIMARY KEY,
    email               TEXT,
    preferred_username  TEXT,
    display_name        TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Per-user notes. The `sub` column is the only link to Keycloak
-- identity. The BFF translates the session cookie into a sub before
-- it ever talks to this table.
CREATE TABLE notes (
    id          SERIAL PRIMARY KEY,
    sub         TEXT        NOT NULL REFERENCES user_profile(sub) ON DELETE CASCADE,
    text        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX notes_sub_idx ON notes(sub);

GRANT SELECT, INSERT, UPDATE ON user_profile TO bffapp;
GRANT SELECT, INSERT, DELETE ON notes        TO bffapp;
GRANT USAGE, SELECT ON SEQUENCE notes_id_seq TO bffapp;
