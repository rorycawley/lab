# Vault + PostgreSQL: A Zero-Trust Security Demo

A working, end-to-end proof of concept that shows *why* a zero-trust security
model exists, *what* the moving parts are, and *how* they fit together — using
HashiCorp Vault, PostgreSQL, and Kubernetes.

It's not a Vault tutorial. It's not a Postgres-HA demo. It's an answer to a
specific question:

> *"My Python app needs a Postgres password. Where does that password come
> from, who is allowed to use it, and what happens when something goes wrong?"*

Read this top to bottom and run `make doctor && make up && make verify` at the
end — every claim in this README is exercised by a script that exits non-zero
if the claim is false.

---

## The problem this demo exists to solve

Picture the simplest possible production setup: a Python web service that
queries a Postgres database. It needs a database password to connect.

Where does that password come from? Each common answer has a problem.

| The naive answer | What it actually means |
|---|---|
| Hard-coded in source | The password is in Git history forever, visible to every developer who's ever cloned the repo, and to anyone who breaches the source repository. |
| Baked into the container image | The password is in every layer of every image push, archived in registries, and visible to anyone who can `docker pull` it. |
| Set as an env var in the Deployment YAML | The password is in `kubectl get deployment -o yaml`, in version control if YAML is committed, and visible to anyone with `pods/exec` rights in the namespace. |
| Stored as a Kubernetes Secret | Better — but Secrets are base64, not encrypted at rest by default, visible to anyone with `secrets/get` in the namespace, and *long-lived*. |
| Generated once and rotated yearly | Long enough for an attacker who steals it to do whatever they want. Rotation is risky and disruptive enough that nobody actually does it. |

There's a deeper problem underneath all five answers: the password is *the
identity*. Whoever holds the string **is** the app, indefinitely. There's no
way to ask "who is this caller and should they be allowed to do this?" — only
"do they have the password?"

This is the question this demo answers. Not by tweaking one of the five
options above. By **separating identity from credentials**.

---

## The mental model

Five concepts, each mapping to a class of problem:

### 1. Identity is separate from credentials

> *"The app proves who it is. Vault decides what credential to give it."*

Instead of giving the app a database password, give the app a **Kubernetes
ServiceAccount**. The kubelet projects a JWT into the Pod that the cluster
itself signed. Vault verifies that JWT against the Kubernetes API. Now the
app's identity is `demo/demo-app` — a name the cluster vouches for — not a
password the app happens to hold.

If the app is compromised and an attacker tries to use that identity from a
different Pod, the JWT won't match. Identity is *bound* to the workload, not
to a string.

### 2. Credentials are short-lived and dynamic

> *"Vault makes a fresh database user every time the app asks. The user dies
> when the lease expires."*

Vault's database secrets engine generates a new Postgres user — `v-token-demo-app-runtime-abc123` —
on demand, with a 15-minute TTL. When the lease expires, Vault drops the
Postgres role. There is no long-lived password to steal: a stolen credential
is useful for a maximum of 15 minutes, less if it's revoked.

This also gives you forensics. Every database query is tagged with the
generated username, so logs say *exactly which Vault lease* did *exactly which
SQL operation* at *exactly what time*.

The full issuance path, in 10 steps:

```text
   Pod (demo/python-postgres-demo)              Vault                          Postgres
   ─────────────────────────────────            ─────                          ────────
   ┌─ vault-agent-init ──────┐
   │ 1. read SA JWT          │
   │    /var/run/secrets/    │
   │    kubernetes.io/.../   │
   │    token                │
   │                         │   2. POST auth/kubernetes/login (jwt=...)
   │                         │ ────────────────────────────────▶
   │                         │
   │                         │   3. TokenReview → K8s API → ✓ identity OK
   │                         │
   │                         │   4. apply policy demo-app-runtime
   │                         │      → grants `read` on
   │                         │        database/creds/demo-app-runtime
   │                         │
   │                         │   5. database engine: CREATE ROLE
   │                         │ ────────────────────────────────────────────▶
   │                         │      v-token-demo-app-runtime-XXXXX
   │                         │      GRANT app_runtime
   │                         │ ◀───────────────── ack ─────────────────────
   │                         │
   │   6. lease + user/pass  ◀
   │                         │
   │   7. render file:       │
   │      /vault/secrets/    │
   │      db-creds           │
   └─────────┬───────────────┘
             │
             ▼
   ┌─ app container ─────────┐
   │ 8. read /vault/secrets/ │
   │    db-creds             │
   │                         │   9. psycopg.connect(host=..., user=v-token-...,
   │                         │      password=..., sslmode=verify-full)
   │                         │ ──────────────────────────────────────────────▶
   │                         │
   │                         │   10. SELECT/INSERT/UPDATE/DELETE
   │                         │       (DROP TABLE → permission denied)
   └─────────────────────────┘

   After 15 minutes the lease expires. Vault drops the Postgres role and
   terminates active sessions. The app's pool max-lifetime (10 minutes)
   rotates connections before that, so the rotation is invisible to users.
```

