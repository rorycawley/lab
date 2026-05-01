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

## Phase Index

Detailed documentation for each phase is in `docs/`:

- [Phase 0: Security Model and Demo Contract](docs/phase-00-security-model.md)
- [Phase 1: Kubernetes Foundation](docs/phase-01-kubernetes-foundation.md)
- [Phase 2: PostgreSQL Permissions Without Vault](docs/phase-02-postgresql-permissions.md)
- [Phase 3: Vault Foundation and Audit](docs/phase-03-vault-foundation-and-audit.md)
- [Phase 4: Vault Kubernetes Auth](docs/phase-04-vault-kubernetes-auth.md)
- [Phase 5: Vault Policies](docs/phase-05-vault-policies.md)
- [Phase 6: Vault Database Secrets Engine](docs/phase-06-vault-database-secrets.md)
- [Phase 7: Vault Agent Injector](docs/phase-07-vault-agent-injector.md)
- [Phase 8: Python App With Dynamic DB Credentials](docs/phase-08-python-app-dynamic-creds.md)
- [Phase 9: Denied-Operation Proof and Evidence](docs/phase-09-denied-operation-evidence.md)
- [Phase 10: Connection Pool and Credential Rotation Behavior](docs/phase-10-connection-pool.md)
- [Phase 11: TLS With cert-manager](docs/phase-11-tls-cert-manager.md)
- [Phase 12: NetworkPolicy](docs/phase-12-networkpolicy.md)
- [Phase 13: Container Hardening](docs/phase-13-container-hardening.md)
- [Phase 14: Audit Evidence](docs/phase-14-audit-evidence.md)
- [Phase 15: Rotation, Revocation, and Recovery](docs/phase-15-rotation-revocation-recovery.md)
- [Phase 16: Repeatability and IaC](docs/phase-16-repeatability-and-iac.md)

## Quick Start

```sh
make doctor      # confirm tools and cluster
make up          # apply phases 1-16 and verify
make verify      # rerun verification only
make clean       # tear down (wipes K8s namespaces, Compose volumes, runtime artifacts, Terraform state)
make reset       # timed clean + up + verify, single command
```

For lifecycle drills:

```sh
make rotate          # rotate the Vault database engine root credential
make revoke-runtime  # mass-revoke runtime credentials (destructive)
make recover         # Vault outage + Postgres restart drills
make recover-vault   # re-bootstrap a destroyed dev-mode Vault
make verify-rrr      # rotation + revocation + recovery drills
```

For reports and IaC:

```sh
make audit-drill     # Phase 14 denied-attempt drill
make audit-report    # JSON evidence report (.runtime/audit/report.json)
make verify-iac      # Terraform + NetworkPolicy drift check
make tf-plan         # show pending Vault config changes
```

## Requirements

- `kubectl`
- `docker`
- `make`
- `helm`
- `openssl`
- `jq` (used by Phase 13+ verify scripts)
- `terraform` >= 1.5 (used by Phase 16)
- access to a Kubernetes cluster

Run `make doctor` to confirm all of the above are present and the cluster is reachable.

Rancher Desktop, k3d, kind, or a Hetzner Kubernetes cluster are all acceptable
for Phase 1 because this phase only creates namespaces and a ServiceAccount.
