# Registry Flyway No-PgBouncer Proof of Concept

This proof of concept simulates the production design where:

- PostgreSQL runs **outside** Kubernetes on VMs.
- The application runs **inside** Rancher Desktop Kubernetes.
- Flyway runs as Kubernetes Jobs to apply database migrations.
- There is **no PgBouncer** — the application connects directly to PostgreSQL.

For the laptop POC, Docker Compose runs two PostgreSQL containers in place of the VM-hosted Patroni clusters:

- `event-postgres` simulates the production event-store Patroni PostgreSQL cluster.
- `read-postgres` simulates the production read-store Patroni PostgreSQL cluster.

Splitting the event store and read store into two databases mirrors the production CQRS topology: writes go to one database (the event log), reads come from another (the projected view).

## What this proves

This POC is focused on the **deployment and migration topology**, not on data correctness or HA features. Specifically it shows that:

- Kubernetes workloads can reach PostgreSQL databases that live **outside** the cluster.
- The application can connect **directly** to PostgreSQL without PgBouncer in the path.
- Flyway can run **inside** Kubernetes as one-off Jobs and apply schema changes to **external** databases.
- Event-store and read-store migrations can be managed **independently** (separate Jobs, separate ConfigMaps, separate history tables).
- Re-running migrations is **safe** because Flyway records applied migrations in `flyway_schema_history` and skips them on the next run.

It is **not** testing Patroni failover, HAProxy routing, backup/restore, Vault, Harbor, Argo CD, Rancher HA, or Marten itself. See `docs/PRODUCTION-MAPPING.md` for what each POC component maps to in production.

## Runtime paths

The POC keeps the **same network shape** as production: the app and Flyway both reach the database through a stable Kubernetes Service name, which resolves to a host outside the cluster. Only the resolution target differs.

Application path (POC):

```text
Python API Pod
  -> external-event-postgres Service (ExternalName)
  -> Docker PostgreSQL event store

Python API Pod
  -> external-read-postgres Service (ExternalName)
  -> Docker PostgreSQL read store
```

Migration path (POC):

```text
Event-store Flyway Job
  -> external-event-postgres Service (ExternalName)
  -> Docker PostgreSQL event store

Read-store Flyway Job
  -> external-read-postgres Service (ExternalName)
  -> Docker PostgreSQL read store
```

Production equivalent:

```text
Application Pods
  -> HAProxy VIP (DNS)
  -> Patroni PostgreSQL primary

Flyway Migration Jobs
  -> HAProxy write VIP (DNS)
  -> Patroni PostgreSQL primary
```

The pods don't know — and don't need to know — whether the Service name resolves to a Docker container on the laptop or to an HAProxy VIP fronting a Patroni cluster. That decoupling is exactly what makes this topology portable.

## Quick run with Make

The numbered scripts remain the clearest way to understand each step, but the Makefile provides shorter commands for repeated runs.

Run the full setup and verification flow:

```bash
make up
```

This runs steps 1-7: start PostgreSQL, build the image, apply Kubernetes base resources, test pod-to-database connectivity, run Flyway, deploy the app, and verify the database contents.

In a second terminal, expose the app locally:

```bash
make port-forward
```

Leave that running while you test the app. In another terminal, run the smoke test:

```bash
make smoke
```

When finished, stop `make port-forward` with `Ctrl+C` (the script traps the signal and kills the underlying `kubectl port-forward`), then clean up:

```bash
make clean
```

`make clean` is split into two targets you can run independently when iterating:

```bash
make clean-k8s   # delete the registry-poc namespace, leave Postgres running
make clean-db    # stop and remove only the Docker Postgres containers and volumes
```

