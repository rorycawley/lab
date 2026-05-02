# Kubernetes Migration Job + External Postgres Demo

A learning lab for running a Python application in Kubernetes while its
PostgreSQL database runs outside the cluster in Docker Compose. The lab focuses
on one operational problem:

> How do we run database migrations from Kubernetes without giving the runtime
> application the same database permissions as the migration tool?

The intended shape is deliberately close to a production topology:

- PostgreSQL runs outside Kubernetes.
- The Python API runs as a normal Kubernetes Deployment.
- Database migrations run as one-off Kubernetes Jobs.
- The migration Job is a container image, not a local script.
- The app and the migration Job use different Kubernetes identities.
- The app and the migration Job use different PostgreSQL users.
- All database connections use TLS.
- Network access, Kubernetes RBAC, filesystem permissions, and database grants
  are layered so that no single control carries the whole security model.

## What It Shows

- A Kubernetes workload can reach a PostgreSQL database that is not running in
  Kubernetes.
- A migration container can be run as a Kubernetes Job before the application is
  deployed or upgraded.
- Runtime and migration permissions are intentionally different:
  - the app can read and write application data only;
  - the migrator can change schema and write migration metadata;
  - neither workload gets superuser, database owner, or admin credentials.
- TLS protects the pod-to-database connection even though the database is
  outside the cluster.
- Kubernetes Secrets hold different credentials and client certificates for
  different workloads.
- NetworkPolicy, ServiceAccount separation, Secret scoping, container hardening,
  and PostgreSQL grants combine into a defense-in-depth model.

## Requirements

- Rancher Desktop with Kubernetes enabled
- Docker-compatible CLI
- `kubectl`
- `make`
- `openssl`
- `curl`

The images use `imagePullPolicy: Never`, matching the other labs in this repo.
Rancher Desktop with the Docker-compatible image store can run the locally built
images directly.

## Quick Start

Run the lab from a clean checkout:

```sh
make up
make test-all
```

`make up` runs the full proof:

```text
1. generate a local CA, server cert, app client cert, and migrator client cert
2. start PostgreSQL 16 in Docker Compose with TLS required
3. build migrations-demo-api:demo
4. build migrations-demo-migrator:demo
5. apply Kubernetes ServiceAccounts, ExternalName Service, Secrets, and policies
6. run the db-migrate Kubernetes Job
7. deploy the Python API
8. verify TLS, role separation, denied DDL, denied admin actions, and Secret API RBAC
```

`make test-all` starts a temporary port-forward and proves the API path:

```text
HTTP client
  -> Python API Pod
  -> TLS connection as app_user
  -> app.todos
```

Useful targets:

- `make up` - start Postgres, build images, run migrations, deploy app, verify
- `make test-all` - port-forward the API and run HTTP smoke tests
- `make port-forward` - expose the API at <http://localhost:8080>
- `make status` - show Kubernetes, Docker, and image state
- `make clean` - remove namespace, containers, volumes, images, certs, and logs
- `make full-check` - run `make up`, run `make test-all`, then clean

## Problem

A common shortcut is to let the application start up and run its own schema
migrations. That is convenient, but it couples two different responsibilities:

- serving user traffic;
- changing database structure.

Those responsibilities need different permissions. An API process should not
need `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`, or ownership over migration
history. A migration process needs those privileges briefly, but it does not
need to run all day, serve HTTP traffic, or hold the runtime application's
identity.

This lab makes that split visible.

## Architecture

```text
                              Kubernetes cluster
                        namespace: migrations-demo

  +---------------------------------------------------------------+
  |                                                               |
  |  +----------------------+        +-------------------------+   |
  |  | Python API Pod       |        | Migration Job Pod        |   |
  |  | serviceAccount: app  |        | serviceAccount: migrator |   |
  |  | db user: app_user    |        | db user: migrator_user   |   |
  |  | long-running         |        | short-lived              |   |
  |  | no DDL privileges    |        | DDL privileges on schema |   |
  |  +----------+-----------+        +------------+------------+   |
  |             |                                 |                |
  |             | TLS                             | TLS            |
  |             | app client cert                 | migrator cert        |
  |             |                                 |                |
  |             +-------------+     +-------------+                |
  |                           |     |                              |
  |                           v     v                              |
  |                  +------------------------+                    |
  |                  | Service: external-pg   |                    |
  |                  | type: ExternalName     |                    |
  |                  | host.rancher-desktop  |                    |
  |                  | .internal             |                    |
  |                  +-----------+------------+                    |
  |                              |                                 |
  +------------------------------|---------------------------------+
                                 |
                                 | TLS over host network
                                 v
                    Docker Compose / laptop host

                    +-----------------------------+
                    | PostgreSQL                  |
                    | db: appdb                   |
                    | ssl = on                    |
                    | CA trusts client certs      |
                    | roles:                      |
                    | - app_user                  |
                    | - migrator_user             |
                    | - postgres bootstrap admin  |
                    +-----------------------------+
```

