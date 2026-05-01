# Phase 10: Connection Pool and Credential Rotation Behavior


Phase 10 makes the Python app use a PostgreSQL connection pool and verifies the
pool is configured around Vault credential lifetime.

Goal:

```text
Use pooled database connections without turning short-lived Vault credentials
into long-lived app access.
```

This phase adds:

```text
App endpoint: GET /pool/status
App endpoint: POST /pool/reload
Command: make verify-pool
```

The app now:

- reads `/vault/secrets/db-creds`
- creates a psycopg connection pool from the rendered username/password
- sets pool max lifetime below the Vault runtime credential TTL
- rebuilds the pool when explicitly reloaded
- rebuilds the pool automatically when the rendered credential file changes

Vault PostgreSQL revocation SQL now terminates active sessions before dropping a
generated role, which is required when pooled connections may still be open.

Acceptance criteria:

- app exposes pool status
- pool max lifetime is lower than the Vault runtime credential TTL
- pooled app connections can perform CRUD
- app can rebuild the pool from `/vault/secrets/db-creds`
- app still connects as a generated `v-...` database user after pool rebuild
- Vault revocation SQL is pool-safe because it terminates active sessions

Verify only pool behavior:

```sh
make verify-pool
```