### 3. Authorization is layered

> *"Vault decides if the app can ask. Postgres decides what the resulting user
> can do. NetworkPolicy decides if the request can even reach the database.
> Pod Security decides whether the Pod was allowed to run in the first place."*

A single layer is one bug away from breach. Production security is *defense
in depth*: every layer enforces its own policy independently, so an
attacker has to break multiple layers to do real damage.

In this demo:

- **Vault** authorises which credential paths each identity can read
- **Postgres** authorises what each generated user can do (CRUD only — no DDL,
  no role creation)
- **NetworkPolicy** authorises which Pods can reach Vault and Postgres at the
  L4 level
- **Pod Security Admission** authorises what Pods are allowed to run at all
  (no privileged, no root, no host paths)
- **TLS** authorises connections cryptographically (`verify-full` everywhere)

Visualised as a stack the attacker has to climb:

```text
  ┌────────────────────────────────────────────────────────────────────┐
  │ 1. Pod Security Admission   "restricted" profile, admission-time   │
  ├────────────────────────────────────────────────────────────────────┤
  │ 2. Workload identity         K8s SA → cluster-signed JWT           │
  ├────────────────────────────────────────────────────────────────────┤
  │ 3. Vault Kubernetes auth     TokenReview verifies the JWT          │
  ├────────────────────────────────────────────────────────────────────┤
  │ 4. Vault policy              scoped to specific credential paths   │
  ├────────────────────────────────────────────────────────────────────┤
  │ 5. NetworkPolicy             default-deny + 3 contracted flows     │
  ├────────────────────────────────────────────────────────────────────┤
  │ 6. TLS verify-full           Vault HTTPS, Postgres SSL, both with  │
  │                              cert-manager-issued CA                │
  ├────────────────────────────────────────────────────────────────────┤
  │ 7. PostgreSQL grants         SELECT/INSERT/UPDATE/DELETE only;     │
  │                              DROP TABLE / CREATE ROLE denied       │
  ├────────────────────────────────────────────────────────────────────┤
  │ 8. Lease TTL                 15-minute credential, mass-revocable  │
  ├────────────────────────────────────────────────────────────────────┤
  │ 9. Audit (two devices)       stdout + on-disk file, every API call │
  └────────────────────────────────────────────────────────────────────┘

  An attacker must defeat all 9 layers within the lease window — and
  every step they take is recorded twice.
```

Each layer is verified independently. A breach in any one of them does not
compromise the others.

### 4. Revocation is an operational primitive, not an afterthought

> *"If the app is compromised at 3am, you need to kill its access in seconds —
> without breaking every other workload."*

Long-lived passwords have a fundamental problem at incident response time: to
revoke them, you change the password, which breaks every legitimate consumer
simultaneously. Operators avoid revocation because revocation is too costly,
which means stolen credentials stay valid until someone notices.

With Vault dynamic credentials, revocation is `vault lease revoke -prefix database/creds/demo-app-runtime`
— one command kills every outstanding runtime credential at the database
layer (the Postgres roles are dropped, active sessions terminated). The
legitimate app immediately gets a new credential and reconnects. Total impact:
a few seconds of latency.

This demo proves it works under load (Phase 15 revocation drill).

### 5. Configuration is declared, not scripted

> *"If you can't reproduce it from a clean cluster, you don't actually know
> what your security posture is."*

Imperative `vault write` calls drift over time. Manual config gets reapplied
inconsistently. State diverges from intent, and nobody notices until something
breaks. The remedy is **declarative IaC**: Terraform describes what Vault
should look like, and `terraform plan` flags any drift.

