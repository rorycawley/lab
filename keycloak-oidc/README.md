# OIDC BFF Demo

A small learning project that shows the **OIDC Backend-for-Frontend
(BFF) pattern**: a Python web app in Rancher Desktop Kubernetes that
authenticates users against **Keycloak** (running in Docker Compose),
keeps OIDC tokens server-side, and gives the browser only an
`HttpOnly` session cookie. Per-user data is stored in **Postgres**
(also running in Docker Compose) keyed by Keycloak's `sub` claim.

In production Keycloak would sit in front of AD (or any other
upstream IdP); the user *identity* lives in Keycloak, the user
*data* lives in Postgres.

## What It Shows

- **The browser never sees an access token.** Login goes
  browser → BFF `/login` → Keycloak (OIDC authorization code + PKCE) →
  BFF `/callback`. The BFF stores the ID/access/refresh tokens in an
  in-memory session map and sets an `HttpOnly`, `SameSite=Lax`
  session cookie. The cookie value is just an opaque random ID.
- **Auto-provisioning on first login.** The BFF upserts a row in
  Postgres `user_profile` keyed by the Keycloak `sub` claim, copying
  `email`, `preferred_username`, and `name` from the verified ID
  token. `last_login_at` updates on every login. There are no
  passwords in Postgres.
- **Per-user data is scoped by `sub`.** `GET /notes` and `POST /notes`
  read/write the `notes` table filtered by the session's `sub`. Alice
  cannot see Bob's notes — the smoke test asserts this.
- **RP-initiated logout.** `POST /logout` clears the BFF session and
  redirects the browser to Keycloak's `end_session_endpoint` with
  `id_token_hint`, so the IdP session is killed too. Coming back to
  `/me` after logout is a 401.
- **Real auth-code flow in CI.** The smoke test drives the full
  authorization-code flow with `curl` + a cookie jar, including
  parsing Keycloak's login form action and posting credentials to it.
  No ROPC, no shortcuts.

## Architecture

```text
Browser                                      Docker Compose host
  │                                          ┌────────────────────────┐
  │  GET /                                    │ keycloak    :8180     │
  │  GET /login    ─── 302 ──►─────────────►──┤   start-dev            │
  │                                           │   KC_HOSTNAME =        │
  │       (Keycloak login form)               │     http://localhost   │
  │  POST username/password ◄───────────────►─│     :8180              │
  │                                           │                        │
  │  GET /callback?code=...                   │ postgres    :5432     │
  ▼                                           │   user_profile, notes  │
Python BFF (k8s namespace: keycloak-oidc-demo)│   bffapp / bffpass     │
  │                                           └─────────▲──────────────┘
  │  POST /token (auth code + PKCE) ──────────────────► │
  │  ◄── id_token, access_token, refresh_token        (backchannel via
  │                                                     ExternalName)
  │  Verify id_token: signature (JWKS), iss, aud,
  │                   exp, nonce
  │  upsert user_profile, create session, set cookie
  ▼
Browser ◄── 302 / + Set-Cookie: bff_session=...; HttpOnly
```

The BFF inside Kubernetes reaches the Compose host through two
ExternalName Services in the `keycloak-oidc-demo` namespace:

- `external-keycloak`  → `host.rancher-desktop.internal:8180`
- `external-postgres`  → `host.rancher-desktop.internal:5432`

The browser reaches the BFF on `localhost:8080` via
`kubectl port-forward`.

## How auth flows (read this first)

There are two URLs for the same Keycloak realm and they look
different on purpose:

| Used by   | Base URL                                          |
|-----------|---------------------------------------------------|
| Browser   | `http://localhost:8180/realms/poc`                 |
| BFF (k8s) | `http://external-keycloak:8180/realms/poc`         |