The application and the migration Job use the same network destination but not
the same identity. They resolve the same Kubernetes Service name, connect to the
same PostgreSQL server, and validate the same server certificate. After that,
PostgreSQL authorization decides what each user can do.

## Trust Boundaries

```text
                 boundary 1                  boundary 2
            Kubernetes identity           PostgreSQL identity

  +---------------------------+       +---------------------------+
  | ServiceAccount: app       |       | Role: app_user            |
  | - mounted with app Secret | ----> | - CONNECT appdb           |
  | - no Kubernetes API       |       | - USAGE app schema        |
  |   access to Secrets       |       | - SELECT/INSERT/UPDATE    |
  | - no admin RBAC           |       | - no DDL                  |
  +---------------------------+       +---------------------------+

  +---------------------------+       +---------------------------+
  | ServiceAccount: migrator  |       | Role: migrator_user       |
  | - mounted with migrator   | ----> | - CONNECT appdb           |
  |   Secret                  |       | - CREATE in app schema    |
  | - used by Job only        |       | - CREATE/ALTER in schema  |
  | - no admin RBAC           |       | - no broad admin rights   |
  +---------------------------+       +---------------------------+
```

The Kubernetes identity boundary controls the workload identity each pod runs
as, and the pod specs mount different Secrets and certificates for each
workload. The PostgreSQL identity boundary controls what the authenticated
database user can do after the TLS connection is established.

Kubernetes RBAC controls API access to Secrets; it does not, by itself, stop a
controller from creating a pod that mounts any Secret in the same namespace.
For a stronger production boundary, put app and migrator workloads in separate
namespaces or enforce mount rules with admission policy. In this lab, the
runtime pod has no Kubernetes API permission to read Secrets, and the manifests
intentionally mount only the Secret needed by that workload.

Neither boundary replaces the other. If a Kubernetes Secret is leaked, the
database grants still limit blast radius. If a database password is leaked, the
network and certificate requirements still make the credential harder to use
from an arbitrary location.

## Request Paths

### Runtime Application Path

```text
HTTP client
  |
  v
Kubernetes Service: migrations-demo-api
  |
  v
Python API Pod
  |
  | reads Secret: app-db-credentials
  | mounts CA bundle
  | optionally mounts app client certificate
  |
  | postgresql://app_user@external-pg:55432/appdb?sslmode=verify-full
  v
ExternalName Service: external-pg
  |
  v
Docker Compose PostgreSQL
  |
  | authorizes app_user
  v
application tables only
```

The app should be able to run normal business queries. It should fail if it
attempts schema changes.

Expected app permissions:

```sql
GRANT CONNECT ON DATABASE appdb TO app_user;
GRANT USAGE ON SCHEMA app TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_user;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA app TO app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator_user IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator_user IN SCHEMA app
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO app_user;
```

The default privileges are configured for objects created by `migrator_user`,
so future migration-created tables and sequences are usable by the runtime app
without granting the app schema ownership or DDL permissions.

Expected app denials:

```sql
-- should fail
CREATE TABLE app.should_not_work(id bigint);
ALTER TABLE app.some_table ADD COLUMN should_not_work text;
DROP TABLE app.some_table;
```

### Migration Job Path

```text
operator / GitOps controller / make target
  |
  v
Kubernetes Job: db-migrate
  |
  | image: migration-runner:<tag>
  | serviceAccount: migrator
  | restartPolicy: Never
  | backoffLimit: low
  | reads Secret: migrator-db-credentials
  | mounts CA bundle
  | optionally mounts migrator client certificate
  |
  | postgresql://migrator_user@external-pg:55432/appdb?sslmode=verify-full
  v
ExternalName Service: external-pg
  |
  v
Docker Compose PostgreSQL
  |
  | authorizes migrator_user
  v
schema changes + migration history
```