This demo bootstraps Vault entirely from `terraform/`. `make verify-iac`
detects drift in both Vault config (`terraform plan -detailed-exitcode`) and
NetworkPolicies (`kubectl diff`). `make reset` proves the entire system
reproduces from a wiped slate in under 10 minutes.

---

## What this demo proves

Run `make verify` and 16 verify scripts will exit 0 — or non-zero with a
specific failure pointing at exactly which claim broke. The claims, in plain
language:

```text
A Kubernetes workload proves its identity (not a password).
Vault verifies that identity through the Kubernetes API.
Vault policy decides what credential paths that identity can read.
Vault issues a short-lived PostgreSQL user, scoped to runtime CRUD only.
PostgreSQL enforces least privilege even if the credential leaks.
NetworkPolicy denies any Pod that's not the demo app from reaching the database.
Pod Security Admission rejects any Pod that doesn't run non-root with dropped capabilities.
TLS protects every hop with cert-manager-issued certificates and verify-full validation.
Audit logs prove what happened — both allowed and denied operations.
Mass revocation kills every outstanding credential without breaking the system.
The whole thing reproduces from scratch in under 10 minutes via Terraform.
```

The core principle, in one sentence:

> *The app is not trusted because it is inside Kubernetes. The app is trusted
> only after identity, policy, network, TLS, and database checks succeed —
> independently, every time.*

---

## Architecture

```text
                              ┌─────────────────────────────────────────┐
                              │       Kubernetes cluster                │
                              │                                         │
   ┌──────────────────┐       │  ┌─ namespace: demo ─────────────────┐  │
   │   Operator       │       │  │                                   │  │
   │  (you, with      │       │  │  ┌─ Pod: python-postgres-demo ──┐ │  │
   │   kubectl +      │       │  │  │  ServiceAccount: demo-app    │ │  │
   │   terraform)     │       │  │  │                              │ │  │
   └────────┬─────────┘       │  │  │  ┌─ vault-agent-init ──┐    │ │  │
            │                  │  │  │  │ login + render       │    │ │  │
            │ apply via TF     │  │  │  └──────────┬───────────┘    │ │  │
            ▼                  │  │  │             │                │ │  │
   ┌──────────────────┐       │  │  │  ┌──────────▼───────────┐    │ │  │
   │  Vault config    │       │  │  │  │ /vault/secrets/      │    │ │  │
   │  (terraform/)    │       │  │  │  │ db-creds (mode 0400) │    │ │  │
   │                  │       │  │  │  │ DB_USERNAME=v-...    │    │ │  │
   │ - auth methods   │       │  │  │  │ DB_PASSWORD=...      │    │ │  │
   │ - policies       │       │  │  │  └──────────┬───────────┘    │ │  │
   │ - DB engine      │       │  │  │             │                │ │  │
   │ - audit devices  │       │  │  │  ┌──────────▼───────────┐    │ │  │
   └────────┬─────────┘       │  │  │  │ app (Python+Flask)   │    │ │  │
            │                  │  │  │  │ - reads file         │    │ │  │
            │                  │  │  │  │ - psycopg pool       │    │ │  │
            ▼                  │  │  │  │ - HTTP /companies    │    │ │  │
   ┌──────────────────┐       │  │  │  └──────────┬───────────┘    │ │  │
   │  ┌─ namespace:   │       │  │  │             │                │ │  │
   │  │   vault ──┐   │       │  │  └─────────────┼────────────────┘ │  │
   │  │           │   │       │  │                │                  │  │
   │  │  Vault    │   │       │  │  Default-deny NetworkPolicy       │  │
   │  │  - auth   │◀──┼───────┼──┘  permits only:                    │  │
   │  │  - policy │   │       │     demo-app → vault:8200             │  │
   │  │  - DB eng.│   │       │     demo-app → host:5432              │  │
   │  │  - audit  │───┼───────┼─────vault → host:5432  (DB engine)    │  │
   │  └───────────┘   │       └────────────────┬──────────────────────┘  │
   └──────────────────┘                        │ (host network)         │
                                               │                         │
                                       ┌───────▼───────────────┐         │
                                       │ Docker Compose         │         │
                                       │   PostgreSQL 16        │         │
                                       │ - TLS-only             │         │
                                       │ - schema_owner         │         │
                                       │ - migration_runtime    │         │
                                       │ - app_runtime          │         │
                                       │ - vault_admin (Vault   │         │
                                       │   uses to create users)│         │
                                       └────────────────────────┘         │
                                                                         │
   Legend                                                                │
   ──────                                                                │
   ───▶  control flow (config / identity)                                │
   ◀──   data flow (issued credentials)                                  │
```