The browser cannot resolve `external-keycloak`, and the BFF pod
cannot reach `localhost:8180`. They both must agree on the **issuer
claim** in the ID token. The fix is `KC_HOSTNAME=http://localhost:8180`
on the Keycloak container: it pins the issuer to that one URL
regardless of which Host header was on the request. The BFF
validates `iss == http://localhost:8180/realms/poc` and trusts only
that.

The full flow for one login:

```text
browser                 BFF                  Keycloak
   │                     │                       │
   │── GET /login ──────►│                       │
   │                     │  pending_logins[state]
   │                     │  = {verifier, nonce}
   │◄── 302 to authorize │                       │
   │── GET .../auth?... ─┼──────────────────────►│
   │◄── login HTML ──────┼───────────────────────│
   │── POST creds ───────┼──────────────────────►│
   │◄── 302 to /callback?code=&state= ───────────│
   │── GET /callback ───►│                       │
   │                     │── POST /token ───────►│  (backchannel)
   │                     │◄── id_token ──────────│
   │                     │  verify JWKS+iss+aud+
   │                     │         exp+nonce
   │                     │  upsert user_profile
   │                     │  sessions[sid] = ...
   │◄── 302 / + Set-Cookie bff_session=sid; HttpOnly
   │── GET /me ─────────►│                       │
   │                     │  sub from session →
   │                     │  SELECT user_profile  │
   │◄── {claims, profile}│                       │
```

## Why a BFF at all?

The browser-only OIDC pattern (SPA holds the access token in JS
memory) is hard to do safely:

- access tokens accessible to any XSS,
- refresh tokens that can't easily be rotated client-side,
- CORS gymnastics to call APIs.

A BFF moves the OIDC client *off* the browser. The browser only
holds an opaque cookie; the tokens never cross the client. CSRF is
the only thing left to think about (handled here by `SameSite=Lax`
plus `POST` for state-changing endpoints).

## Postgres schema

```sql
-- BFF service account
CREATE ROLE bffapp WITH LOGIN PASSWORD 'bffpass';
GRANT CONNECT ON DATABASE pocdb TO bffapp;

CREATE TABLE user_profile (
    sub                 TEXT PRIMARY KEY,
    email               TEXT,
    preferred_username  TEXT,
    display_name        TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE notes (
    id          SERIAL PRIMARY KEY,
    sub         TEXT        NOT NULL REFERENCES user_profile(sub) ON DELETE CASCADE,
    text        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`bffapp` has only `SELECT/INSERT/UPDATE` on `user_profile` and
`SELECT/INSERT/DELETE` on `notes`. There is no per-user database
role: identity is application-level, gated by the BFF's session
lookup.

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

Build the image, start the services, configure Keycloak, deploy the
BFF:

```sh
make up
```

`up` runs, in order: build the app image, start Compose services
(Keycloak + Postgres), apply the Kubernetes namespace + ExternalName
Services, bootstrap Keycloak (realm + client + two seeded users),
deploy the app, and verify.

Run the smoke test with a temporary port-forward:

```sh
make test-all
```

Forward the BFF to `localhost:8080` and click around in a browser:

```sh
make port-forward
open http://localhost:8080/
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

- `make up` – build image, start services, bootstrap Keycloak, deploy app
- `make test` – run the smoke test; needs a port-forward
- `make test-all` – run the smoke test with a temporary port-forward
- `make port-forward` – forward `localhost:8080 -> keycloak-oidc-demo-app:8080`
- `make status` – show Kubernetes, Docker, image, log, and port state
- `make full-check` – run everything and always clean up
- `make clean` – remove all demo runtime state
- `make check-local` – syntax-check Python and dry-run k8s manifests

## Seeded users

| username | password | email             | name           |
|----------|----------|-------------------|----------------|
| alice    | alice    | alice@example.com | Alice Anderson |
| bob      | bob      | bob@example.com   | Bob Brown      |

These exist only in Keycloak. The first login of each user creates
the corresponding row in `user_profile`.

## API Shape

