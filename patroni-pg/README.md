# Vault + PostgreSQL Security Demo

This proof of concept demonstrates a zero-trust, defense-in-depth access model
for a Python workload in Kubernetes using Vault-issued PostgreSQL credentials.

The first track is intentionally not a PostgreSQL HA demo. Patroni, HAProxy,
replication, floating IPs, and failover are out of scope until the security
model is understood and proven.

## What This Demo Proves

```text
A Kubernetes workload proves its identity.
Vault verifies that identity.
Vault policy authorises only the required secret path.
Vault issues short-lived PostgreSQL credentials.
PostgreSQL enforces least-privilege permissions.
NetworkPolicy restricts traffic paths.
TLS protects traffic.
Audit logs prove what happened.
```

The core principle:

```text
The app is not trusted because it is inside Kubernetes.
The app is trusted only after identity, policy, network, TLS, and database checks succeed.
```

## Target Architecture

```text
Kubernetes cluster

namespace: demo
  Python app Pod
  ServiceAccount: demo-app
  Vault Agent sidecar
  Rendered file: /vault/secrets/db-creds

namespace: vault
  Vault dev server Deployment
  TLS proxy using a cert-manager certificate
  Vault Agent Injector
  Vault Kubernetes auth method
  Vault database secrets engine
  Vault audit devices

Docker Compose
  PostgreSQL with TLS-only TCP access
  database: demo_registry
  schema: registry
  table: company
  app_runtime role
  migration_runtime role
  schema_owner role
```

## Build Order

```text
Phase 0  Security model and demo contract
Phase 1  Kubernetes foundation
Phase 2  PostgreSQL permissions without Vault
Phase 3  Vault foundation and audit
Phase 4  Vault Kubernetes auth
Phase 5  Vault policies
Phase 6  Vault database secrets engine
Phase 7  Vault Agent Injector
Phase 8  Python app with dynamic DB credentials
Phase 9  Denied-operation proof
Phase 10 Connection pool and credential rotation behavior
Phase 11 TLS with cert-manager
Phase 12 NetworkPolicy
Phase 13 Container hardening
Phase 14 Audit evidence script
Phase 15 Rotation, revocation, and recovery
Phase 16 Repeatability and IaC
```

## Phase 0: Security Model and Demo Contract

Phase 0 defines what the demo must prove before deploying services.

Acceptance criteria:

- namespaces are named `demo`, `vault`, and `database`
- workload identity is fixed as `demo/demo-app`
- database roles are defined as `schema_owner`, `migration_runtime`, and `app_runtime`
- Vault credential paths are fixed as:
  - `database/creds/demo-app-runtime`
  - `database/creds/demo-app-migrate`
- allowed network flows are defined as:
  - `demo/demo-app -> vault/vault:8200`
  - `demo/demo-app -> database/postgres:5432`
  - `vault/vault -> database/postgres:5432`
- denied cases are listed and later testable
- no runtime database password will live in Git, an image, an environment variable,
  Deployment YAML, or a Kubernetes Secret
- one command will eventually prove the demo end to end

Denied cases this repo must eventually prove:

- `demo/default` cannot authenticate to Vault as the app
- `other-namespace/demo-app` cannot authenticate to Vault as the app
- a random Pod cannot get runtime database credentials
- the runtime app cannot request migration credentials
- the runtime app cannot perform PostgreSQL DDL or admin operations
- unapproved Pods cannot reach Vault or PostgreSQL once NetworkPolicy is active
- revoked generated PostgreSQL credentials stop working

## Phase 1: Kubernetes Foundation

Phase 1 creates only Kubernetes identity primitives. It does not deploy Vault,
PostgreSQL, an app, TLS, or NetworkPolicy yet.

Goal:

```text
Create namespaces, a dedicated app ServiceAccount, and a minimal RBAC baseline.
```

Acceptance criteria:

- namespace `demo` exists
- namespace `vault` exists
- namespace `database` exists
- ServiceAccount `demo-app` exists in namespace `demo`
- the app workload will not use the `default` ServiceAccount
- no Vault role will later be bound to the `default` ServiceAccount
- `demo/demo-app` cannot list Kubernetes Secrets
- `demo/demo-app` cannot list Pods
- `demo/demo-app` cannot read ConfigMaps
- `demo/demo-app` cannot read resources in other namespaces

Run Phase 1:

```sh
make up
```

Verify Phase 1:

```sh
make verify
```

Check current state:

```sh
make status
```

Remove Phase 1 resources:

```sh
make clean
```

Validate manifests without applying them:

```sh
make check-local
```

## Phase 2: PostgreSQL Permissions Without Vault

Phase 2 deploys a single PostgreSQL instance and proves the database
authorization model before Vault is introduced.

Goal:

```text
Prove that PostgreSQL grants enforce least privilege even when a workload has
valid database credentials.
```

This phase creates:

```text
Docker Compose service: postgres
service: host.rancher-desktop.internal:5432 from Kubernetes
database: demo_registry
schema: registry
table: registry.company
base roles: schema_owner, migration_runtime, app_runtime
temporary test logins: phase2_app_user, phase2_migration_user
```

The temporary Phase 2 login passwords are generated into `.runtime/postgres.env`
at apply time. They are not committed to Git. These temporary users exist only
to prove PostgreSQL permissions before Vault starts issuing dynamic credentials.
Later phases replace them with Vault-generated users.

Acceptance criteria:

- PostgreSQL is running in Docker Compose
- Docker Compose PostgreSQL is reachable from Kubernetes at `host.rancher-desktop.internal:5432`
- database `demo_registry` exists
- schema `registry` exists
- table `registry.company` exists
- `schema_owner` owns schema/table objects
- `app_runtime` can `SELECT`, `INSERT`, `UPDATE`, and `DELETE` on `registry.company`
- `app_runtime` cannot `DROP TABLE registry.company`
- `app_runtime` cannot `CREATE TABLE registry.bad_idea`
- `app_runtime` cannot `CREATE ROLE attacker`
- `app_runtime` cannot `CREATE DATABASE attacker_db`
- `migration_runtime` can perform controlled migration-style schema changes

Run Phase 1 and Phase 2:

```sh
make up
```

Verify only PostgreSQL permissions:

```sh
make verify-postgres
```

## Phase 3: Vault Foundation and Audit

Phase 3 deploys Vault and proves it is reachable, initialized, unsealed, and
emitting audit evidence. It does not configure Kubernetes auth, Vault policy, the
database secrets engine, or application credential injection yet.

Goal:

```text
Run Vault, understand the unseal model, and capture audit evidence before any
application trusts Vault.
```

This phase uses Vault dev mode:

```text
Vault starts initialized.
Vault starts unsealed.
The dev root token is generated into a Kubernetes Secret at apply time.
Vault data is not durable.
Restarting Vault loses configuration and state.
This is for learning the control flow, not for production.
```

Production-shaped Vault will be handled later with persistent storage, an
explicit unseal or auto-unseal model, and stronger audit storage.

Acceptance criteria:

- Vault is running in namespace `vault`
- Service `vault.vault.svc.cluster.local:8200` exists
- `vault status` works inside the Vault Pod
- Vault is initialized
- Vault is unsealed
- the chosen unseal model is documented as dev mode
- Vault audit logging is enabled
- an allowed Vault request is visible in audit logs
- a denied Vault request is visible in audit logs
- audit backpressure risk is documented

Audit caveat:

```text
This phase enables one file audit device to stdout for demo visibility.
For production, use at least two audit devices and monitor the backing storage or
logging pipeline. A blocked audit device can affect Vault availability.
```

Run Phase 3:

```sh
make vault
```

Verify only Vault foundation and audit:

```sh
make verify-vault
```

## Phase 4: Vault Kubernetes Auth

Phase 4 configures Vault to verify Kubernetes workload identity using the
Kubernetes TokenReview API.

Goal:

```text
Vault accepts only the exact Kubernetes identity demo/demo-app for the demo app
role, and rejects default or wrong-namespace identities.
```

This phase uses the preferred in-cluster pattern:

```text
Vault runs as ServiceAccount vault/vault-auth.
Only vault/vault-auth is bound to system:auth-delegator.
Vault uses its own in-pod ServiceAccount token to call TokenReview.
Client application ServiceAccounts do not need TokenReview permission.
```

This phase creates:

```text
ServiceAccount: vault/vault-auth
ClusterRoleBinding: vault-tokenreview-auth-delegator
Vault auth method: kubernetes/
Vault auth role: demo-app
Bound identity: ServiceAccount demo-app in namespace demo
```

Acceptance criteria:

- ServiceAccount `vault-auth` exists in namespace `vault`
- `vault-auth` can create TokenReview requests
- `demo/demo-app` cannot create TokenReview requests
- Vault Kubernetes auth method is enabled
- Vault role `demo-app` is bound to `demo/demo-app`
- `demo/demo-app` can authenticate to Vault through Kubernetes auth
- `demo/default` cannot authenticate as the app
- `phase4-other/demo-app` cannot authenticate as the app

Run Phase 4:

```sh
make vault-auth
```

Verify only Vault Kubernetes auth:

```sh
make verify-vault-auth
```

## Phase 5: Vault Policies

Phase 5 configures Vault authorization after Phase 4 proved Kubernetes
authentication.

Goal:

```text
Runtime and migration identities can authenticate to Vault, but each identity is
authorized only for its own future database credential path.
```

This phase creates:

```text
ServiceAccount: demo/demo-migrate
Vault policy: demo-app-runtime
Vault policy: demo-app-migrate
Vault auth role: demo-app
Vault auth role: demo-migrate
```

Runtime policy:

```hcl
path "database/creds/demo-app-runtime" {
  capabilities = ["read"]
}
```

Migration policy:

```hcl
path "database/creds/demo-app-migrate" {
  capabilities = ["read"]
}
```

Acceptance criteria:

- `demo/demo-app` can authenticate to Vault through role `demo-app`
- `demo/demo-app` receives only the `demo-app-runtime` policy
- runtime identity has `read` capability on `database/creds/demo-app-runtime`
- runtime identity has `deny` capability on `database/creds/demo-app-migrate`
- runtime identity has `deny` capability on Vault config paths such as `sys/auth`
- `demo/demo-migrate` can authenticate to Vault through role `demo-migrate`
- `demo/demo-migrate` receives only the `demo-app-migrate` policy
- migration identity has `read` capability on `database/creds/demo-app-migrate`
- migration identity has `deny` capability on `database/creds/demo-app-runtime`
- migration identity has `deny` capability on Vault config paths such as `sys/auth`
- runtime ServiceAccount cannot authenticate as the migration Vault role

Important limitation:

```text
database/creds/demo-app-runtime and database/creds/demo-app-migrate do not issue
credentials yet. Phase 5 proves policy boundaries. Phase 6 configures the Vault
database secrets engine so those paths become real dynamic credential endpoints.
```

Run Phase 5:

```sh
make vault-policies
```

Verify only Vault policies:

```sh
make verify-vault-policies
```

## Phase 6: Vault Database Secrets Engine

Phase 6 makes the policy paths from Phase 5 real by enabling Vault's database
secrets engine and configuring PostgreSQL dynamic credentials.

Goal:

```text
Vault issues short-lived PostgreSQL users for runtime and migration identities,
and PostgreSQL still enforces the role grants from Phase 2.
```

This phase creates:

```text
PostgreSQL management role: vault_admin
Vault secrets engine: database/
Vault connection config: database/config/demo-postgres
Vault dynamic role: database/roles/demo-app-runtime
Vault dynamic role: database/roles/demo-app-migrate
Credential path: database/creds/demo-app-runtime
Credential path: database/creds/demo-app-migrate
```

The `vault_admin` password is generated into `.runtime/vault-postgres.env` at
apply time. It is used only by Vault to create and revoke generated database
users. It is not an app runtime password and is not committed to Git.

Acceptance criteria:

- Vault database secrets engine is enabled
- Vault can connect to PostgreSQL
- Vault can issue runtime PostgreSQL credentials
- runtime credentials have a lease
- runtime generated user inherits `app_runtime`
- runtime generated user can `SELECT`, `INSERT`, `UPDATE`, and `DELETE`
- runtime generated user cannot `DROP TABLE`
- runtime generated user cannot `CREATE ROLE`
- runtime identity cannot read migration credentials
- Vault can issue migration PostgreSQL credentials
- migration credentials have a lease
- migration generated user inherits `migration_runtime`
- migration generated user can perform controlled schema changes
- migration identity cannot read runtime credentials
- revoking the runtime lease makes old runtime credentials fail
- revoking the migration lease makes old migration credentials fail

Run Phase 6:

```sh
make vault-db
```

Verify only Vault database dynamic credentials:

```sh
make verify-vault-db
```

## Phase 7: Vault Agent Injector

Phase 7 installs the Vault Agent Injector and proves that annotated Pods are
mutated with a Vault Agent init container and sidecar.

Goal:

```text
The application container can consume a rendered local credential file without
calling the Vault API itself.
```

This phase installs:

```text
Helm release: vault-agent-injector
Deployment: vault/vault-agent-injector-agent-injector
MutatingWebhookConfiguration: vault-agent-injector-agent-injector-cfg
Smoke Pod: demo/vault-injector-smoke
Rendered file: /vault/secrets/db-creds
```

The smoke Pod uses `demo/demo-app` and these annotations:

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "demo-app"
vault.hashicorp.com/service: "https://vault.vault.svc.cluster.local:8200"
vault.hashicorp.com/tls-secret: "vault-ca"
vault.hashicorp.com/ca-cert: "/vault/tls/ca.crt"
vault.hashicorp.com/tls-server-name: "vault.vault.svc.cluster.local"
vault.hashicorp.com/agent-inject-secret-db-creds: "database/creds/demo-app-runtime"
vault.hashicorp.com/agent-inject-perms-db-creds: "0400"
```

Acceptance criteria:

- Vault Agent Injector Deployment is ready
- Vault Agent Injector mutating webhook exists
- annotated smoke Pod is mutated
- Vault Agent init container is injected
- Vault Agent sidecar container is injected
- `/vault/secrets/db-creds` exists in the app container
- rendered file contains `DB_USERNAME` and `DB_PASSWORD`
- rendered file permissions are `0400`
- an unannotated Pod is not injected

Important limitation:

```text
This phase proves injection and file rendering only. The Python app that reads
the file and reconnects with dynamic credentials comes in Phase 8.
```

Run Phase 7:

```sh
make vault-injector
```

Verify only Vault Agent Injector:

```sh
make verify-vault-injector
```

## Phase 8: Python App With Dynamic DB Credentials

Phase 8 replaces the injector smoke Pod with a real Python application that
uses the rendered Vault Agent file.

Goal:

```text
The app reads /vault/secrets/db-creds, connects to PostgreSQL with Vault-issued
runtime credentials, performs CRUD, and proves forbidden database operations are
denied.
```

This phase creates:

```text
Docker image: python-postgres-vault-demo:phase8
Deployment: demo/python-postgres-demo
Service: demo/python-postgres-demo
Vault-rendered file: /vault/secrets/db-creds
```

The app reads:

```text
DB_USERNAME and DB_PASSWORD from /vault/secrets/db-creds
```

The app does not receive:

```text
DB_PASSWORD as an environment variable
DB_PASSWORD in Deployment YAML
DB_PASSWORD in image contents
```

Acceptance criteria:

- Python app image builds
- app Deployment is created in namespace `demo`
- app runs as ServiceAccount `demo-app`
- Vault Agent sidecar is injected
- `/vault/secrets/db-creds` exists in the app container
- app has no database password in Deployment YAML
- `/healthz` works
- app connects as a Vault-generated `v-demo-app-runtime...` database user
- app can `INSERT`, `SELECT`, `UPDATE`, and `DELETE` `registry.company` rows
- app proves `DROP TABLE` is denied
- app proves `CREATE ROLE` is denied

Run Phase 8:

```sh
make deploy-app
```

Verify only the Python app:

```sh
make verify-app
```

## Phase 9: Denied-Operation Proof and Evidence

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

## Phase 10: Connection Pool and Credential Rotation Behavior

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

## Phase 11: TLS With cert-manager

Phase 11 installs cert-manager, creates a demo CA, issues service certificates,
and verifies that Vault and PostgreSQL are no longer treated as plaintext
endpoints.

Goal:

```text
Use cert-manager-issued certificates so Vault Agent, Vault, PostgreSQL, and the
Python app verify the endpoints they talk to.
```

This phase creates:

```text
Helm release: cert-manager
ClusterIssuer: demo-selfsigned-bootstrap
ClusterIssuer: demo-ca
Certificate: vault/vault-tls
Certificate: database/postgres-tls
ConfigMap: demo/postgres-ca
ConfigMap: vault/postgres-ca
Secret: demo/vault-ca
```

Vault remains a dev-mode server for this learning phase, but the Kubernetes
Service endpoint is HTTPS:

```text
Vault dev listener: 127.0.0.1:8201 inside the Pod
Vault service endpoint: https://vault.vault.svc.cluster.local:8200
TLS termination: nginx sidecar using the cert-manager vault-tls Secret
```

PostgreSQL still runs in Docker Compose, not as a Kubernetes StatefulSet. Its
server certificate is issued by cert-manager and exported to
`.runtime/tls/postgres` for Docker Compose to mount.

Acceptance criteria:

- cert-manager is installed
- demo CA ClusterIssuer is ready
- Vault certificate is issued by cert-manager
- PostgreSQL certificate is issued by cert-manager
- Vault HTTPS verifies with the demo CA
- Vault HTTPS does not verify without the demo CA
- Vault Agent uses HTTPS to reach Vault
- Vault database engine reaches PostgreSQL with `sslmode=verify-full`
- PostgreSQL accepts `verify-full` TLS connections
- PostgreSQL rejects plaintext TCP connections
- Python app connects to PostgreSQL with `sslmode=verify-full`
- Python app still uses Vault-generated dynamic credentials

Run Phase 11:

```sh
make tls
make postgres
make vault
make deploy-app
```

Verify only TLS:

```sh
make verify-tls
```

## Phase 12: NetworkPolicy

Phase 12 turns the allowed flows from Phase 0 into Kubernetes NetworkPolicies and
proves that unselected Pods are denied at the network layer, not only at Vault
or PostgreSQL auth.

Goal:

```text
Default-deny ingress and egress in the demo and vault namespaces, then allow
only the contracted flows. A random Pod in either namespace cannot reach Vault
or PostgreSQL on the network even if it forges identity at higher layers.
```

Allowed flows enforced by this phase:

```text
demo Pods labeled app.kubernetes.io/part-of=vault-postgres-security-demo
  -> vault/vault on TCP/8200
