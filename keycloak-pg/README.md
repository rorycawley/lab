# Keycloak + Postgres Demo

A small learning project that shows a Python app in Rancher Desktop
Kubernetes connecting to a PostgreSQL database in Docker Compose,
where the **only thing the app uses to authenticate to Postgres is a
JWT issued by Keycloak**. Keycloak is the identity authority for both
the app *and* its database access.

## What It Shows

- Keycloak running in dev mode via Docker Compose, with a realm `poc`
  and a confidential client `poc-app`.
- PostgreSQL running alongside it via Docker Compose, reachable
  *only* through a custom proxy.
- A small **PG-wire JWT auth proxy** (`proxy/proxy.py`, ~250 lines)
  that pretends to be Postgres on port `6432`. It speaks just enough
  of the Postgres v3 wire protocol to:
  1. Receive the client's startup + password message.
  2. Validate the password as a JWT against Keycloak's JWKS.
  3. Open a real Postgres connection as a backend service account.
  4. Run `SET ROLE <claim from JWT>` on that session.
  5. Forward bytes both ways for the rest of the session.
- The Python app (`app/main.py`) fetches a JWT from Keycloak using
  the `client_credentials` grant and passes it to the proxy *as the
  Postgres password*. There are no Postgres credentials in the app's
  image, environment, or Kubernetes Secret - only a Keycloak
  `client_id` / `client_secret`.

## How auth flows (read this first)

There are two auth steps, and they are completely separate:

1. **App ↔ Keycloak.** The app POSTs `grant_type=client_credentials`
   to the Keycloak token endpoint with its `client_id` and
   `client_secret` (mounted from the `keycloak-client` Kubernetes
   Secret). Keycloak issues a signed JWT. The hardcoded-claim mapper
   on the `pg-role` client scope adds `"pg_role": "pgreader"` to that
   JWT.
2. **App ↔ Postgres (via proxy).** The app then opens a Postgres
   connection to the proxy with `user=poc-app, password=<the JWT>`.
   The proxy is the *only* thing that authenticates to Postgres
   itself, and only after it has verified the JWT.

Concretely, the proxy:
- Verifies the JWT signature against Keycloak's JWKS at
  `/realms/poc/protocol/openid-connect/certs`.
- Verifies `iss == http://external-keycloak:8180/realms/poc` (matches
  the URL the app used to fetch the token).
- Verifies `azp == poc-app`.
- Verifies `exp` is in the future.
- Reads the `pg_role` claim and uses it as the argument to
  `SET ROLE` on the upstream Postgres session.

If any of those checks fail, the proxy responds with a Postgres
`ErrorResponse` (`SQLSTATE 28000`) and closes the connection.
Postgres itself never sees the unverified caller.

## Why a proxy at all?

Postgres can't natively validate Keycloak-issued JWTs. PostgreSQL 18
adds an `oauth` auth method, but it requires a custom validator
shared library, which is too much yak-shaving for a POC. A small
purpose-built proxy is honest about what it does and is easy to read
end-to-end.

The proxy is intentionally the smallest thing that proves the trust
chain. It is **not** production-ready. In particular Postgres is
configured with `POSTGRES_HOST_AUTH_METHOD=password` (cleartext on
the Compose network). The reason is that the proxy only knows how
to answer a cleartext-password challenge - it doesn't implement
SCRAM-SHA-256 client-side, which is what postgres:18 would otherwise
ask for. That's safe enough here because nothing untrusted reaches
the Compose network: the only Postgres client is the proxy, and the
proxy authenticates with a known constant (`pgproxypass`). In a real
deployment you would either implement SCRAM in the proxy, run it
over a unix socket, or both.

## Architecture

```text
HTTP client
  │
  ▼
Python FastAPI app (k8s namespace: keycloak-pg-demo)
  │
  │  1. POST /token (client_credentials)  ──► Keycloak    [authn: app ↔ Keycloak]
  │     ◄── access_token (JWT, contains pg_role: pgreader)
  │
  │  2. psycopg.connect(host=external-pg-proxy, user=poc-app, password=<JWT>)
  │
  ▼
Docker Compose host (host.rancher-desktop.internal)
  ├── keycloak       :8180  (dev mode, admin/admin, realm "poc")
  ├── pg-jwt-proxy   :6432  validates JWT → opens upstream PG session
  │                          → SET ROLE <claim> → transparent forwarder
  └── postgres       :5432  pgproxy/pgreader/pgwriter roles, messages table
```

The app inside Kubernetes reaches the host through two ExternalName
Services in the `keycloak-pg-demo` namespace:

