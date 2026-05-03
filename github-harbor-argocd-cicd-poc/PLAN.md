# CI/CD POC: Execution Plan

This is the *how* document. The *why* lives in [DESIGN.md](DESIGN.md).

---

## How to use this plan

This plan is written so an LLM agent (or a careful human) can execute it phase by phase. Each phase is self-contained: if the previous phase's **Verification** passes, you can start the next phase without re-reading earlier phases.

**Operating rules:**

1. Run phases in order. Do not skip ahead.
2. Before starting phase N, run the **Verification** from phase N-1 again. If it does not pass, do not proceed — return to phase N-1.
3. If a verification command fails, follow the **On failure** block. Do not bypass safety checks (no `--insecure`, no `--no-verify`, no `--insecure-skip-tls-verify`) to make a check pass.
4. Do not commit anything in `generated/`. That directory is gitignored and contains development credentials, certs, and rendered values.
5. When a step says "create file X with content Y," use the literal content shown. When a step provides a skeleton, fill in the obvious blanks (imports, types, error handling) but keep the named functions, endpoints, and config keys exactly as specified.
6. When a phase lands in a partially complete state (a step ran but verification failed), prefer fixing forward. Do not delete generated state to "start clean" unless the **On failure** block says to.

**Conventions:**

- Working directory: `github-harbor-argocd-cicd-poc/` unless stated otherwise.
- Python: 3.12.
- Container base image: `python:3.12-slim`.
- Web framework: FastAPI; ASGI server: uvicorn.
- DB driver: `psycopg` (psycopg3).
- Local Kubernetes: Rancher Desktop.
- Generated outputs: `generated/` (gitignored).
- Numbered scripts in `scripts/` mirror phase numbers (`01-...`, `02-...`).
- All Helm releases are namespaced; default namespace is `cicd-demo`.

---

## Phase 0: Plan-only baseline (current state)

**Goal.** Confirm the POC directory holds only design and plan documents.

**Verification.**
```bash
ls github-harbor-argocd-cicd-poc/
# expect: DESIGN.md, PLAN.md (and nothing else, or only those two plus a .gitignore)
```

**Postconditions.** Repository contains design and plan; no application code yet.

---

## Phase 1: Minimal Python app

**Goal.** A Python web app passes local tests and responds on `/healthz`, `/readyz`, and `/version`.

**Preconditions.**
- Phase 0 verification passes.
- Python 3.12 is installed and `python3 --version` reports `3.12.x`.

**Files to create.**

1. `.gitignore` — at minimum:
```gitignore
__pycache__/
*.pyc
.venv/
.pytest_cache/
generated/
*.env
```

2. `app/requirements.txt`:
```
fastapi>=0.110,<1
uvicorn[standard]>=0.30,<1
pytest>=8,<9
httpx>=0.27,<1
```

3. `app/main.py` — a FastAPI app exposing:
   - `GET /healthz` → `{"status": "ok"}` (200)
   - `GET /readyz` → `{"status": "ready"}` (200) once startup is complete
   - `GET /version` → `{"git_sha": <env GIT_SHA or "dev">, "image_tag": <env IMAGE_TAG or "dev">, "image_digest": <env IMAGE_DIGEST or "">}` (200)
   - The app reads config from environment variables only. No DB connection in this phase.

4. `app/tests/test_health.py` — pytest tests for the three endpoints, using FastAPI's `TestClient`.

5. `Makefile` with targets:
```makefile
.PHONY: venv install test run clean

venv:
	python3 -m venv .venv

install: venv
	.venv/bin/pip install -r app/requirements.txt

test:
	.venv/bin/python -m pytest app/tests -v

run:
	.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8080

clean:
	rm -rf .venv .pytest_cache app/__pycache__ app/tests/__pycache__
```

**Steps.**
```bash
cd github-harbor-argocd-cicd-poc
make install
make test
```

**Verification.**
```bash
make test
# expect: pytest reports 3 passed (or more), exit 0

# in a second shell:
make run &
RUN_PID=$!
sleep 2
curl -fsS http://localhost:8080/healthz | grep -q '"status":"ok"' && echo OK
curl -fsS http://localhost:8080/readyz | grep -q '"status":"ready"' && echo OK
curl -fsS http://localhost:8080/version | grep -q '"git_sha"' && echo OK
kill $RUN_PID
```
All three `echo OK` lines must print.

**Postconditions.** App runs locally; tests pass; nothing depends on a database yet.

**On failure.**
- Tests fail with import errors → confirm `make install` succeeded; check `.venv/bin/python -c "import fastapi"`.
- Port 8080 already in use → kill the conflicting process; do not change the port (downstream phases assume 8080).

---

## Phase 2: Local PostgreSQL with TLS

**Goal.** A local PostgreSQL instance runs in Docker Compose with TLS, and the app's new `/db-healthz` endpoint connects with `sslmode=verify-full`.

**Preconditions.** Phase 1 verification passes.

**Files to create.**

1. `scripts/00-generate-postgres-tls.sh` — generates a local CA and Postgres server certificate into `generated/postgres/`. The certificate's Subject Alternative Names must include:
   - `localhost`
   - `127.0.0.1` (as IP SAN)
   - `host.docker.internal`
   - `host.rancher-desktop.internal`
   - `postgres` (the Compose service name)

   Use `openssl` (or `cfssl`). Output files:
   - `generated/postgres/ca.crt`, `generated/postgres/ca.key`
   - `generated/postgres/server.crt`, `generated/postgres/server.key`