demo/python-postgres-demo
  -> host PostgreSQL on TCP/5432
vault/vault
  -> host PostgreSQL on TCP/5432
all Pods in demo and vault
  -> kube-system DNS on UDP/53 and TCP/53
```

Operational flows that must remain open:

```text
kubelet -> demo/python-postgres-demo on TCP/8080  (liveness and readiness probes)
Kubernetes API server -> vault/vault-agent-injector on TCP/8443  (admission webhook)
vault/vault and vault/vault-agent-injector -> Kubernetes API server  (TokenReview, watches)
```

This phase creates:

```text
k8s/15-networkpolicies.yaml
NetworkPolicy: demo/default-deny-all
NetworkPolicy: demo/allow-dns
NetworkPolicy: demo/demo-egress-vault
NetworkPolicy: demo/demo-egress-postgres
NetworkPolicy: demo/app-ingress-http
NetworkPolicy: vault/default-deny-all
NetworkPolicy: vault/allow-dns
NetworkPolicy: vault/vault-ingress-demo
NetworkPolicy: vault/vault-egress-apiserver-and-postgres
NetworkPolicy: vault/vault-injector-webhook
```

Acceptance criteria:

- default-deny ingress and egress are enforced in namespace `demo`
- default-deny ingress and egress are enforced in namespace `vault`
- DNS to kube-system is allowed for every Pod in `demo` and `vault`
- `demo/python-postgres-demo` can still reach `vault/vault` on TCP/8200
- `demo/python-postgres-demo` can still reach PostgreSQL on TCP/5432
- `vault/vault` can still reach PostgreSQL on TCP/5432
- `vault/vault` can still reach the Kubernetes API server for TokenReview
- `vault/vault-agent-injector` can still receive admission webhook calls
- the Vault Agent sidecar in the Python app Pod still renders `/vault/secrets/db-creds`
- a Pod in `demo` without the demo's `part-of` label cannot reach `vault/vault:8200`
- a Pod in `demo` that is not `python-postgres-demo` cannot reach PostgreSQL on TCP/5432
- the denied test Pod can still resolve cluster DNS, so denials are proven at L4

Important limitations of this phase:

```text
PostgreSQL runs in Docker Compose on host.rancher-desktop.internal, outside the
cluster. NetworkPolicy cannot select a host endpoint by namespace or pod, so
egress to PostgreSQL is expressed as TCP/5432 to an ipBlock and is restricted
to the Pods that legitimately need it. PostgreSQL cannot be defended with
ingress NetworkPolicy from inside the cluster.

The Vault Agent Injector admission webhook (TCP/8443) accepts ingress from any
IP. The Kubernetes API server's source IP varies by distribution, so a tighter
selector is left to the Phase 16 IaC track.