- `external-keycloak` → `host.rancher-desktop.internal:8180`
- `external-pg-proxy` → `host.rancher-desktop.internal:6432`

The real Postgres on `:5432` is exposed on the host for `psql`
debugging only; the app cannot resolve it from inside the cluster.

## How the proxy speaks Postgres

The proxy implements just enough of the [Postgres v3 frontend/backend
protocol][pgproto] to handle the startup + auth phase, then becomes
a dumb byte forwarder. The full sequence for one `/query` call:

```text
client (psycopg)          proxy (proxy.py)                postgres
      │                          │                            │
      │── SSLRequest ───────────►│                            │
      │◄── 'N' (no SSL) ─────────│                            │
      │── StartupMessage ───────►│                            │
      │   user=poc-app db=pocdb  │                            │
      │◄── AuthCleartextPassword │                            │
      │── PasswordMessage ──────►│  validate JWT against      │
      │   payload=<JWT>          │  cached JWKS, iss, azp,exp │
      │                          │── StartupMessage ─────────►│
      │                          │   user=pgproxy db=pocdb    │
      │                          │◄── AuthCleartextPassword   │
      │                          │── PasswordMessage ────────►│
      │                          │   payload=pgproxypass      │
      │                          │◄── AuthenticationOk        │
      │                          │◄── ParameterStatus × N     │
      │                          │◄── BackendKeyData          │
      │                          │◄── ReadyForQuery           │
      │                          │── Query 'SET ROLE "..."' ─►│
      │                          │◄── CommandComplete         │
      │                          │◄── ReadyForQuery           │
      │◄── AuthenticationOk      │                            │
      │◄── ParameterStatus × N   │  (replayed from upstream)  │
      │◄── BackendKeyData        │                            │
      │◄── ReadyForQuery         │                            │
      │── Query 'SELECT ...' ───►│── (forwarded) ────────────►│
      │◄── RowData / etc ────────│◄── (forwarded) ────────────│
```

Two non-obvious details to look at in `proxy/proxy.py`:

- **The `SET ROLE` round-trip is invisible to the client.** The
  proxy reads the upstream's `ParameterStatus`, `BackendKeyData`,
  and first `ReadyForQuery` into a buffer, runs `SET ROLE <claim>`
  and drains its responses, *then* sends `AuthenticationOk` to the
  client followed by the buffered messages. The client sees a
  normal-looking fresh session whose effective user happens to be
  `pgreader`. If we sent `AuthenticationOk` before `SET ROLE`, the
  client would briefly be operating as `pgproxy` and could issue a
  query in that window.
