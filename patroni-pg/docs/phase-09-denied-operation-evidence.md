# Phase 9: Denied-Operation Proof and Evidence


Phase 9 turns the security claims into a single readable evidence run.

Goal:

```text
Show the workload identity, rendered credential file, allowed app behavior,
forbidden database behavior, Vault audit evidence, and PostgreSQL runtime state
in one command.
```

This phase adds:

```text
App endpoint: POST /security/evidence
Command: make evidence
```

Acceptance criteria:

- evidence output shows the app Pod uses ServiceAccount `demo-app`
- evidence output shows Vault Agent containers are present
- evidence output shows `DB_PASSWORD` is absent from the app environment
- evidence output shows `/vault/secrets/db-creds` exists
- evidence output shows the app connects as a generated `v-...` database user
- evidence output shows CRUD succeeds
- evidence output shows `DROP TABLE` is denied
- evidence output shows `CREATE ROLE` is denied
- evidence output includes Vault audit counts for login/runtime credential access
- evidence output includes PostgreSQL Docker Compose runtime state

Run evidence:

```sh
make evidence
```