2. `docker-compose.yml`:
```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: cicd_demo
      POSTGRES_USER: cicd_demo_app
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    command:
      - "postgres"
      - "-c"
      - "ssl=on"
      - "-c"
      - "ssl_cert_file=/etc/postgres-tls/server.crt"
      - "-c"
      - "ssl_key_file=/etc/postgres-tls/server.key"
      - "-c"
      - "ssl_ca_file=/etc/postgres-tls/ca.crt"
    volumes:
      - ./generated/postgres:/etc/postgres-tls:ro
    ports:
      - "5432:5432"

secrets:
  db_password:
    file: ./generated/db-password.txt
```

3. `scripts/01-start-postgres-local.sh` — generates `generated/db-password.txt` if missing (with `openssl rand -base64 24`), then runs `docker compose up -d postgres` and waits for readiness.

4. Add `psycopg[binary]>=3.2,<4` to `app/requirements.txt`.

5. Extend `app/main.py` with `GET /db-healthz`:
   - Reads `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_SSLMODE`, `DB_SSLROOTCERT` from env.
   - Reads `DB_PASSWORD` from env.
   - Connects with `psycopg.connect(...)` using those parameters.
   - Runs `SELECT 1` and returns `{"status": "ok"}` (200) or `{"status": "error", "detail": "<short msg>"}` (503).

6. `app/tests/test_db_healthz.py` — a test that requires Postgres running. Skip if `DB_HOST` is not set in the environment; otherwise call `/db-healthz` and assert 200.

**Steps.**
```bash
bash scripts/00-generate-postgres-tls.sh
bash scripts/01-start-postgres-local.sh
make install   # picks up psycopg
```

**Verification.**
```bash
docker compose ps postgres | grep -q "Up" && echo OK

export DB_HOST=localhost
export DB_PORT=5432
export DB_NAME=cicd_demo
export DB_USER=cicd_demo_app
export DB_SSLMODE=verify-full
export DB_SSLROOTCERT="$PWD/generated/postgres/ca.crt"
export DB_PASSWORD="$(cat generated/db-password.txt)"

make run &
RUN_PID=$!
sleep 2
curl -fsS http://localhost:8080/db-healthz | grep -q '"status":"ok"' && echo OK
kill $RUN_PID

make test
# expect: db_healthz test passes (not skipped)
```

**Postconditions.** Postgres is up, TLS is enforced, `/db-healthz` returns ok with `verify-full`.

**On failure.**
- TLS handshake fails with "hostname does not match" → the server cert is missing the SAN you connected to. Edit Phase 2 cert script; regenerate; restart Compose.
- "self-signed certificate" → `DB_SSLROOTCERT` does not point at the right CA file. Verify the path.
- Connection refused → Postgres did not start. `docker compose logs postgres`.
- Do **not** drop to `sslmode=require` to make this pass.

---

## Phase 3: Config and secrets contract

**Goal.** The app loads config and secrets from a documented contract; tests prove startup fails fast on missing required values.

**Preconditions.** Phase 2 verification passes.

**Files to create / modify.**

1. `app/config.py` — a `Settings` class (Pydantic Settings or plain dataclass) with:
   - Required: `APP_ENV`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_SSLMODE`, `DB_SSLROOTCERT`, `DB_PASSWORD`.
   - Loader raises a clear error if any required value is missing.
   - `DB_PASSWORD` must come from an env var only — there is no `.from_url()` shortcut and no default.

2. `app/main.py` — refactor `/db-healthz` and `/version` to use `Settings`. App startup calls `Settings.load()`; failure exits with code 1 and a single-line error.

3. `app/tests/test_config.py` — tests:
   - All required vars present → `Settings.load()` returns object with those values.
   - Missing `DB_PASSWORD` → `Settings.load()` raises with a message containing `DB_PASSWORD`.
   - `DB_SSLMODE=verify-full` is enforced (not silently changed).

4. `generated/local.env.example` (committed as `local.env.example`, not under `generated/`):
```
APP_ENV=local
DB_HOST=localhost
DB_PORT=5432
DB_NAME=cicd_demo
DB_USER=cicd_demo_app
DB_SSLMODE=verify-full
DB_SSLROOTCERT=./generated/postgres/ca.crt
```

5. `scripts/02-write-local-env.sh` — writes `generated/local.env` (non-secret) and `generated/db.secret.env` (containing only `DB_PASSWORD`) by reading `local.env.example` and `generated/db-password.txt`.

**Verification.**
```bash
make test
# expect: config tests pass

bash scripts/02-write-local-env.sh
test -f generated/local.env && echo OK
test -f generated/db.secret.env && echo OK
grep -q '^DB_PASSWORD=' generated/db.secret.env && echo OK
grep -q '^DB_PASSWORD=' generated/local.env && echo "FAIL: password leaked into non-secret env" || echo OK
```

**Postconditions.** Config loader is the single source of truth for app inputs. Non-secret config and secret values live in separate files locally.

**On failure.**
- Tests pass when they should fail (missing var case) → the loader is too lenient. Make required fields explicitly required.

---

## Phase 4: Container image with the same contract

**Goal.** A locally built container image runs the app, connects to Postgres with the same `verify-full` contract, and passes the same smoke tests as the local Python process.

**Preconditions.** Phase 3 verification passes.

**Files to create.**

1. `app/Dockerfile`:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ .
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```
   - Note: the build context will be the POC root; adjust `COPY` paths if you change context.