- **Backend identity vs. effective role.** Inside Postgres,
  `session_user` stays as `pgproxy` (the connection's login identity)
  while `current_user` becomes `pgreader` (changed by `SET ROLE`).
  That's why the smoke test asserts both - `session_user` proves the
  proxy connected as its backend account, `current_user` proves the
  JWT claim drove the role switch.

[pgproto]: https://www.postgresql.org/docs/current/protocol-message-formats.html

## Postgres roles

Three roles are created by `postgres-init/01-init.sql`:

| role     | LOGIN | granted to         | what it can do                                              |
|----------|-------|--------------------|-------------------------------------------------------------|
| pgproxy  | yes   | pgreader, pgwriter | the proxy's backend identity; no privileges of its own      |
| pgreader | no    | -                  | `SELECT` on `messages`                                      |
| pgwriter | no    | -                  | `SELECT, INSERT` on `messages` (plus sequence USAGE)        |

`pgreader` and `pgwriter` are deliberately `NOLOGIN`: nobody
authenticates *as* them, ever. They only become reachable via
`SET ROLE` from `pgproxy`. The `GRANT pgreader, pgwriter TO pgproxy;`
line is what makes that `SET ROLE` legal - remove it and the proxy's
`SET ROLE pgreader` call fails with `permission denied`.

The pattern scales: to add a new role mapping, create the role,
`GRANT` it to `pgproxy`, and add (or change) a Keycloak claim mapper
that emits its name as `pg_role`.

## Issuer-mismatch note

The `iss` claim in a Keycloak token is the URL the *client* used to
fetch the token. Inside Kubernetes the app reaches Keycloak as
`http://external-keycloak:8180`, so tokens it gets carry
`iss=http://external-keycloak:8180/realms/poc`. The proxy lives on
the Compose network and fetches the JWKS from
`http://keycloak:8080/...` directly. The two URLs are different, but
the JWKS endpoint only ships signing keys - it does not constrain
the issuer. The proxy still requires `iss` to match the
`EXPECTED_ISS` env var, so the trust boundary is sound.

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

Build the images, start the services, configure Keycloak, and deploy
the app:

```sh
make up
```

`up` runs, in order: build the app and proxy images, start Compose
services (Keycloak, Postgres, proxy), apply the Kubernetes namespace
+ ExternalName Services, bootstrap Keycloak (realm + client + scope
+ mapper), deploy the app, and verify.

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

- `make up` – build images, start services, bootstrap Keycloak, deploy the app
- `make test` – run the smoke test; needs a port-forward
- `make test-all` – run the smoke test with a temporary port-forward
- `make status` – show Kubernetes, Docker, image, log, and port state
- `make full-check` – run everything and always clean up
- `make clean` – remove all demo runtime state
- `make check-local` – syntax-check Python and dry-run the k8s manifests

## API Shape

- `GET /` – lists endpoints and configured upstreams
- `GET /healthz` – process liveness
- `GET /query` – fetches a JWT from Keycloak, connects to the proxy
  using the JWT as the Postgres password, returns
  `{session_user, current_user, now, message, token_expires_in}`.
  `session_user` is the proxy's backend identity (`pgproxy`);
  `current_user` is the role the proxy switched to with `SET ROLE`,
  driven by the JWT's `pg_role` claim.
- `GET /query/bad-token` – sends a forged JWT to the proxy on
  purpose; succeeds only if the proxy's response is a Postgres error.
  If the forged token is ever accepted, the endpoint returns 500 -
  i.e. the test fails loudly.

## What `make test-all` proves

The test calls `/query` once and `/query/bad-token` once, then
asserts:

- `/query` returns `session_user = pgproxy` (the login identity the
  proxy used on the upstream connection) and `current_user = pgreader`
  (the value of the JWT's `pg_role` claim, applied via `SET ROLE`).
  A row from the `messages` table comes back, proving the resulting
  session can actually read data.
- `/query/bad-token` returns `{"rejected": true, "error": "..."}`
  with the word `JWT` in the error - i.e. the proxy refused to open
  a Postgres session at all.
- The proxy logs contain both a `JWT_OK` line (good token) and a
  `JWT_REJECTED` line (forged token).
- The app log contains a `TOKEN_FETCHED` line (Keycloak returned a
  token).

If any of those don't match, the smoke test exits non-zero.

## Explore Keycloak in the UI

While the demo is up, open <http://localhost:8180/>. Sign in as
`admin` / `admin`, switch to the `poc` realm in the top-left, and
poke around:

- **Clients → poc-app** – the confidential client the app
  authenticates as. Service Accounts is on; Standard Flow and Direct
  Access Grants are off (we only do `client_credentials`).
- **Clients → poc-app → Credentials** – the `client_secret` the
  bootstrap script writes into the `keycloak-client` Kubernetes
  Secret.
- **Clients → poc-app → Client scopes** – `pg-role` is attached as a
  default scope. Default scopes are added to every token the client
  receives, including service-account tokens.
- **Client scopes → pg-role → Mappers → pg_role-claim** – the
  hardcoded-claim mapper that adds `"pg_role": "pgreader"` to the
  access token. Change the value here, run `make test-all` again,
  and watch the test fail because `current_user` no longer matches
  `pgreader`. (Or set the value to `pgwriter` and run
  `EXPECTED_ROLE=pgwriter make test-all`.)
- **Sessions** – every time the app calls `/query` you'll see a
  fresh service-account session.

You can also pull a token by hand:

```sh
docker compose exec keycloak \
  curl -s -d grant_type=client_credentials \
       -d client_id=poc-app \
       -d client_secret="$(make -s ...)" \
       http://localhost:8080/realms/poc/protocol/openid-connect/token
```

…or, easier, copy the secret out of the k8s Secret:

```sh
kubectl -n keycloak-pg-demo get secret keycloak-client \
  -o jsonpath='{.data.client_secret}' | base64 -d
```

## Inspect the proxy

Tail proxy logs to watch validation in real time:

```sh
docker compose logs -f pg-jwt-proxy
```

Or talk to the proxy directly with `psql`, using a real JWT as the
password (assumes Keycloak port-forward / direct host access):

```sh
TOKEN="$(curl -s -d grant_type=client_credentials \
              -d client_id=poc-app \
              -d "client_secret=$(kubectl -n keycloak-pg-demo \
                                  get secret keycloak-client \
                                  -o jsonpath='{.data.client_secret}' | base64 -d)" \
              http://localhost:8180/realms/poc/protocol/openid-connect/token \
            | jq -r .access_token)"

PGPASSWORD="$TOKEN" psql -h localhost -p 6432 -U poc-app -d pocdb \
  -c "SELECT current_user, current_setting('role');"
```

> The `iss` in this token will be `http://localhost:8180/realms/poc`,
> which won't match the proxy's `EXPECTED_ISS`. The proxy will reject
> it - that is exactly the point. To experiment, edit `EXPECTED_ISS`
> in `docker-compose.yml` and `docker compose up -d pg-jwt-proxy` to
> recreate it.

## Gotchas / lessons from getting this to work

A few things that bit me while assembling this and aren't obvious
from reading the code:

- **`aud` vs `azp` for `client_credentials` tokens.** PyJWT validates
  the `aud` claim by default whenever a token has one. Keycloak puts
  `aud=account` in service-account access tokens (it's the audience
  for the built-in `account` client), which is meaningless to us.
  The proxy turns off `aud` validation and instead requires
  `azp == poc-app`. `azp` (Authorized Party) is the right claim for
  this flow - it identifies the client the token was issued *to*,
  which is exactly the "who's calling" question the proxy needs to
  answer.
- **`kcadm get client-scopes -q name=...` does not filter.** The
  `client-scopes` REST endpoint silently ignores `-q`; kcadm returns
  *all* scopes. An earlier version of `04-bootstrap-keycloak.sh`
  did `tail -n 1` on the result and picked an unrelated scope's
  UUID, then attached *that* scope (with no mapper) to the client
  as a default. Tokens came back without a `pg_role` claim and the
  proxy rejected every connection. The fix is to list with
  `--fields id,name --format csv` and `awk` for the row whose name
  matches.
- **`kubectl wait --for=condition=Ready pod -l ...` races with
  `rollout restart`.** Right after a restart the old terminating pod
  still matches the label selector. `kubectl wait` then times out
  watching *that* pod become Ready (it never will - it's
  terminating). Use
  `kubectl wait --for=condition=Available deployment/...` instead;
  it tracks the new ReplicaSet's status, not arbitrary pods.
- **`python:3.12-slim` already has a system user named `proxy`.**
  The first build of `proxy/Dockerfile` failed with
  `useradd: user 'proxy' already exists`. Renamed to `pgproxy`.
  Worth `getent passwd | grep <name>` against the base image before
  claiming a name.
- **Issuer URL ≠ JWKS-fetch URL.** The `iss` claim Keycloak emits
  is the URL the *caller* used to fetch the token. The proxy fetches
  the JWKS over its own Compose-network view of Keycloak. Those URLs
  are different on purpose - JWKS only ships signing keys, it
  doesn't constrain the issuer. But the `EXPECTED_ISS` env var must
  match the URL the *app* uses, not the URL the proxy uses.
- **`current_user` vs `session_user` after `SET ROLE`.** It's easy
  to write a smoke test that asserts `current_user = pgproxy`,
  expecting it to be the login identity. After `SET ROLE pgreader`,
  `current_user` *is* `pgreader`; the login identity is
  `session_user`. Asserting both is what proves the trust chain end
  to end.

## Cleanup Guarantee

`make clean` removes and verifies removal of:

- Kubernetes namespace `keycloak-pg-demo`
- Docker Compose containers (`keycloak-pg-demo-keycloak`,
  `keycloak-pg-demo-postgres`, `keycloak-pg-demo-proxy`)
- Docker Compose volumes
- Docker network
- local images `keycloak-pg-demo-app:demo`, `keycloak-pg-demo-proxy:demo`
- `logs/`
- `/tmp/keycloak-pg-demo-port-forward.log`

After `make clean`, a new run starts from an empty runtime state.

## Files

```text
keycloak-pg/
├── docker-compose.yml
├── Makefile
├── README.md
├── postgres-init/01-init.sql      pgproxy + pgreader + pgwriter + messages table
├── proxy/                         PG-wire JWT auth proxy
│   ├── Dockerfile
│   ├── requirements.txt
│   └── proxy.py
├── app/                           FastAPI client of Keycloak + the proxy
│   ├── Dockerfile
│   ├── requirements.txt
│   └── main.py
├── k8s/
│   ├── 00-namespace.yaml
│   ├── 01-external-pg-proxy-service.yaml
│   ├── 02-external-keycloak-service.yaml
│   ├── 03-app-deployment.yaml
│   └── 04-app-service.yaml
└── scripts/01-..12-               build / bootstrap / verify / clean
```
