# CI/CD POC: Design

GitHub Actions → GHCR → Harbor → Argo CD, with a small Python + PostgreSQL workload as the carrier. The proof is the deployment chain; the workload is deliberately small.

This is the *why* document. The executable runbook lives in [PLAN.md](PLAN.md).

---

## 1. The question this POC answers

> Can a small Kubernetes workload move from local development to a Hetzner cluster through a realistic CI/CD path, while using Helm, GitHub Actions, GHCR, Harbor, Terraform, Argo CD, and OpenBao in their intended roles?

Most CI/CD demos show one slice — image build, or Argo CD sync — and skip the handoff between CI and CD. This POC builds the whole path end-to-end and is the artifact you can point at when someone asks "how do we ship a service into our cluster."

---

## 2. Scope

### In scope (the POC must prove)

- A Python app passes tests locally before any container or cluster work.
- The app connects to PostgreSQL with `sslmode=verify-full` (TLS, CA verification, hostname verification).
- The same config-and-secret contract works locally, in CI, and in Hetzner.
- The Helm chart can be linted, templated, installed, upgraded, rolled back, and smoke-tested locally.
- GitHub Actions runs the same checks on every pull request.
- Trusted `main` builds publish to GHCR with an immutable digest.
- Harbor in Hetzner makes the GHCR image available to the Hetzner cluster (proxy cache first, replication later).
- A Git change to a Helm value promotes a specific image digest.
- Argo CD reconciles that digest into the cluster.
- Rolling forward and rolling back are both Git operations.
- The database password lives in OpenBao and is reconciled into Kubernetes by External Secrets Operator. Git holds only the reference.

### Out of scope

| Concern | Where it belongs |
|---|---|
| App complexity | A real product, not a deployment-chain POC |
| Database migrations | A separate migrations POC (see `migrations/` lab) |
| HA Postgres | The `patroni-pg/` lab |
| Secret rotation policy | A follow-up on top of this POC once OpenBao is wired |
| Observability stack | The `grafana-lgtm/` lab |
| Multi-service orchestration | A platform-level POC |
| Multi-region or multi-cluster | A platform-level POC |

The POC includes only enough PostgreSQL behavior to prove secure application configuration. The app does not manage schema in this POC.

---

## 3. Architecture

```text
LOCAL CONFIDENCE
┌──────────────────────────────────────────────────────┐
│ Developer laptop                                     │
│   pytest                                             │
│   docker compose up postgres (TLS)                   │
│   docker build                                       │
│   helm upgrade --install (Rancher Desktop)           │
│              │                                       │
│              ▼                                       │
│       Python app Pod ── ConfigMap + Secret + CA      │
│              │                                       │
│              ▼  sslmode=verify-full                  │
│       Local PostgreSQL                               │
└──────────────────────────────────────────────────────┘

CI ARTIFACT
┌──────────────────────────────────────────────────────┐
│ GitHub Actions                                       │
│   reproduces local checks                            │
│   builds image                                       │
│   pushes trusted main builds                         │
│              │                                       │
│              ▼                                       │
│       GHCR (immutable digest)                        │
│              │                                       │
│              │ proxy cache, then replication         │
│              ▼                                       │
│       Harbor (Hetzner)                               │
└──────────────────────────────────────────────────────┘

CD / GITOPS
┌──────────────────────────────────────────────────────┐
│ Git repository                                       │
│   Helm chart + values + image digest                 │
│              │ watched by                            │
│              ▼                                       │
│       Argo CD                                        │
│              │ reconciles                            │
│              ▼                                       │
│ Hetzner Kubernetes                                   │
│   Python app Pod                                     │
│              │  ConfigMap + ExternalSecret + CA      │
│              │  image pulled from Harbor by digest   │
│              ▼  sslmode=verify-full                  │
│       PostgreSQL endpoint                            │
│                                                      │
│       OpenBao ──► ESO ──► Secret/cicd-demo-db        │
└──────────────────────────────────────────────────────┘
```

---

## 4. Boundaries: who owns what

