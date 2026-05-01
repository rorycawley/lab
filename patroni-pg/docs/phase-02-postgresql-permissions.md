# Phase 2: PostgreSQL Permissions Without Vault


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