2. `scripts/03-build-image-local.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
docker build -t cicd-demo:local -f app/Dockerfile .
```

3. `scripts/04-run-image-local.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
docker run --rm -p 8080:8080 \
  --env-file generated/local.env \
  --env-file generated/db.secret.env \
  -e DB_HOST=host.docker.internal \
  -e DB_SSLROOTCERT=/etc/postgres-ca/ca.crt \
  -v "$PWD/generated/postgres/ca.crt:/etc/postgres-ca/ca.crt:ro" \
  cicd-demo:local
```
   - The hostname override is required because `localhost` inside a container is the container, not the host. The Postgres cert must include `host.docker.internal` (Phase 2).

**Verification.**
```bash
bash scripts/03-build-image-local.sh
docker images cicd-demo:local | grep -q cicd-demo && echo OK

bash scripts/04-run-image-local.sh &
RUN_PID=$!
sleep 3
curl -fsS http://localhost:8080/healthz | grep -q '"status":"ok"' && echo OK
curl -fsS http://localhost:8080/db-healthz | grep -q '"status":"ok"' && echo OK
curl -fsS http://localhost:8080/version | grep -q '"image_tag"' && echo OK
kill $RUN_PID || true
```

**Postconditions.** The image contains everything the app needs; Postgres connectivity from inside the container is proven.

**On failure.**
- DB connect fails with "hostname does not match" → the cert is missing `host.docker.internal`. Fix Phase 2 certs.
- DB connect fails with "could not translate host name" → DNS for `host.docker.internal` is not configured (uncommon on Rancher Desktop). Use `host.rancher-desktop.internal` and add it to the cert.

---

## Phase 5: Helm chart with local install

**Goal.** A Helm chart installs the app into Rancher Desktop, with config and secret references and a CA bundle mounted at the documented path.

**Preconditions.** Phase 4 verification passes. Rancher Desktop Kubernetes is enabled (`kubectl get nodes` returns at least one Ready node).

**Files to create.** Under `helm/cicd-demo/`:

1. `Chart.yaml` — name `cicd-demo`, version `0.1.0`, appVersion matches the image tag.

2. `values.yaml` — base values (image repo and tag, port, resources, probes for `/healthz` and `/readyz`).

3. `values-local.yaml`:
```yaml
image:
  repository: cicd-demo
  tag: local
  pullPolicy: IfNotPresent
appEnv: local
database:
  host: host.rancher-desktop.internal
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

4. `templates/configmap.yaml` — non-secret env keys from `database` (excluding password).

5. `templates/deployment.yaml`:
   - Pod env: ConfigMap-backed for non-secret keys; Secret-backed for `DB_PASSWORD` from `database.existingSecret`.
   - Volume: `database.caBundle.configMapName` mounted read-only at the directory of `database.sslRootCert`.
   - Probes: `httpGet /healthz` (liveness), `httpGet /readyz` (readiness).
   - `imagePullPolicy: {{ .Values.image.pullPolicy }}`.
   - Image rendering: if `image.digest` is set, use `repository@digest`; otherwise `repository:tag`.

6. `templates/service.yaml` — ClusterIP service on port 80 → 8080.

7. `scripts/05-create-local-k8s-resources.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
kubectl create namespace cicd-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic cicd-demo-db \
  -n cicd-demo \
  --from-file=password=generated/db-password.txt \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap cicd-demo-postgres-ca \
  -n cicd-demo \
  --from-file=ca.crt=generated/postgres/ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
```

8. `scripts/06-helm-install-local.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
helm lint helm/cicd-demo
helm template cicd-demo helm/cicd-demo -f helm/cicd-demo/values-local.yaml > generated/rendered-local.yaml
helm upgrade --install cicd-demo helm/cicd-demo \
  -n cicd-demo \
  -f helm/cicd-demo/values-local.yaml \
  --wait --timeout 2m
```

**Verification.**
```bash
bash scripts/05-create-local-k8s-resources.sh
bash scripts/06-helm-install-local.sh

kubectl -n cicd-demo rollout status deploy/cicd-demo --timeout=2m
kubectl -n cicd-demo port-forward svc/cicd-demo 8080:80 &
PF_PID=$!
sleep 2
curl -fsS http://localhost:8080/healthz | grep -q '"status":"ok"' && echo OK
curl -fsS http://localhost:8080/db-healthz | grep -q '"status":"ok"' && echo OK
kill $PF_PID
```

**Postconditions.** App runs in Rancher Desktop; ConfigMap, Secret, and CA bundle are all live; DB connectivity works through Helm-managed plumbing.

**On failure.**
- Pod `CreateContainerConfigError` → missing Secret or ConfigMap. Re-run script 05.
- DB connect fails inside the cluster → confirm `host.rancher-desktop.internal` resolves from the Pod and is on the cert SAN list.
- `helm lint` fails → fix the chart before installing.

---

## Phase 6: Local upgrade and rollback

**Goal.** A non-trivial change can be released with `helm upgrade` and rolled back with `helm rollback`, with `/db-healthz` healthy throughout.

**Preconditions.** Phase 5 verification passes.

**Steps.**

1. Make a small visible change — for example, set `replicaCount: 2` in `values-local.yaml`, or change `appEnv: local` to `appEnv: local-upgraded` and reflect that in the `/version` response.

2. Upgrade and verify:
```bash
helm upgrade cicd-demo helm/cicd-demo -n cicd-demo -f helm/cicd-demo/values-local.yaml --wait --timeout 2m
kubectl -n cicd-demo rollout status deploy/cicd-demo --timeout=2m
# port-forward and curl /healthz, /db-healthz, /version — all 200
```

3. Roll back:
```bash
helm history cicd-demo -n cicd-demo
helm rollback cicd-demo 1 -n cicd-demo --wait --timeout 2m
# port-forward and curl /healthz, /db-healthz, /version — /version reflects the previous value
```

**Verification.**
- `helm history cicd-demo -n cicd-demo` shows revisions 1 (install), 2 (upgrade), 3 (rollback).
- `/version` after rollback matches revision 1.
- `/db-healthz` is 200 throughout.

**Postconditions.** Chart preserves Secret references and CA mount across upgrade and rollback.

**On failure.**
- Pod restarts with `CrashLoopBackOff` after upgrade → the change broke startup. `kubectl logs` and fix the chart, then retry. Do not rollback to hide the bug.

---

## Phase 7: GitHub Actions PR workflow (no publishing)

**Goal.** A repo-root GitHub Actions workflow runs the same tests, container smoke test, and Helm checks on pull requests, without registry write permissions.

**Preconditions.** Phase 6 verification passes. Repository is on GitHub.

**Files to create.** At the **repo root** (not inside the POC directory):

1. `.github/workflows/cicd-demo-ci.yaml`:
```yaml
name: cicd-demo CI
on:
  pull_request:
    paths:
      - 'github-harbor-argocd-cicd-poc/**'
      - '.github/workflows/cicd-demo-ci.yaml'