- `GET /`                   – HTML home page. Logged-out shows a Log-in
                              button; logged-in shows the user, their
                              notes, an add-note form, and a Log-out
                              button. The notes calls happen via
                              `fetch(..., {credentials: "same-origin"})`.
- `GET /healthz`            – process liveness (no DB)
- `GET /readyz`             – `SELECT 1` against Postgres
- `GET /login`              – generates `state`, `nonce`, PKCE
                              `code_verifier`/`code_challenge`, stores
                              them in memory keyed by `state`, redirects
                              the browser to Keycloak's `auth` endpoint
- `GET /callback`           – validates `state`, exchanges `code` for
                              tokens (with `code_verifier`), verifies
                              the ID token (signature / iss / aud / exp
                              / nonce), upserts `user_profile`, creates
                              a server-side session, sets the
                              `bff_session` HttpOnly cookie, redirects
                              to `/`
- `GET /me`                 – session-gated. Returns `sub`, selected
                              ID-token claims, and the `user_profile`
                              row from Postgres.
- `GET /notes`              – session-gated. Lists notes for the
                              session's `sub`.
- `POST /notes`             – session-gated. Inserts a note for the
                              session's `sub`. Body: `{"text": "..."}`.
- `POST /logout` / `GET /logout`
                            – clears the local session, deletes the
                              cookie, and redirects to Keycloak's
                              `end_session_endpoint` with
                              `id_token_hint` and
                              `post_logout_redirect_uri=http://localhost:8080/`.

## What `make test-all` proves

The test drives the **real** authorization-code flow end-to-end with
`curl` + a cookie jar — no ROPC. It asserts:

- `GET /me` without a cookie is 401.
- Logging in alice and bob via `/login` → Keycloak login form → POST
  credentials → `/callback` succeeds. The cookie jar holds
  `bff_session` afterwards.
- `GET /me` returns the right `email`, `preferred_username`, and a
  populated `profile` row from Postgres for each user.
- `POST /notes` adds a note for each user.
- `GET /notes` returns *only* that user's notes — bob does not see
  alice's note.
- `POST /logout` returns a 302 whose `Location` is Keycloak's
  `end_session_endpoint` with `id_token_hint` and
  `post_logout_redirect_uri` query parameters.
- `GET /me` after logout is 401.
- The app log contains `LOGIN_OK email=alice@...`,
  `LOGIN_OK email=bob@...`, `USER_PROVISIONED`, `NOTE_ADDED`, and
  `LOGOUT`.

If any of those don't match, the smoke test exits non-zero.

## Explore Keycloak in the UI

While the demo is up, open <http://localhost:8180/>. Sign in as
`admin` / `admin`, switch to the `poc` realm in the top-left, and
poke around:

- **Clients → bff → Settings** – `Standard flow` (auth code) is on,
  `Direct access grants` (ROPC) is off, `Service accounts` is off,
  `Client authentication` is on (confidential).
- **Clients → bff → Settings → Valid redirect URIs** –
  `http://localhost:8080/callback`. Change this and `/callback`
  fails.
- **Clients → bff → Settings → Valid post logout redirect URIs** –
  `http://localhost:8080/`. Change this and RP-initiated logout
  bounces with an error.
- **Clients → bff → Advanced → Proof Key for Code Exchange Code
  Challenge Method** – `S256`. With this, Keycloak rejects auth code
  exchanges that don't include a matching `code_verifier`.
- **Clients → bff → Credentials** – the `client_secret` the
  bootstrap script writes into the `oidc-client` Kubernetes Secret.
- **Users → alice / bob** – the two seeded users. Their UUIDs are
  what shows up as `sub` in the BFF logs and in
  `user_profile.sub`.
- **Sessions** – every login adds a row. Logging out via the BFF
  removes it.

## Inspect Postgres