Three independent control planes:

- **Operator-side IaC** (`terraform/`) — declares what Vault should look like;
  drift detected by `make verify-iac`.
- **In-cluster identity** — Kubernetes signs the SA JWT; Vault verifies it
  via TokenReview against the Kubernetes API server.
- **Database authority** — PostgreSQL enforces its own role grants regardless
  of what Vault thinks the credential is for.

The Python app never sees a Postgres password until the moment Vault Agent
writes it to a file inside its own Pod. The password lives for 15 minutes
before Vault automatically drops it. The app's only persistent secret is
its Kubernetes ServiceAccount, which the cluster itself is the source of
truth for.

---

## The build order is a teaching path

Each phase exists because of a concrete problem the previous phase didn't
solve. Reading the per-phase docs in order is the fastest way to understand
*why each piece is there*.

| Phase | Problem it solves | Click for detail |
|---|---|---|
| 0 | What does this demo claim, and how will we prove it? | [docs/phase-00-security-model.md](docs/phase-00-security-model.md) |
| 1 | Workload identity primitive — separate ServiceAccount, no extra RBAC | [docs/phase-01-kubernetes-foundation.md](docs/phase-01-kubernetes-foundation.md) |
| 2 | DB-side least privilege — even with valid credentials, app can't escalate | [docs/phase-02-postgresql-permissions.md](docs/phase-02-postgresql-permissions.md) |
| 3 | Vault server up, audit logging on — every API call leaves a trail | [docs/phase-03-vault-foundation-and-audit.md](docs/phase-03-vault-foundation-and-audit.md) |
| 4 | Vault learns to verify K8s identities via TokenReview | [docs/phase-04-vault-kubernetes-auth.md](docs/phase-04-vault-kubernetes-auth.md) |
| 5 | Vault policy boundaries — runtime can't read migrate creds, vice versa | [docs/phase-05-vault-policies.md](docs/phase-05-vault-policies.md) |
| 6 | Vault generates dynamic Postgres users on demand | [docs/phase-06-vault-database-secrets.md](docs/phase-06-vault-database-secrets.md) |
| 7 | Vault Agent sidecar renders credentials into the Pod's filesystem | [docs/phase-07-vault-agent-injector.md](docs/phase-07-vault-agent-injector.md) |
| 8 | Real Python app reads the file, connects, does CRUD; no DB password in env or YAML | [docs/phase-08-python-app-dynamic-creds.md](docs/phase-08-python-app-dynamic-creds.md) |
| 9 | Single command produces human-readable evidence | [docs/phase-09-denied-operation-evidence.md](docs/phase-09-denied-operation-evidence.md) |
| 10 | Connection pool with a max-lifetime shorter than the credential TTL | [docs/phase-10-connection-pool.md](docs/phase-10-connection-pool.md) |
| 11 | TLS at every hop with cert-manager — no plaintext anywhere | [docs/phase-11-tls-cert-manager.md](docs/phase-11-tls-cert-manager.md) |
| 12 | NetworkPolicy default-deny — only the demo's contracted flows are allowed | [docs/phase-12-networkpolicy.md](docs/phase-12-networkpolicy.md) |
| 13 | Container hardening — PSA `restricted`, dropped caps, read-only root | [docs/phase-13-container-hardening.md](docs/phase-13-container-hardening.md) |
| 14 | Structured audit evidence (JSON) — every claim mapped to a log record | [docs/phase-14-audit-evidence.md](docs/phase-14-audit-evidence.md) |
| 15 | Operational drills — rotate root, mass-revoke, outage recovery | [docs/phase-15-rotation-revocation-recovery.md](docs/phase-15-rotation-revocation-recovery.md) |
| 16 | Terraform as source of truth, drift detection, full reproducibility | [docs/phase-16-repeatability-and-iac.md](docs/phase-16-repeatability-and-iac.md) |