permissions:
  contents: read
defaults:
  run:
    working-directory: github-harbor-argocd-cicd-poc
jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_DB: cicd_demo
          POSTGRES_USER: cicd_demo_app
          POSTGRES_PASSWORD: ci-ephemeral
        ports: ['5432:5432']
        options: >-
          --health-cmd "pg_isready -U cicd_demo_app -d cicd_demo"
          --health-interval 5s
          --health-retries 10
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - name: Install
        run: pip install -r app/requirements.txt
      - name: Test (without TLS)
        run: python -m pytest app/tests -v
        env:
          # CI uses sslmode=disable for the smoke test because services:postgres
          # does not enable TLS. The TLS contract is enforced in local + Hetzner.
          DB_HOST: localhost
          DB_PORT: 5432
          DB_NAME: cicd_demo
          DB_USER: cicd_demo_app
          DB_SSLMODE: disable
          DB_PASSWORD: ci-ephemeral
      - name: Build image
        run: docker build -t cicd-demo:ci -f app/Dockerfile .
      - name: Helm setup
        uses: azure/setup-helm@v4
      - name: Helm lint
        run: helm lint helm/cicd-demo
      - name: Helm template
        run: helm template cicd-demo helm/cicd-demo -f helm/cicd-demo/values-local.yaml > /tmp/rendered.yaml
```

   Note the `DB_SSLMODE: disable` exception. This is the one place in the POC where the TLS contract is relaxed — because configuring TLS for a GitHub Actions service container adds complexity without strengthening the proof. The TLS contract is fully exercised locally (Phase 2) and in Hetzner (Phase 15). Document this exception in `DESIGN.md` D3 if it bothers you (or upgrade the CI Postgres to TLS later as a stretch goal).

**Verification.**

Open a pull request that touches `github-harbor-argocd-cicd-poc/`. Confirm:
- The `cicd-demo CI` workflow runs.
- All steps pass.
- No image is pushed to GHCR (no publish step exists).

**Postconditions.** PRs get the same confidence checks as local development.

**On failure.**
- Workflow does not trigger → the `paths:` filter does not match the changed files. Verify the path expression.
- Postgres service container never becomes ready → the `options:` health-check timeout is too short.

---

## Phase 8: GitHub Actions publishing on `main`

**Goal.** Merging to `main` builds the image, pushes it to GHCR with the Git SHA tag, and captures the digest.

**Preconditions.** Phase 7 verification passes.

**Files to create.** At the **repo root**:

1. `.github/workflows/cicd-demo-publish.yaml`:
```yaml
name: cicd-demo publish
on:
  push:
    branches: [main]
    paths:
      - 'github-harbor-argocd-cicd-poc/**'
      - '.github/workflows/cicd-demo-publish.yaml'
permissions:
  contents: read
  packages: write
defaults:
  run:
    working-directory: github-harbor-argocd-cicd-poc
