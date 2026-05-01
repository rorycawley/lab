# Phase 15: Rotation, Revocation, and Recovery


Phase 15 turns the demo's lifecycle claims into runnable drills that exercise
the operational levers an SRE actually pulls: rotate the database engine root
credential, mass-revoke a class of outstanding credentials, and recover from a
Vault outage and a PostgreSQL restart.

Goal:

```text
Phase 6/10/14 proved the primitives (a single lease can be revoked, the pool
rotates around the TTL, an outage doesn't break TLS). Phase 15 proves the
operations: rotate root, kill all credentials of class X, ride out a Vault
outage, ride out a PostgreSQL restart.
```

This phase changes:

```text
scripts/31-verify-rotation.sh    NEW: rotate database engine root, prove old password fails, app continues CRUD
scripts/32-verify-revocation.sh  NEW: vault lease revoke -prefix on runtime, prove pool dies and rebuilds with a new user
scripts/33-verify-recovery.sh    NEW: Vault outage drill (replicas=0/1) + PostgreSQL container restart drill
scripts/34-recover-vault.sh      NEW: operator helper to re-bootstrap a destroyed dev-mode Vault
scripts/35-verify-rrr.sh         NEW: thin wrapper that runs all three drills in order
Makefile                         rotate, revoke-runtime, recover, recover-vault, verify-rrr
```

The three operational levers:

```text
rotation
  vault write -force database/rotate-root/demo-postgres
  After this, only Vault knows the vault_admin password. The drill confirms
  the old password no longer authenticates to PostgreSQL, Vault still issues
  runtime credentials, and the app continues to do CRUD as a v-... user.

revocation
  vault lease revoke -prefix database/creds/demo-app-runtime
  Kills every outstanding runtime credential at once. The drill confirms the
  app's existing pool fails on its next query (revocation SQL terminates
  active sessions), POST /pool/reload rebuilds against a freshly rendered
  credential file, and the new pool connects as a different v-... user.

recovery
  Vault outage:        kubectl scale deployment vault -n vault --replicas=0
  PostgreSQL restart:  docker compose restart postgres
  The drill confirms the existing pool keeps serving CRUD while Vault is at
  replicas=0, that scaling Vault back to 1 restores normal operation, and
  that the pool reconnects after a PostgreSQL container restart.
```

Acceptance criteria:

- `make rotate` rotates the database engine root credential, the old password
  no longer authenticates to PostgreSQL, and the app continues to do CRUD
  with newly issued runtime credentials
- `make revoke-runtime` revokes every outstanding `database/creds/demo-app-runtime`
  lease, the app's existing pool fails on the next query, `POST /pool/reload`
  rebuilds the pool against a fresh credential file, and the app reconnects
  as a different `v-...` user
- The Vault on-disk audit log shows both the rotation and the prefix-revoke
  as discrete events
- `make recover` survives a Vault outage (the app's pool keeps serving CRUD
  while Vault is at replicas=0) and survives a PostgreSQL container restart
  (the pool reconnects within a small number of retries)
- `make recover-vault` re-bootstraps a destroyed dev-mode Vault and the app
  comes back to a working state without manual intervention beyond the single
  command
- `make verify-rrr` runs all three drills and passes, end to end
- Every prior verify (`verify-phase-1` through `verify-audit`) continues to
  pass after each drill

Documented limitations of this phase:

```text
Vault dev mode loses all state on Pod restart. The recover-vault target re-runs
the bootstrap chain instead of restoring state. In production, Vault uses
integrated storage (Raft) with auto-unseal (KMS, HSM, or Shamir), so a Vault
Pod restart preserves auth methods, policies, secrets engines, and leases.

Cert-manager handles certificate rotation automatically before expiry, so this
phase does not include a cert-rotation drill. Force-renewing a cert is
straightforward (delete the Secret, cert-manager re-issues), but PostgreSQL in
Docker Compose binds the file at start, so a Postgres TLS rotation also
requires a Compose restart.

Vault Agent sidecar template re-rendering is event-driven on lease lifetime,
not on a wall-clock schedule. The revocation drill therefore explicitly calls
POST /pool/reload to force the app to read the freshly rendered file rather
than waiting for the next render cycle.
```

Run individual drills:

```sh
make rotate
make revoke-runtime    # destructive: kills all in-flight runtime credentials
make recover
```

Run all three:

```sh
make verify-rrr
```

Re-bootstrap a destroyed Vault (operator action, not a passing test):

```sh
make recover-vault
```