| Concern | Owner | Why this owner |
|---|---|---|
| Build confidence | GitHub Actions | Runs on every change; same checks on PR and `main` |
| Immutable artifact | GHCR | GitHub-native auth, repository-scoped, no extra infra |
| Cluster registry boundary | Harbor (Hetzner) | Local to the cluster; enforces retention, scanning, auth, audit |
| Deployment intent | Git | Reviewable, revertable, auditable |
| Cluster reconciliation | Argo CD | Watches Git; makes cluster match desired state |
| Non-secret config | Helm values → ConfigMap | Same shape locally, in CI, in Hetzner |
| Secret values (later) | OpenBao + ESO | Git holds the reference; OpenBao holds the value |
| Trust material (CA bundle) | Read-only volume | Pod can verify Postgres identity |

The most important boundary: **Git is the deployment source of truth, not "whatever CI just built."** That separation is what makes promotion, rollback, and audit clean.

---

## 5. The three artifact paths

The architecture has three deliberate, independent flows. Each can be tested in isolation, which is what makes the POC useful when something breaks.

### 5.1 Image artifact path

```
source code → CI build → GHCR (digest) → Harbor (cached/replicated) → cluster pulls by digest
```

Image identity is the SHA256 digest. Tags are mutable labels for humans; digests are the deployable contract.

### 5.2 Deployment intent path

```
PR → review → merge → Git records (chart + digest + values) → Argo CD reads Git
```

Argo CD does not call CI. CI does not call the cluster. Git is the only thing both touch.

### 5.3 Configuration path

```
Non-secret:  Helm values  → ConfigMap → env vars in Pod
Secret:      OpenBao      → ESO       → Secret    → env var or file in Pod
Trust:       generated CA → ConfigMap → read-only volume in Pod
```

The Helm chart references Secrets and ConfigMaps **by name**, never by value. The chart is identical across environments; only the values change.

---

## 6. Design decisions

Each decision states the choice, the reason, what was considered instead, and the implications.

### D1: Boring Python app

**Decision.** A single-file Python web app exposing `/healthz`, `/readyz`, `/version`, and `/db-healthz`.

**Why.** The deployment chain is the unit under test. The app needs deterministic tests, fast startup, and clear verification output. A complex app would obscure the CI/CD behavior the POC is trying to prove.

**Considered.** Go (smaller image, but the rest of this lab uses Python). A Hello World container with no DB (would not exercise the secret path).

**Implications.** Python image is bigger than a static binary; this is acceptable because we are not optimizing image size in this POC.

---

### D2: Separate config from secrets

**Decision.** Non-secret config travels through Helm values → ConfigMap → env vars. The database password travels through a separate Kubernetes Secret (manual at first, then ESO from OpenBao).

**Why.** ConfigMaps are for non-confidential key-value data; Secrets are for confidential values. Mixing them puts non-secret config behind unnecessary access controls or leaks secrets through configuration tools.

**Considered.** A single Secret containing everything (loses the distinction; harder to debug). A full database URL with embedded password (couples the secret to the connection string).

**Implications.** The chart references the Secret by name and the ConfigMap by name. Values files contain only references. Deleting either resource fails the Pod; this is intentional.

---

### D3: PostgreSQL with `sslmode=verify-full`, not `require`

**Decision.** Connect with `sslmode=verify-full` and `sslrootcert=/etc/postgres-ca/ca.crt` everywhere, including locally.

**Why.** `require` encrypts the channel but does not verify the server's identity. `verify-full` verifies the certificate chains to the trusted CA *and* that the requested hostname matches the server certificate. The POC should prove the app connects to the *intended* Postgres endpoint, not merely to "something that accepts TLS."

**Considered.** `require` (faster local setup, but does not exercise the trust path). `verify-ca` (verifies CA but not hostname; weaker than `verify-full`).

**Implications.** The local Postgres certificate must include every hostname used in the test paths (`localhost`, `host.docker.internal`, `host.rancher-desktop.internal`, `postgres`). A missing SAN entry causes verification to fail — and that failure is useful evidence the test is doing real verification.

---

### D4: Helm everywhere

**Decision.** The same Helm chart installs into Rancher Desktop and into Hetzner. Only the values file changes.

**Why.** Helm is the packaging boundary. If local Kubernetes uses raw YAML and Hetzner uses Helm, local testing does not exercise the real deployment artifact, and bugs hide in the gap.

