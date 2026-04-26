-- Backend service identity for the JWT proxy.
--
-- The proxy connects to Postgres as `pgproxy` after it has already
-- validated the caller's JWT against Keycloak. Once connected, the
-- proxy issues `SET ROLE <claim>` on this session, so every query the
-- caller runs executes with the *role*, not as pgproxy itself.
--
-- pgproxy therefore needs the union of every role the proxy might
-- SET, but no privileges of its own beyond CONNECT.
CREATE ROLE pgproxy WITH LOGIN PASSWORD 'pgproxypass';
GRANT CONNECT ON DATABASE pocdb TO pgproxy;

-- Roles the JWT `pg_role` claim can resolve to. They have no LOGIN
-- attribute on purpose: nobody authenticates *as* these roles. They
-- are only reachable via SET ROLE from pgproxy.
CREATE ROLE pgreader NOLOGIN;
CREATE ROLE pgwriter NOLOGIN;

GRANT pgreader, pgwriter TO pgproxy;

-- Demo table the test harness reads.
CREATE TABLE messages (
    id          SERIAL PRIMARY KEY,
    text        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO messages (text) VALUES
    ('hello from postgres, gated by keycloak');

GRANT SELECT ON messages TO pgreader;
GRANT SELECT, INSERT ON messages TO pgwriter;
GRANT USAGE, SELECT ON SEQUENCE messages_id_seq TO pgwriter;