`make smoke` requires [`jq`](https://stedolan.github.io/jq/) on `PATH` (`brew install jq`) to pretty-print the JSON responses; the target fails fast with a clear error if it is missing.

You can list all targets with:

```bash
make help
```

## Run

These steps deliberately build the same shape as production: **external databases first, stable Kubernetes database names second, migrations before app deployment, then runtime verification.** Each step is a script in `scripts/`.

| Step | Command | What it does | Why this step exists |
|---|---|---|---|
| 1 | `01-start-postgres.sh` | Runs `docker compose up -d` to start two PostgreSQL 16 containers (`registry-event-postgres` on 5432, `registry-read-postgres` on 5433), then waits for both to pass `pg_isready`. | Stands in for the VM-hosted Patroni clusters. The app and Flyway need a database to talk to before anything else makes sense. |
| 2 | `02-build-python-image.sh` | Builds `registry-python-app:poc` from `app/Dockerfile` using the local Docker daemon. | Rancher Desktop with `dockerd`/Moby shares its image store with Kubernetes, so a locally built image is visible to pods (with `imagePullPolicy: Never`). This avoids needing a registry for the POC. If you use containerd, the script prints the `nerdctl` equivalent. |
| 3 | `03-apply-k8s-base.sh` | Applies the namespace, both `ExternalName` Services, the database Secret, and the two Flyway migration ConfigMaps. | Sets up everything that **must exist before migrations can run**: a stable in-cluster DNS name for each external database, credentials for Flyway, and the SQL files Flyway will mount and apply. Splitting this from migrations means you can re-apply base config without re-running migrations. |
| 4 | `04-test-k8s-db-connectivity.sh` | Runs a throwaway `postgres:16` pod in the namespace and uses `psql` to issue a `SELECT` against each database via its `ExternalName` Service. | Proves the network path **before** Flyway or the app gets blamed for it. If this fails (e.g. `host.rancher-desktop.internal` doesn't resolve), you know it's a Service/DNS issue, not a migration or app issue. This is the single most useful debugging step. |
| 5 | `05-run-migrations.sh` | Deletes any prior Job objects, applies the event-store Flyway Job, waits for completion, prints its logs, then does the same for the read-store. | Migrations must succeed **before** the app is deployed — same ordering as Argo CD PreSync hooks in production. Each store gets its own Job so failures and history are isolated. Old Jobs are deleted first because Job spec is immutable; you can't re-apply a Job over itself. |
| 6 | `06-deploy-python-app.sh` | Applies the Deployment and Service for the FastAPI app and waits for the rollout. | Now that the schemas exist, the app's readiness probe can succeed on first start. Deploying after migrations means a failed migration never produces a half-broken running app. |
| 7 | `07-verify.sh` | Uses `docker exec` + `psql` to query the event-store events, the read-store rows, and `flyway_schema_history` on **both** databases. | End-to-end confirmation that schemas were created, seed rows were inserted, and Flyway recorded each migration as `success = true`. Querying directly via `docker exec` skips the app and proves the data exists at the source. |

```bash
chmod +x scripts/*.sh

./scripts/01-start-postgres.sh
./scripts/02-build-python-image.sh
./scripts/03-apply-k8s-base.sh
./scripts/04-test-k8s-db-connectivity.sh
./scripts/05-run-migrations.sh
./scripts/06-deploy-python-app.sh
./scripts/07-verify.sh
```

### Optional checks after step 1

After `./scripts/01-start-postgres.sh`, you can directly check that both PostgreSQL containers are accepting connections:

```bash
docker exec registry-event-postgres pg_isready -U registry -d registry_events
docker exec registry-read-postgres pg_isready -U registry -d registry_read
```

Expected output for each database:

```text
/var/run/postgresql:5432 - accepting connections
```

At this point the databases are running, but the application schema and seed data are not expected to exist yet. Those are created later by Flyway in step 5.

### Optional checks after step 2

After `./scripts/02-build-python-image.sh`, check that the image exists locally:

```bash
docker image ls registry-python-app:poc
```

Expected output includes an image tagged `registry-python-app:poc`.

You can also run the image directly to prove the FastAPI app starts. First export the database URLs that Kubernetes will provide later through the Secret. Note the hostname differs from the rest of the POC: when running directly via `docker run` on your laptop, reach the host through `host.docker.internal`. From inside Kubernetes (later steps) the same database is reached through `host.rancher-desktop.internal`, fronted by the `ExternalName` Service. Same database, two paths to it.

```bash
export EVENT_STORE_DATABASE_URL='postgresql://registry:registry@host.docker.internal:5432/registry_events'
```

```bash
export READ_STORE_DATABASE_URL='postgresql://registry:registry@host.docker.internal:5433/registry_read'
```

Then run the app container:

```bash
docker run --rm -p 8081:8080 -e EVENT_STORE_DATABASE_URL -e READ_STORE_DATABASE_URL registry-python-app:poc
```

In another terminal, check the liveness endpoint:

```bash
curl http://localhost:8081/healthz
```

Expected output:

```json
{"status":"ok"}
```

Then check that the app container can connect to both PostgreSQL databases:

```bash
curl http://localhost:8081/db-healthz
```

Expected output includes:

```text
"status":"ok"
```

```text
"database":"registry_events"
```

```text
"database":"registry_read"
```

Stop the direct Docker run with `Ctrl+C` before continuing. The `/companies` and `/events` endpoints are not expected to work yet because Flyway has not created the tables.

### Optional checks after step 3

After `./scripts/03-apply-k8s-base.sh`, check that the namespace exists:

```bash
kubectl get namespace registry-poc
```

Expected output shows `registry-poc` with status `Active`.

Check that both external database Services exist:

```bash
kubectl get service -n registry-poc
```

Expected output includes:

```text
external-event-postgres
external-read-postgres
```

Check that the database Secret exists:

```bash
kubectl get secret -n registry-poc registry-db-secret
```

Expected output shows `registry-db-secret` with `DATA` set to `4`.

Check that both Flyway migration ConfigMaps exist:

```bash
kubectl get configmap -n registry-poc
```

Expected output includes:

```text
event-store-flyway-migrations
read-store-flyway-migrations
```

Inspect the event-store ExternalName Service:

```bash
kubectl describe service external-event-postgres -n registry-poc
```

Expected output includes:

```text
Type: ExternalName
External Name: host.rancher-desktop.internal
Port: postgres 5432/TCP
```

Inspect the read-store ExternalName Service:

```bash
kubectl describe service external-read-postgres -n registry-poc
```

Expected output includes:

```text
Type: ExternalName
External Name: host.rancher-desktop.internal
Port: postgres 5433/TCP
```

This proves Kubernetes has the stable in-cluster names, credentials, and migration SQL that later steps need. It does not yet prove a pod can connect through those Services; that is step 4.

### Optional checks after step 4

`./scripts/04-test-k8s-db-connectivity.sh` runs short-lived `postgres:16` pods inside Kubernetes and uses `psql` to connect through the `ExternalName` Services.

For the event store, expected output includes:

```text
event store reachable
```

For the read store, expected output includes:

```text
read store reachable
```

The script uses `kubectl run --rm`, so the test pods should be deleted automatically. You can confirm there are no leftover test pods:

```bash
kubectl get pods -n registry-poc
```

At this point, before the app is deployed, expected output is usually:

```text
No resources found in registry-poc namespace.
```

This proves the Kubernetes network path works from a pod to both external PostgreSQL databases. Flyway and the app use the same Service names in later steps.

### Optional checks after step 5

`./scripts/05-run-migrations.sh` should print this success line for both the event store and read store:

```text
Successfully applied 2 migrations to schema "public", now at version v002
```

You can also confirm the result directly in PostgreSQL.

Check the event-store tables:

```bash
docker exec registry-event-postgres psql -U registry -d registry_events -c "\dt"
```

Expected output includes:

```text
domain_events
flyway_schema_history
```

Check the read-store tables:

```bash
docker exec registry-read-postgres psql -U registry -d registry_read -c "\dt"
```

Expected output includes:

```text
company_read_model
flyway_schema_history
```

Check the event-store seed event:

```bash
docker exec registry-event-postgres psql -U registry -d registry_events -c "select sequence, stream_id, event_type, event_data, correlation_id from domain_events;"
```

Expected output includes:

```text
company-123456
CompanyRegistered
Example Company Ltd
11111111-1111-1111-1111-111111111111
```

Check the read-store seed row:

```bash
docker exec registry-read-postgres psql -U registry -d registry_read -c "select company_number, company_name, registered_address, status from company_read_model;"
```

Expected output includes:

```text
123456
Example Company Ltd
1 Main Street, Dublin
Registered
```

Check the event-store Flyway history:

```bash
docker exec registry-event-postgres psql -U registry -d registry_events -c "select version, description, success from flyway_schema_history order by installed_rank;"
```

Expected output includes:

```text
001 create event store t
002 add correlation columns t
```

Check the read-store Flyway history:

```bash
docker exec registry-read-postgres psql -U registry -d registry_read -c "select version, description, success from flyway_schema_history order by installed_rank;"
```

Expected output includes:

```text
001 create company read model t
002 add registered address t
```

These checks prove Flyway created the schema, inserted seed data, and recorded both migrations as successful in each database.

### Optional checks after step 6

`./scripts/06-deploy-python-app.sh` should end with:

```text
deployment "registry-python-app" successfully rolled out
```

Check the pods in the namespace:

```bash
kubectl get pods -n registry-poc
```

Expected output includes one app pod with `READY` set to `1/1` and `STATUS` set to `Running`:

```text
registry-python-app-... 1/1 Running
```

You may also still see the Flyway migration pods with `STATUS` set to `Completed`. That is normal because Kubernetes keeps completed Job pods for inspection.

Check the Deployment:

```bash
kubectl get deployment -n registry-poc registry-python-app
```

Expected output shows:

```text
READY 1/1
AVAILABLE 1
```

Check the app Service:

```bash
kubectl get service -n registry-poc registry-python-app
```

Expected output shows `registry-python-app` as a `ClusterIP` Service on port `8080/TCP`.

Check the app logs:

```bash
kubectl logs -n registry-poc deployment/registry-python-app
```

Expected output includes:

```text
Application startup complete.
Uvicorn running on http://0.0.0.0:8080
GET /db-healthz HTTP/1.1" 200 OK
GET /healthz HTTP/1.1" 200 OK
```

The `/db-healthz` hits come from the `startupProbe`, which opens real connections to both external PostgreSQL databases before Kubernetes marks the pod Ready. Once the startup probe succeeds it stops running, and the steady-state `/healthz` hits come from the readiness and liveness probes. This is why the pod can never go Ready before both databases are actually reachable.

### Optional checks after step 7

`./scripts/07-verify.sh` queries both databases directly with `docker exec` and `psql`. If your terminal opens a pager and shows `(END)`, press `q` to continue, or rerun the script with the pager disabled:

```bash
PAGER=cat ./scripts/07-verify.sh
```

The output should show:

```text
CompanyRegistered
company-123456
Example Company Ltd
```

```text
001 create event store t
002 add correlation columns t
```

```text
123456
Example Company Ltd
1 Main Street, Dublin
Registered
```

```text
001 create company read model t
002 add registered address t
```

You can also confirm the seeded row counts directly.

Check the event-store row count:

```bash
docker exec registry-event-postgres psql -U registry -d registry_events -c "select count(*) from domain_events;"
```

Expected output shows:

```text
count
-----
1
```

Check the read-store row count:

```bash
docker exec registry-read-postgres psql -U registry -d registry_read -c "select count(*) from company_read_model;"
```

Expected output shows:

```text
count
-----
1
```

These checks prove the verification script can read both databases, the migrated tables exist, and the seed data is present in each store.

## Exercise the running app

Port-forward the service (the POC uses `ClusterIP`, so this is how you reach it from the laptop):

```bash
./scripts/08-port-forward.sh
```

Expected output:

```text
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
```

Leave the port-forward terminal running. In another terminal, check the liveness endpoint:

```bash
curl http://localhost:8080/healthz
```

Expected output:

```json
{"status":"ok"}
```

Check the app's live database connectivity:

```bash
curl http://localhost:8080/db-healthz
```

Expected output includes:

```text
"status":"ok"
```

```text
"database":"registry_events"
```

```text
"database":"registry_read"
```

`/db-healthz` is the most informative endpoint: it proves the app pod is reaching **both** external databases through the `ExternalName` Services in real time, not just at startup.

Check the read-store endpoint:

```bash
curl http://localhost:8080/companies
```

Expected output includes:

```text
Example Company Ltd
1 Main Street, Dublin
```

Check the event-store endpoint:

```bash
curl http://localhost:8080/events
```

Expected output includes:

```text
CompanyRegistered
company-123456
```

These endpoints exercise different parts of the topology:

```bash
curl http://localhost:8080/healthz       # liveness only — no DB touched
curl http://localhost:8080/db-healthz    # opens a connection to BOTH databases
curl http://localhost:8080/companies     # reads from the read store
curl http://localhost:8080/events        # reads from the event store
```

Register a new company to exercise the write path (event store first, then read-model update):

```bash
curl -X POST http://localhost:8080/companies/register \
  -H 'Content-Type: application/json' \
  -d '{"company_number":"777777","company_name":"New Example Ltd","registered_address":"7 Harbour Road, Galway"}'
```

> Running this exact request twice appends a second `CompanyRegistered` event for `company-777777` and upserts the read model — the API is idempotent on the read side but not on the event log. `make smoke` avoids this by generating a fresh `company_number` per run from `$(date +%s)$$`.


Expected output includes:

```text
Company registered
company-777777
```

Then re-read both stores and confirm the event was appended and the read model was updated:

```bash
curl http://localhost:8080/companies
curl http://localhost:8080/events
```

Expected output now includes both companies:

```text
Example Company Ltd
New Example Ltd
```

Expected output now includes both event streams:

```text
company-123456
company-777777
```

You can also confirm directly in PostgreSQL that both stores now contain two rows.

Check the event-store row count:

```bash
docker exec registry-event-postgres psql -U registry -d registry_events -c "select count(*) from domain_events;"
```

Expected output shows:

```text
count
-----
2
```

Check the read-store row count:

```bash
docker exec registry-read-postgres psql -U registry -d registry_read -c "select count(*) from company_read_model;"
```

Expected output shows:

```text
count
-----
2
```

In production this projection step would run as an asynchronous worker; the POC does it synchronously inside the request handler so the data flow is easy to follow in one place. The two writes are not atomic across databases: if the read-store update fails after the event-store insert succeeds, the read model lags the event log until the next update or a replay. The POC accepts that drift because it is testing topology, not consistency; the production design relies on an idempotent projector replaying from the event log to recover.

## What's in `k8s/`

The numeric prefixes match the apply order. Each manifest exists for a specific reason:

| File | Kind | Purpose |
|---|---|---|
| `00-namespace.yaml` | Namespace `registry-poc` | Isolates all POC resources so cleanup is a single `kubectl delete namespace`. |
| `01-external-event-postgres-service.yaml` | `Service` (ExternalName) | In-cluster DNS name `external-event-postgres` that resolves to `host.rancher-desktop.internal`. The Docker container is reachable from pods through this name. |
| `02-external-read-postgres-service.yaml` | `Service` (ExternalName) | Same pattern for the read store on port 5433. |
| `03-db-secret.yaml` | Secret | Holds the username, password, and full `postgresql://` URLs for both stores. The app and Flyway both consume this Secret instead of hard-coding credentials. |
| `04-event-store-flyway-migrations-configmap.yaml` | ConfigMap | Holds the event-store SQL migrations (`V001`, `V002`). Flyway mounts this as `/flyway/sql`. Stored in the cluster so the Job is self-contained. |
| `05-read-store-flyway-migrations-configmap.yaml` | ConfigMap | Same for the read store. |
| `06-event-store-flyway-job.yaml` | Job | Runs `flyway/flyway:11 migrate` against the event store. `backoffLimit: 0` and `restartPolicy: Never` mean a failed migration fails fast instead of retrying with confusing partial state. |
| `07-read-store-flyway-job.yaml` | Job | Same for the read store. |
| `08-python-app-deployment.yaml` | Deployment | Runs the FastAPI app. `imagePullPolicy: Never` because the image is only in the local Docker store. Readiness/liveness probes hit `/healthz`. |
| `09-python-app-service.yaml` | Service (ClusterIP) | Stable in-cluster name for the app. ClusterIP keeps it off the host network — you reach it via `kubectl port-forward`. |

## If `host.rancher-desktop.internal` does not work

Some setups expose the host as `host.docker.internal` instead. Edit:

- `k8s/01-external-event-postgres-service.yaml`
- `k8s/02-external-read-postgres-service.yaml`

Change:

```yaml
externalName: host.rancher-desktop.internal
```

to:

```yaml
externalName: host.docker.internal
```

Then rerun the affected steps:

```bash
./scripts/03-apply-k8s-base.sh
./scripts/04-test-k8s-db-connectivity.sh
```

Step 4 tells you immediately whether the new name resolves.

## Idempotency

You can rerun:

```bash
./scripts/05-run-migrations.sh
```

Flyway checks `flyway_schema_history` and **skips** migrations already applied successfully. The script deletes prior Job objects first because a Kubernetes Job's pod template is immutable — you can't `kubectl apply` over a completed Job.

**Do not edit migration files after they have been applied.** Flyway records a checksum per migration; editing an applied file causes a checksum mismatch on the next run. Add a new versioned migration (e.g. `V003__...sql`) instead.

## Clean up

```bash
./scripts/09-clean.sh
```

This deletes the Kubernetes namespace (which removes every POC resource in one shot) and runs `docker compose down -v` to drop the PostgreSQL volumes so the next run starts from an empty database.

If `./scripts/08-port-forward.sh` is still running in another terminal, stop it with `Ctrl+C`.

Confirm the Kubernetes namespace is gone:

```bash
kubectl get namespace registry-poc
```

Expected output:

```text
Error from server (NotFound): namespaces "registry-poc" not found
```

Confirm the PostgreSQL containers are gone:

```bash
docker ps --filter name=registry-
```

Expected output contains only the table header and no containers:

```text
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

Confirm the PostgreSQL volumes are gone:

```bash
docker volume ls --filter name=registry-flyway-no-pgbouncer-poc
```

Expected output contains only the table header and no volumes:

```text
DRIVER    VOLUME NAME
```

These checks confirm the POC is fully stopped and the next run will start from clean databases.