jobs:
  publish:
    runs-on: ubuntu-latest
    outputs:
      digest: ${{ steps.build.outputs.digest }}
      tag: ${{ steps.meta.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: meta
        run: |
          tag="${GITHUB_SHA::7}"
          echo "tag=$tag" >> "$GITHUB_OUTPUT"
          echo "image=ghcr.io/${{ github.repository }}/cicd-demo" >> "$GITHUB_OUTPUT"
      - id: build
        uses: docker/build-push-action@v6
        with:
          context: github-harbor-argocd-cicd-poc
          file: github-harbor-argocd-cicd-poc/app/Dockerfile
          push: true
          tags: |
            ghcr.io/${{ github.repository }}/cicd-demo:${{ steps.meta.outputs.tag }}
            ghcr.io/${{ github.repository }}/cicd-demo:main
      - name: Summary
        run: |
          echo "### Published" >> "$GITHUB_STEP_SUMMARY"
          echo "- tag: \`${{ steps.meta.outputs.tag }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- digest: \`${{ steps.build.outputs.digest }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- image: \`ghcr.io/${{ github.repository }}/cicd-demo@${{ steps.build.outputs.digest }}\`" >> "$GITHUB_STEP_SUMMARY"
```

**Verification.**

After merging to `main` (or running the workflow on a test branch via `workflow_dispatch`):
- Workflow run reports a digest in the summary.
- `ghcr.io/<owner>/<repo>/cicd-demo:<sha>` is visible in the GitHub Packages UI.
- A `docker pull ghcr.io/<owner>/<repo>/cicd-demo@sha256:<digest>` succeeds locally (after `docker login ghcr.io`).

**Postconditions.** GHCR holds an immutable artifact for every `main` build, addressable by digest.

**On failure.**
- `denied: permission_denied` on push → `permissions: packages: write` is missing or the package visibility is set to disallow this repo.
- Build context errors → confirm `context:` and `file:` paths are repo-relative (the `defaults.run.working-directory` does not affect `docker/build-push-action`'s `context`).

---

## Phase 9: Capture digest, render Hetzner values

**Goal.** A reproducible mechanism exists to take the digest from a successful publish and render the Hetzner values that Argo CD will consume.

**Preconditions.** Phase 8 verification passes.

**Files to create.**

1. `helm/cicd-demo/values-hetzner.yaml.template`:
```yaml
image:
  repository: harbor.example.com/cicd-demo-cache/{{ .Owner }}/{{ .Repo }}/cicd-demo
  digest: "{{ .Digest }}"
appEnv: hetzner
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
ingress:
  enabled: true
  host: cicd-demo.example.com
  tls:
    enabled: true
```
   (Adjust template syntax to whatever renderer you use — `envsubst`, `gomplate`, plain `sed`. The point is that the digest is the only value that changes per-promotion.)

2. `scripts/07-render-hetzner-values.sh` — reads the digest from a workflow output (or argument), substitutes into the template, writes `helm/cicd-demo/values-hetzner.yaml`. The actual write is a Git commit later, in Phase 16.

**Verification.**
```bash
DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
OWNER=test \
REPO=test \
bash scripts/07-render-hetzner-values.sh > /tmp/values.yaml
grep -q 'digest: "sha256:0000' /tmp/values.yaml && echo OK
```

**Postconditions.** Promotion mechanics are decoupled from the runtime cluster.

---

## Phase 10: Terraform — Hetzner platform baseline

**Goal.** Terraform provisions or configures the Hetzner-side platform: cluster access (kubeconfig), ingress controller, DNS/TLS prerequisites. No application deploy yet.

**Preconditions.** Phase 9 verification passes. Hetzner Cloud token (or Hetzner Robot credentials, depending on your setup) is available.

**Files to create.** Under `terraform/`:

1. `versions.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf` — standard Terraform layout.
2. `terraform.tfvars.example` — documents required variables; the real `.tfvars` is gitignored.

The exact resource set depends on whether you create a new Hetzner cluster, use an existing one, or run k3s on Hetzner VMs. The plan does **not** prescribe one path — it prescribes that this phase ends with:
- A `kubeconfig` written to `generated/kubeconfig` (gitignored).
- An ingress controller (e.g., ingress-nginx) installed via Terraform's Helm provider.
- A working `KUBECONFIG=generated/kubeconfig kubectl get nodes` command.

**Verification.**
```bash
cd terraform
terraform init
terraform plan -out tfplan
terraform apply tfplan
cd ..

KUBECONFIG=generated/kubeconfig kubectl get nodes
# expect: at least one Ready node

KUBECONFIG=generated/kubeconfig kubectl -n ingress-nginx get pods
# expect: ingress-nginx-controller Running
```

**Postconditions.** Hetzner cluster is reachable; cluster networking is in place. No application or registry yet.

**On failure.**
- `terraform apply` fails partway → use `terraform state list` and `terraform plan` to see what landed; do not run `terraform destroy` unless you accept losing platform state. Fix forward.

---

## Phase 11: Hetzner namespace and bootstrapped Secret

**Goal.** The Hetzner namespace contains the bootstrapped database Secret and CA bundle the chart will reference. Values are not committed to Git.

**Preconditions.** Phase 10 verification passes. The Hetzner Postgres endpoint exists (existing service or a Terraform-provisioned one) and you have its CA bundle and password.

**Steps.**
```bash
KUBECONFIG=generated/kubeconfig kubectl create namespace cicd-demo --dry-run=client -o yaml | KUBECONFIG=generated/kubeconfig kubectl apply -f -

# Real password is read from a local file or env var; not committed.
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo create secret generic cicd-demo-db \
  --from-literal=password="$HETZNER_DB_PASSWORD" \
  --dry-run=client -o yaml | KUBECONFIG=generated/kubeconfig kubectl apply -f -

KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo create configmap cicd-demo-postgres-ca \
  --from-file=ca.crt="$HETZNER_POSTGRES_CA_PATH" \
  --dry-run=client -o yaml | KUBECONFIG=generated/kubeconfig kubectl apply -f -
```

**Verification.**
```bash
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo get secret cicd-demo-db -o jsonpath='{.data.password}' | base64 -d | wc -c
# expect: > 0 (a non-empty password)

KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo get configmap cicd-demo-postgres-ca -o jsonpath='{.data.ca\.crt}' | grep -q "BEGIN CERTIFICATE" && echo OK
```

Confirm that the password value does not appear in any tracked file:
```bash
git grep -F "$HETZNER_DB_PASSWORD" || echo OK
```

**Postconditions.** The Secret and CA bundle exist in Hetzner; the chart's references will resolve.

---

## Phase 12: Harbor in Hetzner

**Goal.** Harbor is reachable in Hetzner with a project and a robot account ready to receive image traffic.

**Preconditions.** Phase 11 verification passes.

**Approach.** Install Harbor with the official chart via Terraform's Helm provider (or `helm install` after Terraform prerequisites). Configure:
- DNS: `harbor.<your-domain>` → ingress IP.
- TLS: cert-manager with Let's Encrypt, or a static cert.
- A project named `cicd-demo-cache` (the proxy-cache project; created in Phase 13).
- An admin password stored in OpenBao or a Kubernetes Secret out-of-band — not in Git, not in tfvars.

**Verification.**
```bash
curl -fsS https://harbor.<your-domain>/api/v2.0/health
# expect: {"status":"healthy",...}

# Login as admin (interactive or via configured robot):
docker login harbor.<your-domain>
# expect: Login Succeeded
```

**Postconditions.** Harbor is up; project namespace exists; auth works.

**On failure.**
- TLS: certificate not issued → check cert-manager logs; do not bypass with `--insecure`.

---

## Phase 13: Harbor proxy cache for GHCR

**Goal.** A Hetzner test pod pulls a GHCR image through Harbor and reports the expected `/version`.

**Preconditions.** Phase 12 verification passes. The image from Phase 8 exists in GHCR.

**Steps.**

1. In Harbor: create a Registry endpoint of type "Github Container Registry" pointing at `https://ghcr.io`. Authentication: a GitHub Personal Access Token with `read:packages` (or use anonymous if your packages are public).

2. Create a Project named `cicd-demo-cache` configured as a proxy cache for that registry endpoint.

3. From Hetzner, run a smoke pod:
```yaml
# generated/probe-pod.yaml (gitignored)
apiVersion: v1
kind: Pod
metadata:
  name: pull-probe
  namespace: cicd-demo
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: harbor.<your-domain>/cicd-demo-cache/<owner>/<repo>/cicd-demo@sha256:<digest-from-phase-8>
      command: ["sh", "-c", "wget -qO- http://localhost:8080/version || true; sleep 30"]
      ports: [{ containerPort: 8080 }]
      env:
        - name: APP_ENV
          value: probe
        # Skip DB env vars for this probe; we are testing the pull path only.
```

```bash
KUBECONFIG=generated/kubeconfig kubectl apply -f generated/probe-pod.yaml
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo wait --for=condition=ContainersReady pod/pull-probe --timeout=2m
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo logs pull-probe | grep -q '"image_digest"' && echo OK
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo delete pod pull-probe
```

**Verification.** The pod becomes Ready and logs the `/version` JSON. Harbor's project shows the cached image.

**Postconditions.** The cluster can pull images from GHCR through Harbor by digest.

**On failure.**
- `ImagePullBackOff` with `unauthorized` → Harbor robot or proxy-cache credentials need adjusting; check Harbor's configuration; configure a `dockerconfigjson` `imagePullSecret` if Harbor requires auth for proxy pulls.
- Wrong digest → confirm the digest from Phase 8's workflow summary is what you pasted.

---

## Phase 14: Argo CD installed and bootstrapped

**Goal.** Argo CD is installed in Hetzner, can read the Git repository, and has the namespace permissions it needs to deploy this app. No app sync yet.

**Preconditions.** Phase 13 verification passes.

**Approach.** Install via Terraform + Helm (Argo CD's official chart). Configure a Git repository credential (HTTPS PAT or SSH key) for this repo, stored as a Kubernetes Secret. Restrict to the project containing `cicd-demo`.

**Verification.**
```bash
KUBECONFIG=generated/kubeconfig kubectl -n argocd get pods
# expect: argocd-server, argocd-repo-server, etc. all Running

# UI / API reachable:
curl -fsS https://argocd.<your-domain>/healthz
# expect: ok
```

In Argo CD UI: confirm the repository connection status shows "Successful" for this repo. Do not create the Application yet.

**Postconditions.** Argo CD is ready to receive an Application definition.

---

## Phase 15: Argo CD Application syncs the chart

**Goal.** An Argo CD Application points at the Helm chart in Git. After sync, the Hetzner cluster runs the app and `/db-healthz` passes.

**Preconditions.** Phases 11, 13, and 14 verification all pass. `helm/cicd-demo/values-hetzner.yaml` is committed (rendered from Phase 9's template with the digest from Phase 8).

**Files to create.**

1. `argocd/application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cicd-demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<owner>/<repo>.git
    targetRevision: main
    path: github-harbor-argocd-cicd-poc/helm/cicd-demo
    helm:
      valueFiles:
        - values-hetzner.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: cicd-demo
  syncPolicy:
    syncOptions:
      - CreateNamespace=false  # Phase 11 created it
    # Manual sync first; auto-sync added later (see DESIGN.md §10).
```

**Steps.**
```bash
KUBECONFIG=generated/kubeconfig kubectl apply -f argocd/application.yaml
# Then in Argo CD UI (or via CLI): click Sync.
```

**Verification.**
```bash
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo rollout status deploy/cicd-demo --timeout=3m

# From inside the cluster, or via the ingress:
curl -fsS https://cicd-demo.<your-domain>/healthz | grep -q '"status":"ok"' && echo OK
curl -fsS https://cicd-demo.<your-domain>/db-healthz | grep -q '"status":"ok"' && echo OK
```

**Postconditions.** The full path works: Git → Argo CD → Hetzner cluster → app → Hetzner Postgres with `verify-full`.

**On failure.**
- Argo CD shows OutOfSync forever → check the Application's `status.conditions`; common cause is a chart syntax error in `values-hetzner.yaml`.
- Pod runs but `/db-healthz` is 503 → DB connectivity, CA bundle, or Secret. Check Pod logs and Pod env via `kubectl exec`.
- `/db-healthz` says "hostname does not match" → `database.host` in `values-hetzner.yaml` is not on the Hetzner Postgres cert SAN list.

---

## Phase 16: Promotion via Git

**Goal.** Promoting a new image is a Git change that updates the digest in `values-hetzner.yaml`. Argo CD reconciles the new digest. Rollback is a Git revert.

**Preconditions.** Phase 15 verification passes.

**Files to create.** At the **repo root**:

1. `.github/workflows/cicd-demo-promote.yaml` — a `workflow_dispatch` workflow with inputs:
   - `digest` (required) — the SHA256 digest from a successful publish.
   - The job:
     1. Checks out the repo.
     2. Renders `helm/cicd-demo/values-hetzner.yaml` from the template (Phase 9) with the new digest.
     3. Opens a pull request titled `promote cicd-demo @ <short-digest>`.
     4. Does **not** merge automatically.

   This keeps promotion reviewable and revertable.

**Verification.**

1. Trigger the workflow with the digest from a Phase 8 publish.
2. Confirm a PR is opened that changes only `values-hetzner.yaml`.
3. Merge the PR.
4. Watch Argo CD: it detects the change, syncs, the new Pod becomes Ready.
5. `/version` reports the new `image_digest`.

**Rollback verification:**

1. `git revert` the promotion commit on `main`.
2. Argo CD detects the change, syncs, the previous Pod returns.
3. `/version` reports the previous `image_digest`.

**Postconditions.** Promotion and rollback are both Git operations.

---

## Phase 17: Harbor replication

**Goal.** Harbor copies selected GHCR images into a Harbor project on its own schedule (or on demand). The cluster pulls from the replicated project, decoupled from GHCR availability at deploy time.

**Preconditions.** Phase 16 verification passes.

**Steps.**

1. Create a second Harbor project: `cicd-demo` (not a proxy cache; a regular project).
2. Create a Replication rule in Harbor:
   - Source: the GHCR registry endpoint.
   - Filters: `cicd-demo:*` tags or whatever scope you choose.
   - Destination: the `cicd-demo` project.
   - Trigger: manual first; consider event-based later.
3. Run the replication; confirm the image lands in `harbor.<your-domain>/cicd-demo/cicd-demo`.
4. Add a second Hetzner values file or modify `values-hetzner.yaml` to point at the replicated path:
   ```yaml
   image:
     repository: harbor.<your-domain>/cicd-demo/cicd-demo
     digest: "sha256:..."
   ```
5. Promote (Phase 16 mechanism) and confirm the new pull comes from the replicated project.

**Verification.**
```bash
# Harbor's UI shows the image in the cicd-demo project.
# After promotion, kubectl describe pod shows the image was pulled from the replicated path.
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo describe pod -l app=cicd-demo | grep "Image:" | grep -q "/cicd-demo/cicd-demo@" && echo OK
```

**Postconditions.** Cluster pulls go through replicated Harbor; GHCR is no longer in the deploy-time path.

---

## Phase 18: Replace bootstrapped Secret with OpenBao + ESO

**Goal.** The database password lives in OpenBao. External Secrets Operator reconciles it into `Secret/cicd-demo-db`. The chart does not change. Rotating the password in OpenBao causes the Pod to pick up the new value without a chart or Git change.

**Preconditions.** Phase 17 verification passes. The sibling `openbao/` lab (or another OpenBao instance) is reachable from the Hetzner cluster, or you deploy OpenBao into Hetzner via Terraform as part of this phase.

**Steps.**

1. Install ESO via Terraform + Helm (`external-secrets/external-secrets` chart) into a `external-secrets` namespace.

2. In OpenBao:
   - Enable a KV v2 secrets engine at `kv/`.
   - Write the password: `vault kv put kv/cicd-demo/db password=<value>`.
   - Create a policy that allows `read` on `kv/data/cicd-demo/db`.
   - Create a Kubernetes auth method binding (or AppRole) tied to that policy and to the `cicd-demo` ServiceAccount in the `cicd-demo` namespace.

3. Create `argocd/clustersecretstore.yaml`:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ClusterSecretStore
   metadata:
     name: openbao
   spec:
     provider:
       vault:
         server: "https://openbao.<your-domain>"
         path: "kv"
         version: "v2"
         auth:
           kubernetes:
             mountPath: "kubernetes"
             role: "cicd-demo"
             serviceAccountRef:
               name: cicd-demo
               namespace: cicd-demo
   ```

4. Create `argocd/externalsecret.yaml`:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: cicd-demo-db
     namespace: cicd-demo
   spec:
     refreshInterval: "1h"
     secretStoreRef:
       name: openbao
       kind: ClusterSecretStore
     target:
       name: cicd-demo-db   # same name the chart references
       creationPolicy: Owner
     data:
       - secretKey: password   # same key the chart references
         remoteRef:
           key: cicd-demo/db
           property: password
   ```

5. Add both files to the Argo CD Application's path (or a sibling Application). Sync.

6. Delete the bootstrapped Secret from Phase 11 — ESO will recreate it from OpenBao:
   ```bash
   KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo delete secret cicd-demo-db
   # ESO reconciles within `refreshInterval` (or trigger a sync via the ESO CLI).
   KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo get secret cicd-demo-db
   # expect: AGE is recent; managed by ESO (annotations show external-secrets.io)
   ```

**Verification.**
```bash
# 1. Pod is healthy with the ESO-managed Secret.
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo rollout status deploy/cicd-demo
curl -fsS https://cicd-demo.<your-domain>/db-healthz | grep -q '"status":"ok"' && echo OK

# 2. Rotation works. In OpenBao:
vault kv put kv/cicd-demo/db password=<NEW_VALUE>
# Also rotate the DB user's password in Postgres to match.
# Wait for ESO refresh (or force) and rolling restart of the Pod (you may need
# to add a checksum annotation on the Deployment so that Pods restart when the
# Secret content changes — this is a chart change, accepted in this phase).
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo rollout restart deploy/cicd-demo
KUBECONFIG=generated/kubeconfig kubectl -n cicd-demo rollout status deploy/cicd-demo
curl -fsS https://cicd-demo.<your-domain>/db-healthz | grep -q '"status":"ok"' && echo OK
```

Confirm that the rotated password appears nowhere in Git:
```bash
git grep -F "<NEW_VALUE>" || echo OK
```

**Postconditions.** OpenBao is the source of truth for the password. The chart references the same Secret name as before. Rotation is a write to OpenBao plus a rollout, not a Git change.

**On failure.**
- ESO `ExternalSecret` stuck in `SecretSyncedError` → check ESO logs and the ClusterSecretStore status; usually authentication to OpenBao.
- App fails after rotation with a stale password → the Pod has not been restarted; ensure the Deployment template has a `checksum/secret` annotation tied to the Secret content, or run a manual rollout.

---

## Phase 19: Failure drills

**Goal.** The chain handles bad images, bad config, and OpenBao unavailability without corrupting state.

**Preconditions.** Phase 18 verification passes.

**Drills.**

1. **Bad image digest.** Promote a digest that does not exist in Harbor.
   - Expected: Pod stays in `ImagePullBackOff`; previous Pod keeps serving traffic.
   - Recovery: `git revert` the promotion. Argo CD restores the previous digest. New Pod becomes Ready.

2. **Bad DB host.** Change `database.host` in `values-hetzner.yaml` to a non-existent name, commit, sync.
   - Expected: New Pod starts, fails readiness, never receives traffic; old Pod stays.
   - Recovery: `git revert`.

3. **Bad CA bundle.** Replace the CA ConfigMap with a CA that does not match the Postgres server cert.
   - Expected: `/db-healthz` reports certificate-verification failure; pod readiness fails.
   - Recovery: restore the correct CA ConfigMap.

4. **OpenBao unreachable.** Block egress to OpenBao (or scale OpenBao to zero) for a short window.
   - Expected: Existing Secret stays as-is; existing Pods keep running; `ExternalSecret` status reports failures.
   - Recovery: restore OpenBao reachability; ESO reconciles.

**Verification.** For each drill: take notes on observed behavior, recovery time, and any state corruption (there should be none). Document in `DESIGN.md` or a `RUNBOOK.md` if useful.

**Postconditions.** The chain's failure modes are characterized.

---

## Phase 20: Final runbook

**Goal.** The full path is reproducible from a clean state by following documented commands.

**Preconditions.** Phase 19 verification passes.

**Steps.**

1. Tear down the local environment (`helm uninstall`, `docker compose down`).
2. From scratch, follow phases 1 through 5 using only commands documented in this plan; record any deviations needed.
3. Update each phase in this PLAN.md with corrections from the dry run.
4. Update `DESIGN.md` "Open questions" section with how each was resolved during implementation.
5. Add a top-level `RUNBOOK.md` (or extend this PLAN) with the production-mode condensed sequence for operators who only need to ship a change, not bootstrap the whole POC.

**Verification.** A second person (or LLM agent) runs phases 1 through 5 from a clean checkout and reports any step that needs more detail.

**Postconditions.** The POC is repeatable.

---

## Appendix A: Final checklist

Tick these off during a clean end-to-end run.

- [ ] `make test` passes locally.
- [ ] `docker compose up -d postgres` starts; `/db-healthz` is 200 with `verify-full`.
- [ ] `docker build` succeeds; container `/db-healthz` is 200.
- [ ] `helm install` in Rancher Desktop; `/db-healthz` is 200 through Service.
- [ ] `helm upgrade` then `helm rollback` round-trip; `/db-healthz` is 200 throughout.
- [ ] PR triggers `cicd-demo CI`; all steps green; nothing pushed.
- [ ] Merge to `main` triggers `cicd-demo publish`; GHCR holds the digest.
- [ ] Hetzner namespace has `cicd-demo-db` and `cicd-demo-postgres-ca`.
- [ ] Harbor proxy cache pulls the GHCR image; Hetzner probe pod logs `/version`.
- [ ] Argo CD Application syncs; `/db-healthz` is 200 in Hetzner.
- [ ] `cicd-demo promote` opens a PR; merging updates the digest; Argo CD redeploys.
- [ ] Harbor replication rule lands the image in the `cicd-demo` project; cluster pulls from there.
- [ ] OpenBao + ESO replaces the bootstrapped Secret; password rotation works without a Git change.
- [ ] Failure drills behave as documented.
- [ ] A clean repeat of phases 1–5 by a fresh operator works end-to-end.
