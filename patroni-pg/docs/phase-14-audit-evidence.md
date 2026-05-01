# Phase 14: Audit Evidence


Phase 14 turns every claim from Phase 0 into a specific audit record produced
by Vault, PostgreSQL, or the Kubernetes API server, and packages those records
into a single structured deliverable.

Goal:

```text
The existing make evidence (Phase 9) stays as the human-readable demo.
Phase 14 adds a machine-readable, compliance-shaped artifact next to it: one
command runs the full denied-attempt drill, another emits a JSON evidence
report, and a third verifies the report is complete.
```

This phase changes:

```text
k8s/07-vault-deployment.yaml           add /vault/audit emptyDir for the second audit device
scripts/08-verify-vault.sh             enable a second on-disk audit device alongside stdout
docker-compose.yml                     log_statement=ddl, log_connections, log_line_prefix
scripts/04-clean.sh                    sweep .runtime/audit and the phase4-other namespace
scripts/28-audit-drill.sh              NEW: run all denied cases, capture evidence
scripts/29-audit-evidence-report.sh    NEW: emit JSON + markdown report
scripts/30-verify-audit.sh             NEW: drill + report + assertions
Makefile                               audit-drill, audit-report, verify-audit
```

The drill exercises every denied case from Phase 0 and later, and writes one
evidence file per case to `.runtime/audit/`:

```text
01-default-sa-cannot-login          source: Vault audit (file device)
02-other-namespace-cannot-login     source: Vault audit (file device)
03-runtime-cannot-read-migrate      source: Vault audit (file device)
04-migrate-cannot-read-runtime      source: Vault audit (file device)
05-drop-table-and-create-role       source: app /security/prove-denied + PostgreSQL log
06-netpol-vault                     source: TCP timeout (no positive log on this CNI)
07-netpol-postgres                  source: TCP timeout (no positive log on this CNI)
08-psa-privileged                   source: kube-apiserver admission rejection
09-revoked-lease                    source: PostgreSQL FATAL on revoked role + Vault lease state
```

Report shape (JSON, written to `.runtime/audit/report.json`):

```text
generated_at
identity
  service_account, pod, container_uid
  db_password_env_present (must be false)
  rendered_credential_file (path, mode)
vault
  audit_devices (list)
  counts: kubernetes_logins, runtime_creds_issued, migration_creds_issued,
          permission_denied, invalid_token
postgresql
  ssl_active, connections_logged, ddl_attempts, denied_role_creation_attempts
kubernetes
  psa_enforce: { demo, vault }
  privileged_pod_admission
  networkpolicies: { demo, vault }
denied_cases (status verified|not_run, with evidence path)
correlation_example (one Vault login -> credential read -> PG connection -> SQL)
```

Acceptance criteria:

- Vault has at least two audit devices and both record the same events
- PostgreSQL logs every connection, disconnection, and DDL statement with a
  timestamp, role, and database
- `make audit-drill` runs all denied cases and exits 0 only if every denial
  happened as expected
- `make audit-report` writes `.runtime/audit/report.json` and a markdown sibling
- `make verify-audit` asserts the report is valid JSON, all denied cases are
  `verified`, both PSA enforce labels are `restricted`, the privileged-Pod
  admission was rejected, and the Vault counts are non-zero
- The Phase 9 `make evidence` continues to work unchanged

Documented limitations of this phase:

```text
Vault audit hashes most fields by default (HMAC) so client tokens and
credentials do not appear in plaintext. The report shows event counts and
paths, not secret material. Production should ship the on-disk audit log to a
durable backend (file -> Fluent Bit -> SIEM) and monitor for backpressure on
both audit devices.

PostgreSQL native logging captures DDL and connections but not row-level
reads. Production typically adds the pgaudit extension, which classifies
events as READ / WRITE / DDL / ROLE / MISC. We document this as the
production upgrade rather than ship a custom Postgres image.

NetworkPolicy denials do not produce a positive audit record on most CNIs
(including k3s + kube-router). The drill proves the denial by attempting
the connection and confirming a TCP timeout, but no log entry says
"NetworkPolicy denied X." Production needs a CNI with policy logging
(Cilium Hubble, Calico flow logs) for that.
```

Run only the audit drill:

```sh
make audit-drill
```

Generate the report:

```sh
make audit-report
```

Run drill + report + assertions:

```sh
make verify-audit
```