**Considered.** Kustomize (less expressive for value injection in this case). Raw manifests rendered by a script (would diverge from Argo CD's Helm rendering).

**Implications.** Both `values-local.yaml` and `values-hetzner.yaml` exist. The chart must work with both.

---

### D5: Push to GHCR first, Harbor for cluster pulls

**Decision.** GitHub Actions publishes to GHCR. Harbor in Hetzner makes that image available to the cluster (proxy cache first, replication later).

**Why.** GHCR has GitHub-native auth and zero extra infrastructure for CI. Harbor is the cluster-side boundary: a local registry close to the cluster, with retention, scanning, and audit.

**Considered.** Push directly to Harbor from CI (couples CI to Hetzner connectivity; complicates auth). Skip Harbor (loses the cluster-side boundary).

**Implications.** Two registry hops for an image; this is intentional. The image path becomes `harbor.example.com/<proxy-project>/<owner>/<repo>/cicd-demo@sha256:...`.

---

### D6: Deploy by digest, not tag

**Decision.** The chart renders images by digest in Hetzner values. Tags are accepted only in local values for ergonomic reasons.

**Why.** Tags are mutable labels; digests are content-addressed. Digest pinning proves the cluster runs the exact image CI built, even if a tag is later moved or deleted.

**Considered.** Always use tags (loses immutability). Digest only, no tags (annoying for local dev).

**Implications.** When `image.digest` is set, the chart produces `<repo>@sha256:...`. Promotion is a Git change to that digest, not a tag move.

---

### D7: Harbor proxy cache before replication

**Decision.** First make the cluster pull through Harbor as a proxy cache for GHCR. Add replication only after that works end-to-end.

**Why.** The POC isolates problems. Proxy cache is the simplest way to prove the cluster can pull through Harbor. Replication is a stronger production model (retention, scanning, decoupling from GHCR availability) but adds complexity that should not gate the rest of the path.

**Considered.** Replication only (more invasive change to land first). Both at once (harder to debug).

**Implications.** Phase order matters: prove pull-through, then add replication.

---

### D8: GitOps deploys; CI does not run `helm upgrade`

**Decision.** CI never runs `helm upgrade` against Hetzner. Promotion is a Git change. Argo CD reconciles.

**Why.** This makes deployment reviewable, reversible, and decoupled from CI runtime state. Rollback is a Git revert, not a manually reconstructed CI job.

**Considered.** CI-driven `helm upgrade` (faster feedback for first deploys; loses audit trail and rollback ergonomics).

**Implications.** Argo CD owns the Helm rendering and the cluster reconciliation. There is no `helm release` Secret in the target namespace owned by CI.

---

### D9: Secrets — manual bootstrap first, OpenBao + ESO later

**Decision.** First Hetzner pass uses a namespace-scoped Kubernetes Secret created out-of-band. Once the full GitOps path works, swap to External Secrets Operator backed by OpenBao (the sibling `openbao/` lab in this repo).

**Why.** Land the registry → Argo CD → app path with the simplest possible secret story. Then add OpenBao without touching the chart, because the chart already references the Secret by name; ESO writes that same Secret from an `ExternalSecret`.

**Considered.** ESO + OpenBao from day one (more moving parts before the core path is proven). Sealed Secrets (Git holds encrypted blobs; rotation is awkward; weaker than a true secret manager).

**Implications.** The chart never changes between the two phases. Only the source of `Secret/cicd-demo-db` changes — from `kubectl create secret generic` to an `ExternalSecret` reconciled by ESO from OpenBao. Rotation moves from "edit the Secret manually" to "write the new value into OpenBao."

---

### D10: POC-local layout, workflows at repo root

**Decision.** All POC code lives under `github-harbor-argocd-cicd-poc/`, except GitHub Actions workflow files, which must live at the repo root under `.github/workflows/`. Workflows use `paths:` filters and `working-directory:` defaults so they only run for this POC.

**Why.** GitHub Actions discovers workflows only at the repository root. Path filters keep this POC's CI from firing on unrelated changes elsewhere in the lab.

**Considered.** Per-POC workflow runners that watch this directory and dispatch (overcomplicated for a POC).

**Implications.** Two locations to keep mental track of: POC code in this directory, workflows at the root.

---

## 7. The CI/CD contract

Each transition is testable independently. That is what makes the POC useful when something breaks.

| Stage | Owner | Input | Output |
|---|---|---|---|
| Local test | Developer | Source code | Passing tests |
| Local dependency | Developer | Docker Compose + generated TLS material | Postgres reachable with `verify-full` |
| Local config/secrets | Developer | Ignored env files + generated CA + local password | Config contract validated, no committed secrets |
| Local package | Developer | Source code + config contract | Local image |
| Local deploy | Developer | Helm chart + local image + Secret + CA ConfigMap | App in Rancher Desktop with DB connectivity |
| CI verify | GitHub Actions | Pull request | Pass/fail signal |
| CI publish | GitHub Actions | Merged commit | GHCR image digest |
| Hetzner platform | Terraform | Cloud credentials | Cluster, Harbor, Argo CD, ESO, OpenBao |
| Secret bootstrap | Platform operator → OpenBao | DB password + Postgres CA bundle | Namespace `Secret` (manual) → `ExternalSecret` (OpenBao) |
| Registry promotion | Harbor | GHCR image | Harbor-available image |
| Deployment promotion | Git | Image digest | Updated Helm values |
| Reconciliation | Argo CD | Git desired state + secret contract | App in Hetzner with DB connectivity |

---

## 8. The configuration contract

The app reads a small, explicit set of inputs.

| Setting | Secret? | Source | Example |
|---|---:|---|---|
| `APP_ENV` | No | Helm values → ConfigMap | `local`, `hetzner` |
| `DB_HOST` | No | Helm values → ConfigMap | `host.rancher-desktop.internal`, `postgres.example.internal` |
| `DB_PORT` | No | Helm values → ConfigMap | `5432` |
| `DB_NAME` | No | Helm values → ConfigMap | `cicd_demo` |
| `DB_USER` | No (usually) | Helm values → ConfigMap | `cicd_demo_app` |
| `DB_SSLMODE` | No | Helm values → ConfigMap | `verify-full` |
| `DB_SSLROOTCERT` | No | Helm values → ConfigMap | `/etc/postgres-ca/ca.crt` |
| `DB_PASSWORD` | Yes | Kubernetes Secret (manual → ESO/OpenBao) | not committed |
| Postgres CA bundle | No | ConfigMap mounted as file | `ca.crt` |

The chart never embeds real password values. Values files reference Secrets and ConfigMaps **by name**:

```yaml
database:
  host: postgres.example.internal
  port: 5432
  name: cicd_demo
  user: cicd_demo_app
  sslMode: verify-full
  sslRootCert: /etc/postgres-ca/ca.crt
  existingSecret:
    name: cicd-demo-db
    passwordKey: password
  caBundle:
    configMapName: cicd-demo-postgres-ca
    key: ca.crt
```

The Pod must fail fast if the Secret or CA bundle is missing.

---

## 9. Folder shape

```
github-harbor-argocd-cicd-poc/
  DESIGN.md
  PLAN.md
  Makefile
  docker-compose.yml
  app/
    Dockerfile
    main.py
    requirements.txt
    tests/
  helm/
    cicd-demo/
      Chart.yaml
      values.yaml
      values-local.yaml
      values-hetzner.yaml
      templates/
  argocd/
    application.yaml
    externalsecret.yaml
  postgres/
    README.md
    init/
  terraform/
    versions.tf
    providers.tf
    variables.tf
    main.tf
    outputs.tf
    terraform.tfvars.example
  scripts/
    NN-*.sh    # numbered to match PLAN.md phases
  generated/
    # gitignored: local CA, Postgres certs, env files, passwords, rendered values

repo-root/
  .github/
    workflows/
      cicd-demo-ci.yaml          # PRs: tests, build, helm checks
      cicd-demo-publish.yaml     # main: build + push to GHCR
      cicd-demo-promote.yaml     # promote a digest into Hetzner values
```

The first implementation pass should not create all of this at once. The folder shape is the target map; PLAN.md defines the build order.

---

## 10. Open questions and conservative first-pass resolutions

| Question | Conservative first pass |
|---|---|
| Harbor proxy cache, replication, or both? | Proxy cache first; replication later. |
| Helm chart from Git or from an OCI registry? | Argo CD reads the chart directly from Git. |
| Image promotion: automatic on `main`, or manual? | Manual via a promotion workflow first. |
| Argo CD: auto-sync or manual? | Manual sync first; auto-sync after rollback is proven. |
| Terraform installs Harbor and Argo CD, or only prerequisites? | Terraform for infrastructure and bootstrap prerequisites; Helm for app and platform packages where that matches upstream installation patterns. |
| Existing Hetzner cluster, or Terraform-created? | Use whichever the user already has; the POC must work with either. |
| Manual K8s Secret first, or ESO+OpenBao immediately? | Manual Secret for the first Hetzner pass; switch to ESO+OpenBao in PLAN Phase 18, after the registry and Argo CD path already works. |
| Where does Hetzner PostgreSQL come from? | Existing endpoint is fine if DNS name, CA bundle, username, and password are provided through the documented contract. |
| What DNS name for Postgres, and does the cert cover it? | The chart's `database.host` must match a SAN on the Postgres server certificate. Mismatch is a deliberate failure mode for `verify-full`. |

---

## 11. The shape of "done"

The POC is done when a clean run can demonstrate:

1. Local tests pass.
2. Local Postgres comes up with TLS.
3. Local app connects with `verify-full`.
4. Local image builds and runs.
5. Helm install in Rancher Desktop succeeds; `/healthz` and `/db-healthz` pass.
6. PR triggers CI; all checks pass without publishing.
7. Merge to `main` publishes an image to GHCR with a digest.
8. Harbor in Hetzner can pull (or has replicated) that image.
9. Hetzner namespace has the bootstrapped Secret and CA bundle.
10. A Git change to the digest is promoted by Argo CD.
11. Hetzner `/healthz` and `/db-healthz` pass.
12. The DB password moves from the manually bootstrapped Secret into OpenBao via ESO, with no chart change.
13. Rolling back is a Git revert; Argo CD restores the previous healthy state.

The runbook checklist version of this lives in PLAN.md.

---

## 12. References

These external constraints shape the design.

- [GitHub Actions workflows](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows) — must live in `.github/workflows` at the repo root.
- [Publishing Docker images to GHCR](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images) — `GITHUB_TOKEN` is enough for repository-scoped publishes.
- [Container registry digest pulls](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) — `image@sha256:...` form.
- [Pull-request workflow restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows) — fork PRs cannot use repository secrets; never use `pull_request_target` to build untrusted PR code.
- [GitHub Actions secrets](https://docs.github.com/en/actions/security-for-github-actions/security-guides/about-secrets) — pass explicitly into jobs; do not echo transformed values.
- [Harbor proxy cache](https://goharbor.io/docs/main/administration/configure-proxy-cache/) — supports GHCR; pulls go through `<harbor>/<proxy-project>/<upstream-path>`.
- [Harbor replication endpoints](https://goharbor.io/docs/main/administration/configuring-replication/create-replication-endpoints/) — supports GHCR as a non-Harbor endpoint.
- [Kubernetes private registry pulls](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/) — `imagePullSecrets` of type `kubernetes.io/dockerconfigjson`.
- [Kubernetes ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) and [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) — non-confidential vs confidential.
- [Kubernetes Secret good practices](https://kubernetes.io/docs/concepts/security/secrets-good-practices/) — encryption at rest, RBAC, restricted access, external secret stores.
- [Kubernetes Secret injection](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/) — env vars or read-only volumes.
- [PostgreSQL libpq parameters](https://www.postgresql.org/docs/current/libpq-connect.html) — `sslmode=verify-full`, `sslrootcert`.
- [PostgreSQL SSL](https://www.postgresql.org/docs/current/libpq-ssl.html) — recommends `verify-ca` or `verify-full` when validation is required.
- [External Secrets Operator](https://external-secrets.io/latest/api/externalsecret/) — reconciles external secret values into Kubernetes Secrets.
- [Argo CD Helm support](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/) — Argo CD renders Helm charts and reconciles the result.
- [Terraform `plan` vs `apply`](https://developer.hashicorp.com/terraform/cli/commands/plan) — `plan` previews; `apply` changes infrastructure.
- OpenBao — Vault-compatible open-source secret manager. See the sibling `openbao/` lab for a working local instance.