```sh
docker compose exec -T postgres psql -U pgadmin -d pocdb \
  -c 'SELECT sub, preferred_username, email, last_login_at FROM user_profile;'

docker compose exec -T postgres psql -U pgadmin -d pocdb \
  -c 'SELECT n.id, u.preferred_username, n.text, n.created_at
        FROM notes n JOIN user_profile u USING (sub)
        ORDER BY n.id;'
```

## Gotchas / lessons from getting this to work

A few things that bit me while assembling this:

- **Issuer URL stability.** With `start-dev` and no `KC_HOSTNAME`,
  Keycloak stamps the issuer with whichever Host header was on the
  request. The browser hits Keycloak as `localhost:8180`; the BFF
  hits it as `external-keycloak:8180`. Without pinning the hostname,
  every other login would flip the issuer and break ID-token
  validation. The fix is one env var:
  `KC_HOSTNAME=http://localhost:8180`. The BFF can still reach
  Keycloak over `external-keycloak:8180` because Keycloak doesn't
  reject by Host — `KC_HOSTNAME` only controls the URLs it
  *advertises* (issuer, discovery doc, redirects). The BFF
  hardcodes its endpoints rather than trusting discovery.
- **PKCE `code_verifier` in the token request.** PyJWT does not
  enforce PKCE; Keycloak does. The token-exchange POST has to
  include `code_verifier=<the original random string>`, otherwise
  Keycloak returns `invalid_grant` and the auth code is gone (codes
  are single-use). The verifier is stored in `pending_logins[state]`
  on `/login` and looked up on `/callback`.
- **OIDC nonce is the BFF's job.** PyJWT validates `iss`, `aud`,
  `exp`, signature — it does **not** validate `nonce`. We send
  `nonce` on `/login`, store it in `pending_logins`, and check it
  manually on the decoded ID token.
- **`SameSite=Lax` survives the OIDC redirect.** The
  Keycloak `/callback` is a top-level navigation (the browser
  follows a 302 from Keycloak), which is allowed under `Lax`.
  `SameSite=Strict` would block the cookie on this navigation.
- **HTML form action contains `&amp;`.** Keycloak's login page
  renders the form action with `&amp;`. The smoke test has to
  decode it to `&` before posting credentials, or the
  `session_code`/`execution`/`tab_id` query params get lost and
  Keycloak returns a generic error page.
- **Cookie jars in curl are port-agnostic.** `localhost:8080` and
  `localhost:8180` share a curl cookie jar (same hostname). That's
  fine here — Keycloak ignores the BFF's cookie and vice versa —
  but in a real deployment the BFF and IdP would be on different
  hostnames.
- **`xmax = 0` is the cheapest first-login signal.** The upsert
  uses `RETURNING (xmax = 0) AS provisioned_now` to log
  `USER_PROVISIONED` only on the insert path, not on subsequent
  logins. No extra round-trip, no separate `INSERT … WHERE NOT
  EXISTS`.

## Cleanup Guarantee

`make clean` removes and verifies removal of:

- Kubernetes namespace `keycloak-oidc-demo`
- Docker Compose containers (`keycloak-oidc-demo-keycloak`,
  `keycloak-oidc-demo-postgres`)
- Docker Compose volumes
- Docker network
- local image `keycloak-oidc-demo-app:demo`
- `logs/`
- `/tmp/keycloak-oidc-demo-port-forward.log`

After `make clean`, a new run starts from an empty runtime state.

## Files

```text
keycloak-oidc/
├── docker-compose.yml
├── Makefile
├── README.md
├── postgres-init/01-init.sql        bffapp role + user_profile + notes tables
├── app/                             FastAPI BFF
│   ├── Dockerfile
│   ├── requirements.txt
│   └── main.py
├── k8s/
│   ├── 00-namespace.yaml
│   ├── 01-external-keycloak-service.yaml
│   ├── 02-external-postgres-service.yaml
│   ├── 03-app-deployment.yaml
│   └── 04-app-service.yaml
└── scripts/01-..12-                 build / bootstrap / verify / test / clean
```