The migration Job should be able to create and alter objects in the application
schema and update its migration history table. It should not be a PostgreSQL
superuser, should not own the database, and should not have access to unrelated
schemas.

Expected migrator permissions:

```sql
GRANT CONNECT ON DATABASE appdb TO migrator_user;
GRANT USAGE, CREATE ON SCHEMA app TO migrator_user;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator_user IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE migrator_user IN SCHEMA app
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO app_user;
```

Expected migrator denials:

```sql
-- should fail
CREATE DATABASE another_db;
CREATE ROLE another_admin;
ALTER SYSTEM SET log_statement = 'all';
DROP SCHEMA public CASCADE;
```

## TLS Model

TLS has two jobs in this lab:

1. The pod validates that it is talking to the expected PostgreSQL server.
2. PostgreSQL can optionally validate the client certificate as another identity
   factor before password authentication or certificate mapping.

```text
                  demo certificate authority
                             |
          +------------------+------------------+
          |                                     |
          v                                     v
  PostgreSQL server cert                 client certs
  CN/SAN: external-pg                    - app client identity
  trusted by pods                        - migrator client identity

          pod verifies server cert       server verifies client cert
          sslmode=verify-full            pg_hba.conf clientcert=verify-full
```

Recommended connection settings:

```text
sslmode=verify-full
sslrootcert=/var/run/postgres-ca/ca.crt
sslcert=/var/run/postgres-client/tls.crt
sslkey=/var/run/postgres-client/tls.key
```

For a password-only variant, keep server certificate verification enabled and
omit the client certificate. For the stronger variant, require client
certificates in `pg_hba.conf` and map certificate identities to the expected
database roles.

## Defense In Depth

```text
+-------------------+----------------------+-------------------------------+
| Layer             | Control              | What it limits                |
+-------------------+----------------------+-------------------------------+
| Image             | separate app and     | runtime image does not need   |
|                   | migrator images      | migration tooling             |
+-------------------+----------------------+-------------------------------+
| Kubernetes authn  | separate             | app and Job have different    |
|                   | ServiceAccounts      | workload identities           |
+-------------------+----------------------+-------------------------------+
| Kubernetes authz  | minimal RBAC         | workload pods cannot read     |
|                   |                      | Secrets through the API       |
+-------------------+----------------------+-------------------------------+
| Secret scoping    | app-db-credentials   | pod specs mount only the      |
|                   | migrator-db-         | credential each workload uses |
|                   | credentials          |                               |
+-------------------+----------------------+-------------------------------+
| Network           | NetworkPolicy        | egress allowed only to DNS    |
|                   |                      | and TCP 55432 from app and    |
|                   |                      | migrator pods                 |
+-------------------+----------------------+-------------------------------+
| Transport         | TLS verify-full      | prevents cleartext traffic    |
|                   |                      | and server impersonation      |
+-------------------+----------------------+-------------------------------+
| Database authn    | separate roles       | app and migrator authenticate |
|                   |                      | as different users            |
+-------------------+----------------------+-------------------------------+
| Database authz    | least-privilege      | app cannot perform DDL;       |
|                   | grants               | migrator is not admin         |
+-------------------+----------------------+-------------------------------+
| Pod hardening     | non-root, read-only  | reduces impact of code        |
|                   | filesystem, no extra | execution inside a container  |
|                   | capabilities         |                               |
+-------------------+----------------------+-------------------------------+
```

The important lesson is that the design does not depend on one perfect control.
The app does not have migrator credentials, the app credentials cannot run DDL,
the database connection is encrypted, and the network path is constrained.

## Kubernetes Resource Shape

```text
namespace/migrations-demo
|
+-- serviceaccount/app
+-- serviceaccount/migrator
+-- service/external-pg                  ExternalName to host database
+-- secret/app-db-credentials            app_user password and optional cert
+-- secret/migrator-db-credentials       migrator_user password and optional cert
+-- secret/postgres-ca                   CA certificate
+-- deployment/migrations-demo-api       long-running app
+-- job/db-migrate                       short-lived migration runner
+-- networkpolicy/default-deny
+-- networkpolicy/allow-dns
+-- networkpolicy/allow-postgres-port-for-app-and-migrator
```

