# OpenBao + Postgres Demo

A small learning project that shows a Python app in Rancher Desktop
Kubernetes connecting to a PostgreSQL database in Docker Compose,
where every credential the app uses comes from OpenBao.

## What It Shows

- OpenBao running in dev mode via Docker Compose.
- PostgreSQL running alongside it via Docker Compose.
- The app authenticates to OpenBao with **AppRole** (role_id + secret_id).
- The app reads **static** Postgres credentials from a KV v2 secret
  at `kv/data/postgres`.
- The app requests **dynamic**, short-lived Postgres credentials from
  the database secrets engine at `database/creds/poc-role`. OpenBao
  creates a fresh Postgres user for each request and drops it when
  the lease expires.
- Both code paths run a single trivial query (`SELECT current_user, now()`)
  to prove they connected.

## How auth flows (read this first)

OpenBao does **not** authenticate the app to Postgres. There are two
separate auth steps:

1. **App ↔ OpenBao.** The app authenticates to OpenBao using its
   AppRole `role_id` + `secret_id` (mounted from the
   `openbao-approle` Kubernetes Secret). OpenBao authorizes the app
   via the `poc-app` policy, which only permits reading
   `kv/data/postgres` and `database/creds/poc-role` - nothing else.
2. **App ↔ Postgres.** The app then connects to Postgres using a
   normal username/password. Postgres performs its own
   authentication/authorization (Postgres roles, `GRANT`s); OpenBao
   is not in that connection path.

OpenBao's job is to **deliver the Postgres credentials to the app at
runtime** so they never live in the app image, the deployment YAML,
or environment variables - only the AppRole identity does.

The two `/query/*` endpoints differ only in *where the Postgres
credentials come from*:

- `/query/static` - long-lived `appuser` / `apppass` stored in KV v2.
- `/query/dynamic` - OpenBao itself logs into Postgres as
  `vaultadmin`, runs `CREATE ROLE v-approle-poc-role-… WITH LOGIN
  PASSWORD …`, hands the new credentials to the app, and tracks a
  60-second lease. When the lease expires OpenBao runs the
  `DROP ROLE`.

A leaked dynamic credential therefore has a one-minute blast radius,
and OpenBao keeps an audit trail of which AppRole requested which
lease.

## Architecture

```text
HTTP client
  |
  v
Python API in Kubernetes (namespace: openbao-demo)
  |
  | 1. AppRole login -> OpenBao token             (authn + authz: app ↔ OpenBao)
  | 2. read kv/data/postgres        -> static user/pass
  | 3. read database/creds/poc-role -> dynamic user/pass + lease TTL
  |
  | 4. connect with those creds                   (authn + authz: app ↔ Postgres)
  v
Docker Compose host
  - openbao  (dev mode, port 8200, root token "root")
  - postgres (port 5432, db "pocdb")
```

The app inside Kubernetes reaches the host via
`host.rancher-desktop.internal`, exposed as ExternalName Services
named `external-openbao` and `external-postgres`.

## Requirements

- Rancher Desktop with Kubernetes enabled
- Docker-compatible CLI
- `kubectl`
- `make`
- `curl`
- `jq`

## Quick Start

Run the full demo and clean everything afterward:

```sh
make full-check
```

This runs:

```text
make up
make test-all
make clean
```

`make clean` runs even if a check fails.

## Manual Flow

Start the services, configure OpenBao, build the image, deploy:

```sh
make up
```

`up` runs, in order: start Docker Compose services, build the app
image, apply the Kubernetes namespace and ExternalName Services,
bootstrap OpenBao (KV v2 + database engine + AppRole + policy),
deploy the app, and verify.

Run the smoke test with a temporary port-forward:

```sh
make test-all
```

Inspect what is currently running:

```sh
make status
```

Remove all runtime state:

```sh
make clean
```

## Useful Targets

- `make up` - start services, bootstrap OpenBao, deploy the app
- `make test` - run the smoke test; needs a port-forward
- `make test-all` - run the smoke test with a temporary port-forward
- `make status` - show Kubernetes, Docker, image, log, and port state
- `make full-check` - run everything and always clean up
- `make clean` - remove all demo runtime state

## API Shape

- `GET /` - lists endpoints and configured upstreams
- `GET /healthz` - process liveness
- `GET /db-healthz` - tries a `SELECT 1` using the static creds
- `GET /query/static` - reads `kv/data/postgres`, connects with
  `appuser`, returns `{current_user, now}`
- `GET /query/dynamic` - reads `database/creds/poc-role`, connects with
  the freshly minted user, returns `{current_user, now, lease_id,
  lease_duration, renewable}`

## What `make test-all` Proves

The test calls `/query/static` once and `/query/dynamic` twice, then
asserts:

- the static call comes back as `current_user = appuser`
- both dynamic calls come back as `current_user` matching
  `v-approle-poc-role-*` (OpenBao's generated naming)
- the two dynamic calls return **different** users and **different**
  lease IDs - i.e. OpenBao minted a new short-lived Postgres role for
  each request

## Explore OpenBao in the UI

While the demo is up, open <http://localhost:8200/ui>. On the sign-in
page leave **Method** as `Token` and enter `root` (the dev-mode root
token). Worth a click each:

- **Secrets → kv/ → postgres** - the static credentials
  (`appuser`/`apppass`) that `/query/static` reads.
- **Secrets → database/ → Roles → poc-role** - click **Generate
  credentials** to mint a short-lived Postgres user from the UI;
  exactly what `/query/dynamic` does.
- **Secrets → database/ → Connections → postgres-pocdb** - the
  connection OpenBao uses (as `vaultadmin`) to create those dynamic
  users.
- **Access → AppRole → poc-app** - the role the app authenticates as.
- **Policies → poc-app** - the two paths the app is permitted to read.
- **Access → Leases** - every active dynamic Postgres user with its
  TTL ticking down. Watching one expire and disappear from `pg_roles`
  is the clearest way to see what dynamic creds actually do.

## Inspect OpenBao via CLI

```sh
# CLI inside the container:
docker compose exec -e BAO_ADDR=http://127.0.0.1:8200 \
                    -e BAO_TOKEN=root openbao bao kv get kv/postgres
docker compose exec -e BAO_ADDR=http://127.0.0.1:8200 \
                    -e BAO_TOKEN=root openbao bao read database/creds/poc-role
docker compose exec -e BAO_ADDR=http://127.0.0.1:8200 \
                    -e BAO_TOKEN=root openbao bao list sys/leases/lookup/database/creds/poc-role
```

Watching `database/creds/poc-role` issue a fresh user each time, and
the lease list shrink as TTLs expire, is the core thing this POC is
trying to make tangible.

## Cleanup Guarantee

`make clean` removes and verifies removal of:

- Kubernetes namespace `openbao-demo`
- Docker Compose containers (`openbao-demo-server`, `openbao-demo-postgres`)
- Docker Compose volumes
- Docker network
- local image `openbao-demo-app:demo`
- `logs/`
- `/tmp/openbao-demo-port-forward.log`

After `make clean`, a new run starts from an empty runtime state.
