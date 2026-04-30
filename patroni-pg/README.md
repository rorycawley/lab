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
  Vault server
  Vault Agent Injector
  Vault Kubernetes auth method
  Vault database secrets engine
  Vault audit devices

namespace: database
  PostgreSQL
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
Phase 10 TLS
Phase 11 NetworkPolicy
Phase 12 Container hardening
Phase 13 Audit evidence script
Phase 14 Rotation, revocation, and recovery
Phase 15 Repeatability and IaC
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
namespace: database
service: postgres.database.svc.cluster.local
database: demo_registry
schema: registry
table: registry.company
base roles: schema_owner, migration_runtime, app_runtime
temporary test logins: phase2_app_user, phase2_migration_user
```

The temporary Phase 2 login passwords are generated into a Kubernetes Secret at
apply time. They are not committed to Git. These temporary users exist only to
prove PostgreSQL permissions before Vault starts issuing dynamic credentials.
Later phases replace them with Vault-generated users.

Acceptance criteria:

- PostgreSQL is running in namespace `database`
- Service `postgres.database.svc.cluster.local:5432` exists
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

The `vault_admin` password is generated into a Kubernetes Secret at apply time.
It is used only by Vault to create and revoke generated database users. It is not
an app runtime password.

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

## Requirements

- `kubectl`
- `make`
- `helm`
- `openssl`
- access to a Kubernetes cluster

Rancher Desktop, k3d, kind, or a Hetzner Kubernetes cluster are all acceptable
for Phase 1 because this phase only creates namespaces and a ServiceAccount.