---

## Run it

### Preflight

```sh
make doctor
```

Confirms `kubectl`, `docker`, `helm`, `jq`, `openssl`, `terraform` are
present, your kubectl context points at a real cluster, and the cluster
is reachable.

### Apply and verify

```sh
make up
```

Applies all 16 phases from a clean state and runs the full verify chain.
~10 minutes on a fresh system; ~6 minutes when images are already cached.

### Repeatability check

```sh
make reset
```

Wipes everything (K8s namespaces, Compose volumes, runtime artifacts,
Terraform state) then runs `make up`. Times the wall clock and warns if
it exceeds 6 minutes. **This is the real test of "does this work."**

### Tear down

```sh
make clean
```

### See the evidence

```sh
make evidence       # human-readable markdown (Phase 14 report rendering)
make audit-report   # machine-readable JSON
```

### Run the operational drills

```sh
make rotate          # rotate Vault's root credential into Postgres
make revoke-runtime  # mass-revoke every outstanding runtime credential
make recover         # Vault outage + Postgres restart drills
make verify-rrr      # all three drills + assertions
```

These are not just tests. They're the operational primitives an SRE actually
uses at incident-response time, with all the messy interactions
(rotation-then-outage state loss, async revocation, pool warm-up timing)
exercised end-to-end. See `docs/phase-15` for what each drill proves.

### Detect drift

```sh
make verify-iac      # terraform plan -detailed-exitcode + NetworkPolicy diff
```

Run this if you suspect someone has manually changed Vault config or a
NetworkPolicy. Exits non-zero with a specific report of what diverged.

---

## What's deliberately out of scope

This demo proves a security *model*. It does not implement a production
*posture*. The differences matter:

| Concern | This demo | What production needs |
|---|---|---|
| Vault availability | Single-replica dev mode (in-memory state, no HA) | Integrated storage (Raft) with auto-unseal, 3+ replicas |
| Postgres availability | Single Docker Compose container | HA Postgres (CloudNativePG, Patroni, RDS, Cloud SQL) |
| Audit pipeline | stdout + on-disk file in the Pod | Shipped to a durable SIEM with backpressure handling |
| Image supply chain | Tag-pinned, no signature verification | Sigstore / Cosign signing + admission policy (Kyverno, OPA) |
| Pod-to-pod traffic | TLS to Vault and Postgres only | Service mesh (Linkerd, Istio) for mTLS between every Pod |
| NetworkPolicy logging | TCP timeouts (CNI doesn't log denials) | Cilium Hubble or Calico flow logs for positive denial records |
| Secret bootstrap | Dev root token in a Kubernetes Secret | Init/unseal flow with operator key custody (Shamir, KMS, HSM) |

Each of these is a separate multi-phase project. Adding them on top of this
demo is straightforward; *replacing* this demo's security model is not, which
is why the model itself is the focus.

---

## Requirements

- `kubectl`
- `docker`
- `make`
- `helm`
- `openssl`
- `jq` (Phase 13+ verify scripts)
- `terraform` >= 1.5 (Phase 16)
- A Kubernetes cluster — Rancher Desktop, k3d, kind, or any other; the
  demo only needs namespaces, ServiceAccounts, NetworkPolicy, and PSA
  enforcement, which all major distributions support.

Run `make doctor` to confirm everything is in place.

---

## Repository map

```text
README.md             ← you are here
docs/                 ← per-phase teaching docs (the why behind every piece)
k8s/                  ← Kubernetes manifests (namespaces, RBAC, app, Vault, NetworkPolicy, ...)
terraform/            ← Vault configuration as code (auth, policies, DB engine, audit)
scripts/              ← apply, verify, drill, and lifecycle scripts; lib/common.sh for shared helpers
app/                  ← the Python app that proves it all works (Flask + psycopg pool)
docker-compose.yml    ← the host-side TLS PostgreSQL
postgres-init/        ← SQL bootstrap (schema, roles, grants)
postgres-config/      ← pg_hba.conf
Makefile              ← the entry point — `make help` lists everything
```

Everything visible to the eye is something the demo touches and verifies. If
it's in the repo, there's a script that asserts it works.