NetworkPolicy enforcement requires a CNI that supports it. Rancher Desktop
ships k3s with kube-router, which enforces NetworkPolicy by default. On a
cluster whose CNI does not enforce policy, these manifests apply cleanly but do
not actually deny anything.
```

Run Phase 12:

```sh
make netpol
```

Verify only NetworkPolicies:

```sh
make verify-netpol
```

## Phase 13: Container Hardening

Phase 13 hardens every container in the demo to the Pod Security Admission
"restricted" profile, so a workload that lands in a pod has no Linux
capabilities, no privilege escalation, no writable root filesystem, a
RuntimeDefault seccomp profile, an explicit non-root UID, and explicit
resource requests and limits.

Goal:

```text
Make non-conforming Pods fail at admission, and prove that the conforming Pods
still satisfy every previous phase: dynamic credentials, CRUD, denied DB ops,
TLS, and NetworkPolicy denials.
```

This phase changes:

```text
app/Dockerfile                         non-root UID 1000 with chowned /app
k8s/00-namespaces.yaml                 PSA enforce/audit/warn = restricted on demo and vault
k8s/07-vault-deployment.yaml           securityContext, resources, read-only root with tmpfs volumes
k8s/09-vault-injector-smoke-pod.yaml   securityContext and resources for the smoke Pod
k8s/10-python-app-deployment.yaml      pod and container securityContext, /tmp emptyDir, resources
k8s/14-vault-tls-proxy-configmap.yaml  nginx config writes pid, logs, temp paths to /tmp
scripts/15-install-vault-agent-injector.sh   Helm values for restricted-compatible injector + agent
docker-compose.yml                     no-new-privileges, drop ALL capabilities, add only minimum
```

Per-container hardening shape:

```text
pod-level:
  runAsNonRoot: true
  runAsUser:   1000 (app) | 100 (vault, smoke) | injector chart default
  fsGroup:     1000
  seccompProfile.type: RuntimeDefault

container-level:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem:   true
  capabilities.drop:        [ALL]
  seccompProfile.type:      RuntimeDefault
  resources.requests / resources.limits: cpu and memory both set
```

Vault Agent sidecar:

```text
vault.hashicorp.com/agent-set-security-context: "true"
vault.hashicorp.com/agent-run-as-same-user:     "true"
```

The agent therefore runs as the same UID as the app container, which keeps the
rendered file (`/vault/secrets/db-creds`, mode 0400) readable by the app.

Acceptance criteria:

- namespaces `demo` and `vault` enforce `pod-security.kubernetes.io/enforce: restricted`
- a Pod with `securityContext.privileged: true` is rejected at admission in `demo`
- every Pod in `demo` and `vault` runs as a non-root user
- every container in `demo` and `vault` sets `allowPrivilegeEscalation: false`
- every container drops all Linux capabilities
- every container sets `seccompProfile.type: RuntimeDefault`
- every container has CPU and memory requests and limits
- the Python app container runs with `readOnlyRootFilesystem: true`
- writing to `/` from the app container fails at runtime
- the app's runtime UID is non-zero
- the Vault Agent sidecar still renders `/vault/secrets/db-creds`
- the app still connects with a Vault-generated `v-...` runtime user
- the app still proves `DROP TABLE` and `CREATE ROLE` are denied
- the Phase 12 NetworkPolicy denials still hold

Documented limitations of this phase:

```text
The Vault Agent Injector mutates Pods after admission, so the injected sidecar's
securityContext is set by Helm values on the injector chart, not by the
application Deployment. A change to chart values is required for the sidecar
to satisfy "restricted".

PostgreSQL runs in Docker Compose, not in Kubernetes. We harden it with
no-new-privileges and a minimal capability set, but we do not run it under
read-only root because the official postgres entrypoint requires write access
to several non-volume paths during initialization.

The PSA "restricted" profile is enforced by the Kubernetes API server using a
built-in admission plugin. It does not require an external policy engine such
as Kyverno or OPA Gatekeeper. Production hardening typically adds one of
those engines for image-signature, registry, and supply-chain controls that
PSA does not cover.
```

Run Phase 13 against a fresh cluster:

```sh
make up
```

Re-apply Phase 13 to an already-running cluster from earlier phases:

```sh
make harden
```

Verify only container hardening:

```sh
make verify-harden
```

The verify script requires `jq`.

## Phase 14: Audit Evidence

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

## Requirements

- `kubectl`
- `docker`
- `make`
- `helm`
- `openssl`
- `jq` (used by the Phase 13 verify script)
- access to a Kubernetes cluster

Rancher Desktop, k3d, kind, or a Hetzner Kubernetes cluster are all acceptable
for Phase 1 because this phase only creates namespaces and a ServiceAccount.