The app Deployment should not mount the migrator Secret. The migration Job
should not mount the app Secret. That is the key Kubernetes-side teaching point.
For a stricter variant, split the app and migrator into separate namespaces so
Kubernetes Secret names are not even in the same namespace boundary.

## Migration Ordering

```text
1. Start PostgreSQL in Docker Compose
2. Bootstrap database, TLS, and least-privilege roles
3. Build the Python app image
4. Build the migration runner image
5. Apply Kubernetes namespace, ServiceAccounts, Services, Secrets, and policies
6. Run the migration Job
7. Verify migration history
8. Deploy or roll out the Python app
9. Run app smoke tests
```

The migration Job should run before the app rollout. In a GitOps setup, this
maps naturally to a pre-sync hook or an explicit pipeline stage. Locally, it can
be a `make migrate` target that waits for the Job to complete and prints logs.

## Why a Job Instead of Running Migrations Locally?

```text
local laptop migration
  - uses whoever is at the keyboard
  - depends on local tooling
  - may use a different network path
  - hard to reproduce in CI/CD

Kubernetes migration Job
  - uses the cluster workload identity
  - uses the same DNS and network path as the app
  - uses a pinned container image
  - leaves Kubernetes Job status and logs
  - can be ordered before deployment
```

The Job makes migrations part of the deployment system rather than an
out-of-band manual action.

## Verification Checklist

The lab should prove these things explicitly:

- App pod can connect to PostgreSQL over TLS.
- Migration Job can connect to PostgreSQL over TLS.
- App pod reports `current_user = app_user`.
- Migration Job reports `current_user = migrator_user`.
- Migration Job can create or alter schema objects.
- App pod cannot create or alter schema objects.
- App pod cannot read the migrator Secret through the Kubernetes API.
- Migration Job cannot read the app Secret through the Kubernetes API.
- App Deployment does not mount the migrator Secret.
- Migration Job does not mount the app Secret.
- A pod without the right labels cannot egress to PostgreSQL if NetworkPolicy is
  enforced by the local Kubernetes CNI.
- `pg_stat_ssl` confirms TLS for the active PostgreSQL connection.
- `sslmode=disable` fails when PostgreSQL requires TLS.

Useful SQL checks:

```sql
SELECT current_user;

SELECT ssl
FROM pg_stat_ssl
WHERE pid = pg_backend_pid();

SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema = 'app'
ORDER BY table_name;
```

Useful Kubernetes checks:

```sh
kubectl -n migrations-demo get pods,jobs,svc,networkpolicy
kubectl -n migrations-demo logs job/db-migrate
kubectl -n migrations-demo auth can-i get secret/migrator-db-credentials \
  --as system:serviceaccount:migrations-demo:app
kubectl -n migrations-demo auth can-i get secret/app-db-credentials \
  --as system:serviceaccount:migrations-demo:migrator
```

The two `auth can-i` checks should return `no` unless the lab intentionally
grants broader permissions for demonstration.

## Production Mapping

```text
Laptop lab                         Production analogue
----------                         -------------------
Docker Compose PostgreSQL          VM PostgreSQL, Patroni, managed Postgres,
                                   or database platform outside Kubernetes

ExternalName Service               stable DNS name, HAProxy VIP, private
                                   service endpoint, or cloud DNS record

locally generated CA               internal PKI, cert-manager, Vault/OpenBao,
                                   SPIRE, or platform CA

Kubernetes Secret                  external-secrets operator, CSI driver,
                                   Vault/OpenBao injection, sealed secret

manual Job run                     CI/CD stage, GitOps sync wave, Argo CD hook,
                                   Helm hook, or deployment pipeline task
```

The local lab uses Docker Compose only to make the database easy to run on a
laptop. The important part is that Kubernetes treats the database as external.

## What This Does Not Try To Prove

- PostgreSQL high availability.
- Backup and restore.
- Certificate rotation.
- Full production PKI.
- A service mesh.
- Secret-manager integration.
- SQL migration correctness beyond a small demonstration schema.

Those are separate concerns. This lab is about the access model for runtime
application code versus migration code.

## Key Takeaway

The migration Job and the Python app should be separate principals at every
layer:

```text
different container image
different Kubernetes ServiceAccount
different Kubernetes Secret
different TLS client identity
different PostgreSQL role
different database grants
different lifecycle
```

That separation is the core of least privilege. TLS, NetworkPolicy, Secret
scoping, and pod hardening then add defense in depth around it.
