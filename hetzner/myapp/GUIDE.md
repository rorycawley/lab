# Clojure on Kubernetes: End-to-End Guide

## Why This Setup Exists

This project takes a simple Clojure web service and gives it a production-grade deployment pipeline. The goal: you edit code locally, push to Git, and it's live on the internet with TLS, health checks, metrics, logs, and traces — all automated.

Every choice here solves a specific problem:

- **Clojure REPL** — instant feedback while developing. No restart cycle.
- **Uberjar** — one self-contained file with your app + all dependencies. Simple to deploy.
- **Multi-stage Docker** — builds the uberjar in one image, runs it in a tiny one. Security + small size.
- **Helm charts** — same deployment config for local and production. Change one values file, not the whole pipeline.
- **Rancher Desktop** — run real Kubernetes locally. Catch deployment bugs before they hit production.
- **Hetzner + kube-hetzner** — cheap, European Kubernetes. ~€30/mo instead of ~€200/mo on AWS.
- **GitHub Actions CI/CD** — push code, it deploys. No manual steps.
- **LGTM stack** — metrics, logs, and traces in one place. When something breaks at 2am, you can see what happened.

## Project Structure

```
myapp/
├── src/myapp/core.clj          ← the app (ring + reitit + metrics)
├── dev/user.clj                ← REPL dev namespace
├── deps.edn                   ← dependencies
├── build.clj                  ← uberjar build script
├── bb.edn                     ← babashka task runner (all commands live here)
├── Dockerfile                 ← multi-stage build + OTel agent
├── entrypoint.sh              ← conditional OTel agent loader
├── .dockerignore              ← keeps build context small
├── .gitignore                 ← keeps secrets out of git
├── .github/workflows/
│   ├── ci.yaml                ← build + push image on push/PR
│   └── cd.yaml                ← deploy to Hetzner after CI succeeds
├── test/myapp/
│   └── core_test.clj          ← smoke tests for /health, /hello, /metrics
├── helm/
│   ├── cluster-issuer.yaml    ← ClusterIssuer template (configurable ingress class)
│   └── myapp/
│       ├── Chart.yaml
│       ├── values.yaml            ← defaults
│       ├── values-local.yaml      ← Rancher Desktop overrides
│       ├── values-prod.yaml       ← Hetzner production overrides
│       └── templates/
│           ├── deployment.yaml    ← pod spec with rolling update + OTel + probes
│           ├── service.yaml       ← internal networking
│           ├── ingress.yaml       ← external access + TLS + custom annotations
│           └── pdb.yaml           ← PodDisruptionBudget (auto-created if replicas > 1)
├── monitoring/                ← Grafana LGTM stack
│   ├── install.sh             ← one-command setup (order matters)
│   ├── values-minio.yaml      ← object storage for Mimir
│   ├── values-loki.yaml       ← log aggregation
│   ├── values-tempo.yaml      ← distributed tracing
│   ├── values-mimir.yaml      ← metrics storage
│   ├── values-grafana.yaml    ← dashboards (datasources pre-configured)
│   └── values-alloy.yaml      ← collection agent
└── terraform/
    └── main.tf                ← Hetzner cluster definition
```

---

## The Four Workflows

This project has four distinct workflows. They serve different purposes, run at different frequencies, and catch different kinds of problems. Understanding the boundaries between them is important — mixing them up leads to confusion and mistakes.

### Workflow 1: Development (the Clojure REPL)

**Purpose:** Write and test application logic — routes, handlers, business rules.

**When you use it:** Every day. This is your primary activity. You're adding features, fixing bugs, changing routes, updating business logic.

**How it works:**

```
bb dev → nREPL starts on port 7888
  → Connect editor (Calva/Cursive/CIDER)
  → (start) boots the server
  → Edit code → eval → change is live instantly
  → (restart) only if you change server config
```

**What it touches:** `src/myapp/core.clj`, `dev/user.clj`, `deps.edn`. That's it. You're working on the application, not the infrastructure.

**Where it runs:** Your laptop. The REPL is a local process. No cluster, no Docker, no Kubernetes. Just a JVM running your code.

**How fast is the feedback loop:** Milliseconds. You evaluate a form and the running server picks up the change immediately. No build step, no restart, no deploy. This is what makes Clojure development feel qualitatively different from languages with a compile-restart cycle.

**What it catches:** Logic errors, incorrect responses, broken routes, wrong status codes, missing fields. Everything about whether your code does the right thing.

**What it doesn't catch:** Whether your app works inside a container. Whether health probes fire at the right time. Whether your Helm chart produces valid Kubernetes resources. Whether the Dockerfile builds correctly. That's what Workflow 2 is for.

### Workflow 2: Local Kubernetes Validation (Rancher Desktop)

**Purpose:** Verify that your app works inside Kubernetes before pushing to production. Catch deployment problems locally, where they're cheap to fix.

**When you use it:** Before pushing changes that affect deployment — Dockerfile changes, Helm template changes, new environment variables, health endpoint changes, dependency updates. Not every single code change, but any change that touches the boundary between your app and its runtime environment.

**How it works:**

```
bb helm-local
  → docker build (native platform, for local)
  → helm upgrade --install with values-local.yaml
  → kubectl rollout status (waits for pods to be healthy)
  → curl http://myapp.localhost/health (smoke test)
```

**What it touches:** `Dockerfile`, `helm/myapp/` (Chart + templates + values-local.yaml), and your local Rancher Desktop K8s cluster.

**Where it runs:** Your laptop, inside Rancher Desktop's K8s cluster. No cloud resources, no cost, no risk to production.

**Why this is a separate workflow, not part of the REPL:** The REPL tests your code in isolation — a JVM process running on your Mac. Local K8s tests your code packaged as a Docker image, deployed via Helm, running inside a pod, behind an ingress, with health probes checking it. These are fundamentally different environments. Problems that don't exist in the REPL appear here:

- **Docker build failures** — missing dependencies, wrong base image, build context issues
- **Health probe timing** — the JVM takes 15-30 seconds to start inside a container, and if the liveness probe fires too early, K8s kills the pod before it's ready (`CrashLoopBackOff`)
- **Environment variable mismatches** — an env var that exists on your Mac but isn't set in the Helm chart
- **Ingress routing** — typos in the Helm ingress template, wrong port mappings
- **Image pull policy** — forgetting `imagePullPolicy: Never` for local means K8s tries to pull from a registry that doesn't have your local image

**The key insight:** local K8s uses the same Helm chart as production. `values-local.yaml` and `values-prod.yaml` override the same `templates/`. If it works in Rancher Desktop, it will work on Hetzner (with the exception of architecture — local builds ARM, production needs amd64, but `bb docker-push` handles that).

**Debug commands when something fails:**

```bash
bb k8s-status            # what state are pods in?
bb k8s-describe          # events: image pull errors, probe failures
bb k8s-logs              # what is the app printing?
bb k8s-shell             # get a shell inside the container
```

### Workflow 3: Infrastructure Provisioning (Terraform)

**Purpose:** Create and manage the Hetzner cluster, load balancer, network, and firewall.

**When you use it:** Rarely. Once to create the cluster, once to destroy it, occasionally to update node types or add capacity. Maybe a few times a month, or less.

**How it works:**

```
bb tf-apply → Terraform reads main.tf
  → Creates Hetzner servers, network, firewall, load balancer
  → Installs k3s on each server
  → Configures Traefik, cert-manager, Hetzner CSI driver
  → Outputs kubeconfig for kubectl access

bb tf-destroy → Tears everything down
  → Uninstalls apps and monitoring first
  → Deletes all K8s resources and PVCs
  → Destroys Hetzner servers, LB, network
  → Cleans up orphaned volumes
  → Billing stops immediately
```

**What it touches:** `terraform/main.tf`, `terraform/terraform.tfstate`. The state file is critical — it maps your config to real Hetzner resources.

**Where it runs:** Your laptop. Terraform runs locally and talks to the Hetzner API. It's not automated via CI/CD (deliberately — infrastructure changes should be intentional, not triggered by a code push).

**Why it's separate from CI/CD:** Infrastructure changes are high-impact and infrequent. You don't want a typo in `main.tf` to accidentally delete your cluster on the next `git push`. Keeping infrastructure provisioning as a manual laptop operation gives you a chance to review with `bb tf-plan` before applying. In larger teams, you'd add a Terraform-specific CI pipeline with plan-and-approve gates, but for a personal project, running it locally is the right level of control.

**One-time setup tasks that live alongside this workflow:**
- Packer snapshots (MicroOS images — once per Hetzner project, persists forever)
- DNS A records (once per domain, update only if load balancer IP changes)
- ClusterIssuer for cert-manager (once per cluster creation — doesn't survive destroy)
- `bb monitoring-seal-secrets` (once per cluster creation — installs the Sealed Secrets controller and seals fresh Grafana / MinIO credentials)
- `bb monitoring-install` (once per cluster creation — the LGTM stack)

These are all manual, infrequent, and intentional. They form the "platform layer" that your application runs on.

### Workflow 4: CI/CD Pipeline (GitHub Actions)

**Purpose:** Automatically build, deploy, and verify your application when you push code.

**When you use it:** Every time you push to `main`. This is the bridge between writing code (Workflow 1) and running it in production.

**How it works:**

```
git push to main
  ↓
ci.yaml (runs on every push + PRs):
  → Checks out code
  → Builds Docker image for linux/amd64
  → Pushes to GHCR with commit SHA tag + :latest
  ↓
cd.yaml (runs after CI succeeds, main branch only):
  → Checks out code
  → Sets up kubeconfig from KUBE_CONFIG secret
  → helm upgrade --install with --set for image tag + domain
  → Waits for rollout (new pods healthy)
  → Smoke test: curl https://yourdomain.com/health
  → If smoke test fails: helm rollback (automatic)
```

**What it touches:** `.github/workflows/ci.yaml`, `.github/workflows/cd.yaml`, `helm/myapp/` (the Helm chart), and the Hetzner cluster (via kubectl/helm).

**Where it runs:** GitHub's servers. Not your laptop. You push code and walk away.

**What it needs from the other workflows:**
- A running cluster (Workflow 3 must have been run at least once)
- `KUBE_CONFIG` secret in GitHub (the kubeconfig from Workflow 3)
- `PROD_HOST` variable in GitHub (your domain)
- GHCR package must be public (so the cluster can pull images)

### How the Workflows Relate

```
┌─────────────────────────────────────────────────────────────┐
│ Workflow 3: Infrastructure (Terraform)                      │
│ bb tf-apply → creates the cluster                           │
│ bb monitoring-install → sets up observability                │
│ Runs: rarely (create/destroy/modify cluster)                │
│ Who: you, from your laptop                                  │
└──────────────────────┬──────────────────────────────────────┘
                       │ provides: cluster, kubeconfig
                       ▼
┌──────────────────────────────────────┐
│ Workflow 1: Development (REPL)       │
│ bb dev → edit code → eval → test     │
│ Runs: every day                      │
│ Who: you, from your laptop           │
└──────────────────┬───────────────────┘
                   │ code changes
                   ▼
┌──────────────────────────────────────┐
│ Workflow 2: Local K8s (Rancher)      │     ┌──────────────────────────┐
│ bb helm-local → build + deploy local │────→│ Workflow 4: CI/CD        │
│ Catches deployment issues early      │     │ git push → build → deploy│
│ Runs: before pushing deploy changes  │     │ Runs: every push to main │
│ Who: you, from your laptop           │     │ Who: GitHub Actions      │
└──────────────────────────────────────┘     └──────────────────────────┘
                                                      │
                                                      │ deploys to
                                                      ▼
                                             Hetzner cluster (from Workflow 3)
```

### Boundaries and Separation

**Workflow 1 (REPL) has no dependency on anything else.** You can develop in the REPL without a Hetzner cluster, without GitHub Actions, without Docker, even without Rancher Desktop. The REPL is self-contained. This is important — your development speed should never be bottlenecked by infrastructure.

**Workflow 2 (Local K8s) depends on Rancher Desktop but nothing in the cloud.** It uses Docker and Helm locally. It doesn't need a Hetzner cluster, GitHub Actions, or a domain name. It's your local staging environment.

**Workflow 4 (CI/CD) depends on Workflow 3 (Infrastructure).** CI/CD needs a cluster to deploy to. If you destroy the cluster, CI/CD has nowhere to deploy and will fail. If you recreate the cluster, you need to update the `KUBE_CONFIG` secret in GitHub with the new kubeconfig.

**Workflow 3 (Infrastructure) is independent of Workflow 4 (CI/CD).** You can provision and destroy infrastructure without CI/CD. In fact, you must — the cluster has to exist before CI/CD can deploy to it.

**The Helm chart is the shared artifact.** `helm/myapp/` is used by Workflow 2 (via `bb helm-local`), Workflow 4 (via `cd.yaml`'s `helm upgrade`), and manual deploys (via `bb helm-prod`). Changes to the Helm chart affect all three. This is intentional — it's the environment parity principle. But it means you should test Helm changes locally (Workflow 2) before pushing them through CI/CD (Workflow 4).

**The Dockerfile is another shared artifact.** It's used by Workflow 2 (local build) and Workflow 4 (CI build). The difference: Workflow 2 builds for your Mac's architecture (ARM), Workflow 4 builds for Hetzner (amd64). If the Dockerfile breaks, Workflow 2 catches it before Workflow 4 tries to deploy it.

### What Each Workflow Catches

| Problem | Caught by | Not caught by |
|---------|-----------|---------------|
| Logic error in a route handler | Workflow 1 (REPL) | — |
| Wrong HTTP status code | Workflow 1 (REPL) | — |
| Dockerfile build failure | Workflow 2 (Local K8s) | Workflow 1 (REPL) |
| Health probe fires too early | Workflow 2 (Local K8s) | Workflow 1 (REPL) |
| Missing environment variable in Helm | Workflow 2 (Local K8s) | Workflow 1 (REPL) |
| Ingress routing broken | Workflow 2 (Local K8s) | Workflow 1 (REPL) |
| ARM image deployed to x86 cluster | Workflow 4 (CI/CD) | Workflow 2 (builds native) |
| TLS certificate not issued | Workflow 4 (smoke test) | Workflow 2 (no TLS locally) |
| GHCR image pull fails (private) | Workflow 4 (deploy) | Workflow 2 (local image) |
| Cluster doesn't exist | Workflow 4 (deploy fails) | Workflow 2 (uses local cluster) |
| Terraform config error | Workflow 3 (tf-plan) | All others |

### What Triggers Each Workflow

| Trigger | Workflow | What happens |
|---------|----------|-------------|
| You open your editor | 1: Development | REPL, code changes |
| `bb helm-local` | 2: Local K8s | Build + deploy to Rancher Desktop |
| `bb tf-apply` | 3: Infrastructure | Create/update Hetzner cluster |
| `bb tf-destroy` | 3: Infrastructure | Tear down cluster, stop billing |
| `bb monitoring-install` | 3: Infrastructure | Install LGTM stack (one-time) |
| `git push` to `main` | 4: CI/CD | Build image → deploy → smoke test |
| Pull request opened | 4: CI only | Build image (no deploy) — catches build failures early |

### The Daily Workflow vs The Setup Workflow

Once everything is set up, your daily workflow touches only Workflows 1 and 4:

```
bb dev → edit code → test in REPL → git push → done
```

If you're changing deployment config (Dockerfile, Helm), add Workflow 2:

```
bb dev → edit code → bb helm-local → verify → git push → done
```

You don't think about Terraform, monitoring, or certificates. CI/CD handles deployment. The infrastructure sits there running. Grafana watches everything. Certificates renew themselves.

The setup workflow (Workflow 3 + one-time tasks) is more involved, but you only do it once. If you destroy the cluster for cost savings, bringing it back is about 10 minutes of commands (all documented in the "Bringing the cluster back up" section).

---

## Step 1: The Development Loop (REPL)

**Why this matters:** In most languages, you write code, restart the server, wait, test, repeat. In Clojure, the server stays running and you inject code changes into it live. This makes development feel instant — you change a function, evaluate it, and the running server immediately uses the new version.

**How it works:**

```bash
bb dev
# → nREPL server started on port 7888
```

This starts an nREPL server. nREPL is a protocol that lets your editor talk to the running Clojure process. Connect your editor (Calva, Cursive, or CIDER) to `localhost:7888`.

Then evaluate in the REPL:

```clojure
(start)
;; → Server running → http://localhost:8080/health
```

**The key trick:** `dev/user.clj` passes `#'core/app` (the *var*) to Jetty, not `core/app` (the *value*). A var is like a pointer — Jetty always looks up the current value when a request comes in. So when you re-evaluate a route definition in `core.clj`, the running server picks it up immediately. No restart.

**Typical flow:**

1. Edit a route in `core.clj`
2. Eval the changed form (Ctrl+Enter in Calva, C-c C-c in CIDER)
3. Hit the endpoint in your browser — change is live
4. Only call `(restart)` if you change server config like the port

**Why babashka (`bb`)?** Babashka is a fast Clojure scripting tool. `bb.edn` is a task runner — think of it as a Makefile for Clojure projects. Every command in this project is a `bb` task. You never need to remember long shell commands.

---

## Step 2: Dockerfile Explained

**Why a multi-stage build?** A full Clojure build environment (JDK + build tools + all dependencies) is ~800MB. Your running app just needs the JRE and a JAR file (~100MB). Multi-stage builds use the big image to build, then copy only the result into a tiny image. This means smaller images, faster pulls, less attack surface.

**Why an uberjar?** Clojure apps have many small dependency JARs. An uberjar bundles everything into one file — your code, all libraries, even Clojure itself. This makes deployment trivial: one file, one `java -jar` command.

The Dockerfile has two stages:

**Stage 1 (builder):** Starts from a full Clojure+JDK image. Copies `deps.edn` first and runs `clj -P` to download dependencies. Docker caches this layer — rebuilds are fast (seconds) unless you change dependencies. Then copies source and builds the uberjar.

**Stage 2 (runtime):** Starts from a tiny JRE-only Alpine image (~80MB). Creates a non-root user (security best practice — if the app is compromised, the attacker doesn't have root). Copies the uberjar and the OpenTelemetry Java agent (for tracing). That's it.

The `.dockerignore` file keeps the build context small by excluding `terraform/`, `monitoring/`, `helm/`, etc. Without it, Docker sends ~170MB of irrelevant files to the builder.

**Test locally:**

```bash
bb docker-build          # build the image (native platform, for dev)
bb docker-run            # run standalone (no K8s)
curl localhost:8080/health
```

---

## Step 3: Local Kubernetes with Rancher Desktop

### What Kubernetes Actually Does

Kubernetes (K8s) solves a simple problem: how do you run containers reliably? Without K8s, you'd SSH into a server, run `docker run`, and hope nothing crashes. If it does crash, you'd need to notice, SSH in again, and restart it. If you need more capacity, you'd manually start another container and figure out load balancing yourself.

Kubernetes automates all of that. You tell it "I want 2 copies of my app running at all times" and it makes that happen. If a container crashes, K8s restarts it. If a node dies, K8s moves the containers to a healthy node. If you deploy a bad version, K8s can roll back automatically.

### The Key Concepts (just enough to understand the Helm chart)

**Pod** — the smallest deployable unit. For our app, one pod = one running JVM. Think of it as a wrapper around your Docker container that K8s can manage.

**Deployment** — tells K8s "run N replicas of this pod and keep them running." Our deployment says: run 2 replicas of the myapp container, give each pod 512Mi of memory, and check `/health` every 10 seconds to make sure it's alive.

**Service** — pods get random IP addresses that change when they restart. A Service gives your pods a stable internal DNS name (`myapp.default.svc`) and load-balances traffic across all replicas.

**Ingress** — the Service is only reachable inside the cluster. An Ingress exposes it to the outside world. It says: "when someone hits `myappk8s.net`, route traffic to the myapp Service." The Ingress controller (Traefik, installed by kube-hetzner) handles TLS termination, so your app doesn't need to know about certificates.

**Namespace** — a way to organize resources. Your app runs in the `default` namespace. Monitoring runs in the `monitoring` namespace. They're isolated so `helm uninstall` in one namespace doesn't affect the other.

**PersistentVolumeClaim (PVC)** — a request for storage. When Grafana or Mimir need disk space that survives pod restarts, they create a PVC. On Hetzner, each PVC becomes a real Hetzner Cloud Volume (which is why you saw 13 orphaned volumes after destroying the cluster without cleaning up first).

### Why Helm (and What It Replaces)

Without Helm, deploying to Kubernetes means writing raw YAML files — one for the Deployment, one for the Service, one for the Ingress. For our simple app, that's about 150 lines of YAML. It looks like this:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: myapp
  template:
    spec:
      containers:
        - name: myapp
          image: ghcr.io/rorycawley/myapp:latest
          ports:
            - containerPort: 8080
```

This works, but it has problems:

**Problem 1: No variables.** The image name `ghcr.io/rorycawley/myapp:latest` is hardcoded. If you want to deploy a different image tag, you edit the YAML. If you want to change replicas from 2 to 3, you edit the YAML. If you want a different domain in the Ingress, you edit the YAML. Every change means manually editing files and hoping you don't introduce a typo.

**Problem 2: No environment separation.** Your local Rancher Desktop cluster needs `imagePullPolicy: Never` (use local images). Your Hetzner cluster needs `imagePullPolicy: Always` (pull from GHCR). Your local cluster doesn't need TLS or a real domain. Your production cluster does. With raw YAML, you'd maintain two completely separate copies of every file — one for local, one for prod — and keep them in sync manually.

**Problem 3: No release management.** If you `kubectl apply` a broken deployment, how do you roll back? You'd need to remember what the previous YAML looked like, find it in your Git history, and re-apply it. There's no concept of "the previous working version."

**Problem 4: No packaging.** If someone else wants to deploy your app, they need to know which YAML files to apply, in what order, with what values. There's no single command to "install this app."

Helm solves all four problems.

### What Helm Actually Does

Helm is a package manager for Kubernetes — think `apt` for Linux or `brew` for macOS, but for K8s applications. A Helm "chart" is a package containing:

1. **Templates** — YAML files with `{{ .Values.xyz }}` placeholders instead of hardcoded values
2. **Values** — a `values.yaml` file with the defaults for all those placeholders
3. **Metadata** — `Chart.yaml` with the name, version, and description

When you run `helm install` or `helm upgrade`, Helm takes the templates, fills in the placeholders from the values file, and sends the resulting YAML to Kubernetes. You never write or edit raw YAML directly.

### How Values Files Enable Environment Parity

This is the key insight. You write templates once, then swap values files per environment:

**values.yaml** (defaults):
```yaml
replicaCount: 1
image:
  repository: ghcr.io/myuser/myapp
  tag: latest
  pullPolicy: Always
ingress:
  enabled: true
  host: ""
```

**values-local.yaml** (overrides for Rancher Desktop):
```yaml
replicaCount: 1
image:
  pullPolicy: Never    # use local Docker image
ingress:
  host: myapp.localhost
```

**values-prod.yaml** (overrides for Hetzner):
```yaml
replicaCount: 2
image:
  pullPolicy: Always   # pull from GHCR
ingress:
  host: ""             # set via --set flag from PROD_HOST env var
```

The templates are identical in both environments. The deployment template says `replicas: {{ .Values.replicaCount }}` and Helm fills in 1 for local, 2 for production. The ingress template says `host: {{ .Values.ingress.host }}` and Helm fills in `myapp.localhost` for local, `myappk8s.net` for production.

This means if a deployment works locally, it works in production — because the same templates generated both. The only differences are the values, and those are explicit and visible in the values files.

### Helm Releases and Rollback

Every time you run `helm upgrade --install`, Helm creates a "release" — a versioned snapshot of the deployed state. You can see the history:

```bash
helm history myapp
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         deployed    Upgrade complete
```

If revision 3 is broken, you roll back:

```bash
helm rollback myapp 2
```

Helm re-applies the templates and values from revision 2. This is what `cd.yaml` does automatically — if the smoke test fails after deploying, it runs `helm rollback myapp` to revert to the previous working revision.

This is much better than raw YAML, where rolling back means finding the old file in Git and re-applying it manually.

### Why Not Kustomize?

Kustomize is the other popular approach to K8s configuration. Instead of templates with placeholders, Kustomize takes raw YAML files and applies patches (overlays) per environment. It's built into `kubectl` (`kubectl apply -k`) so there's no extra tool to install.

Helm is better for this project for three reasons: it has release history and rollback (Kustomize doesn't), it has a huge ecosystem of pre-packaged charts (we use Helm charts for Grafana, Loki, Mimir, Tempo, Alloy, and MinIO), and the values-file pattern is easier to understand than Kustomize's patch/overlay system. The monitoring stack alone uses 6 Helm charts — doing that with Kustomize would mean maintaining raw YAML for each component.

### How the Helm Chart Maps to Kubernetes Concepts

```
helm/myapp/
├── Chart.yaml              ← name + version
├── values.yaml             ← defaults (replicas: 1, port: 8080, etc.)
├── values-local.yaml       ← overrides for local (imagePullPolicy: Never)
├── values-prod.yaml        ← overrides for production (ingress host, TLS)
└── templates/
    ├── deployment.yaml     ← creates the Deployment + Pods
    ├── service.yaml        ← creates the Service
    ├── ingress.yaml        ← creates the Ingress (TLS + domain routing)
    └── pdb.yaml            ← PodDisruptionBudget (when replicas > 1)
```

The templates are Go templates with `{{ .Values.xyz }}` placeholders. Helm fills them in from the values file. This is why the same chart works locally and in production — only the values change.

**Why Rancher Desktop?** It gives you a real K8s cluster on your Mac with Traefik, kubectl, and Helm pre-installed. No cloud account needed. You get the same behavior as production (pods, services, ingress, health probes) running entirely on your laptop.

**Key difference for local:** `imagePullPolicy: Never` tells K8s to use the Docker image you built locally instead of trying to pull from a registry. This is the one setting that makes local K8s dev practical.

**Deploy locally:**

```bash
bb helm-local
# Builds image → deploys to K8s → waits for pods → runs smoke test
```

**Access the app:**

```bash
# Via ingress (if Traefik is running in Rancher Desktop)
curl http://myapp.localhost/health

# Or port-forward (always works, bypasses ingress)
bb k8s-port-forward
curl http://localhost:8080/health
```

**Debug a failing pod:**

```bash
bb k8s-status            # what state are pods in?
bb k8s-describe          # shows events (image pull errors, probe failures, etc.)
bb k8s-logs              # application-level logs (stdout/stderr)
bb k8s-shell             # get a shell inside the container
```

### Health Probes: How K8s Knows Your App is Working

The deployment defines two probes that hit `/health` on your app:

**Liveness probe** — "is the app still alive?" If this fails 3 times in a row, K8s kills the pod and restarts it. This catches deadlocks, infinite loops, and other situations where the JVM is running but the app is stuck.

**Readiness probe** — "is the app ready to receive traffic?" If this fails, K8s removes the pod from the Service's load balancer. The pod keeps running, but it stops getting requests. This is useful during startup (the JVM needs 15-30 seconds before it's ready) and during graceful shutdown.

The `initialDelaySeconds: 45` gives the JVM time to start before the first probe fires. Without this, K8s would kill the pod before it finishes starting, creating an infinite restart loop (`CrashLoopBackOff`).

---

## Step 4: Manual Deploy to Hetzner

**Why manual first?** CI/CD automates deployment, but you need to understand each step before automating it. Manual deploy teaches you the pipeline. Once it works, you automate it and never do it manually again.

**4a. GHCR authentication:**

GitHub Container Registry (GHCR) is where your Docker images live. It's free, integrated with GitHub, and your CI/CD pipeline uses it automatically. Your `gh` CLI token needs the `write:packages` scope:

```bash
gh auth refresh --scopes write:packages
```

**4b. Build and push:**

```bash
bb docker-push
```

This auto-detects your GitHub username from `gh`, builds for `linux/amd64` (Hetzner runs x86 — your Mac is ARM), and pushes to `ghcr.io/YOUR_USER/myapp:latest`.

**4c. Make the GHCR package public (first time only):**

GHCR packages are private by default. Your Hetzner cluster has no credentials to pull private images (you'd need an imagePullSecret for that). Making it public is simplest for a personal project.

Go to `github.com/YOUR_USER?tab=packages` → click `myapp` → **Package settings → Danger Zone → Change visibility → Public**.

**4d. Deploy:**

```bash
export PROD_HOST=myappk8s.net
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
bb helm-prod
```

`bb helm-prod` auto-detects your GitHub username from `gh` and reads `PROD_HOST` from the environment. These are passed as `--set` flags to Helm, so `values-prod.yaml` never needs editing.

---

## Step 5: GitHub Actions CI/CD

**Why CI/CD?** Without it, deploying means: build Docker image, push to GHCR, run Helm, check it worked. With it, deploying means: `git push`. The pipeline does the rest, and if the new version breaks, it rolls back automatically.

**The split: CI vs CD.** CI (Continuous Integration) builds and tests your code. CD (Continuous Delivery) deploys it. They're separate workflows because they have different triggers — CI runs on pull requests too (so you can catch build failures before merging), while CD only runs on `main`.

Once this is set up, your daily workflow becomes:

```
Edit code → bb dev (REPL) → git push → GitHub Actions does the rest
```

**What stays on your laptop (one-time or rare):**
- `bb tf-apply` / `bb tf-destroy` — infrastructure changes are deliberate, not automated
- `bb monitoring-install` — one-time monitoring setup
- ClusterIssuer, DNS records — one-time

**What GitHub Actions does (on every push to main):**

| File | Trigger | What it does |
|------|---------|-------------|
| `ci.yaml` | Push to main + PRs | Build Docker image (amd64), push to GHCR |
| `cd.yaml` | After CI succeeds on main | Deploy via Helm, smoke test, auto-rollback |

CI also runs on pull requests (builds but doesn't push — useful for catching build failures). CD can be triggered manually from the GitHub Actions UI (useful for redeploying without a code change).

**One-time setup — two secrets + one variable:**

1. **`KUBE_CONFIG`** secret — your kubeconfig, base64-encoded. This is how GitHub Actions authenticates with your Hetzner cluster:

```bash
base64 < myapp_kubeconfig.yaml | pbcopy
```

Go to your repo → **Settings → Secrets and variables → Actions → New repository secret** → paste.

2. **`PROD_HOST`** variable — your domain name. This is a variable (not a secret) because it's not sensitive:

Go to **Settings → Secrets and variables → Actions → Variables tab → New repository variable**:
- Name: `PROD_HOST`
- Value: `myappk8s.net`

3. **GHCR package must be public** — GitHub Actions pushes the image, but your Hetzner cluster pulls it. If it's private, the pull fails.

4. **Workflow permissions** — your repo needs read/write permissions for `GITHUB_TOKEN`. Go to **Settings → Actions → General → Workflow permissions → Read and write permissions**.

5. **Link GHCR package to repo** — if the package was created before the repo (from a manual push), you need to link them. Go to `github.com/YOUR_USER?tab=packages` → `myapp` → **Package settings → Manage Actions access → Add Repository → myapp → Write**.

`GITHUB_TOKEN` is provided automatically by GitHub — no setup needed for GHCR push.

---

## Step 6: Hetzner Cluster with kube-hetzner

**Why Hetzner?** It's 5-10× cheaper than AWS/GCP for equivalent specs. A 4-node K8s cluster with a load balancer costs ~€30/mo. The same on AWS EKS would be €150-200+. The trade-off: no managed Kubernetes service, so we use kube-hetzner (an open-source Terraform module) to set up k3s.

**Why k3s?** k3s is a lightweight Kubernetes distribution. It's a single binary that replaces the many components of full Kubernetes. It's production-ready, CNCF-certified, and uses far less memory — important on small Hetzner instances.

**Why Terraform?** Terraform lets you define infrastructure as code. Your cluster is described in `main.tf`. Run `terraform apply` to create it, `terraform destroy` to delete it. The entire cluster is reproducible — if something breaks badly, you destroy and recreate in 5 minutes.

**Estimated cost: ~€30–35/month** (billed hourly — destroy when not using it)
- 1× control plane (CX23: 2 vCPU, 4GB) — ~€4/mo
- 3× worker nodes (CX33: 4 vCPU, 8GB each) — ~€24/mo
- 1× load balancer (LB11) — ~€6/mo

**Prerequisites** (install once):

```bash
brew install terraform packer hcloud
```

**Setup steps:**

```bash
# 1. Create Hetzner Cloud project + API token
#    https://console.hetzner.cloud → Security → API Tokens (Read & Write)

# 2. Generate SSH key for the cluster
ssh-keygen -t ed25519 -f ~/.ssh/hetzner

# 3. Export tokens (add to your .zshrc for persistence)
export HCLOUD_TOKEN="your-token-here"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"

# 4. Create MicroOS snapshots (one-time, takes ~5 minutes)
#    kube-hetzner uses OpenSUSE MicroOS as the node OS.
#    Packer creates these snapshot images in your Hetzner project.
cd terraform
curl -sL https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/packer-template/hcloud-microos-snapshots.pkr.hcl -o hcloud-microos-snapshots.pkr.hcl
packer init hcloud-microos-snapshots.pkr.hcl
packer build hcloud-microos-snapshots.pkr.hcl

# 5. Create the cluster (takes ~5 minutes)
terraform init
bb tf-plan               # preview what will be created
bb tf-apply              # create it

# 6. Get kubeconfig
bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
kubectl get nodes        # should show 4 nodes (1 control plane + 3 workers)

# 7. Tear down when done (stops billing immediately)
bb tf-destroy
```

**⚠️ Terraform state file:** `terraform/terraform.tfstate` is critical. It maps what Terraform defined to what exists in Hetzner. If you lose it, Terraform can't manage your cluster — it'll try to create duplicates and fail. The `.gitignore` keeps it out of git (it contains secrets). If you lose it: delete everything from the Hetzner Console, then `terraform apply` again.

**Bringing the cluster back up after `bb tf-destroy`:**

```bash
# 1. Set tokens
export HCLOUD_TOKEN="your-token-here"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"

# 2. Recreate (terraform init runs automatically if needed)
bb tf-apply

# 3. Get kubeconfig
bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml

# 4. Check if load balancer IP changed
kubectl get svc -A | grep traefik
# If the EXTERNAL-IP changed → update A records in your DNS provider

# 5. Recreate ClusterIssuer (not persisted across destroys)
export ACME_EMAIL=your-email@example.com
bb cluster-issuer

# 6. Deploy app
bb helm-prod

# 7. Wait for TLS certificate
kubectl get certificate --watch
# READY=True → Ctrl+C

# 8. Verify
curl https://yourdomain.com/health
```

---

## Step 7: DNS + TLS

### What TLS Actually Is

TLS (Transport Layer Security) encrypts traffic between your users' browsers and your app. Without it, anyone on the network path — the coffee shop WiFi, the ISP, any network hop — can read and modify the traffic in plain text. Passwords, API keys, personal data, all visible.

TLS works through certificates. A certificate is a file that says "I am myappk8s.net and here's proof." The proof comes from a Certificate Authority (CA) — a trusted third party that verified you own the domain. When a browser connects to your site, your server presents the certificate, the browser checks it was signed by a trusted CA, and they establish an encrypted connection.

Without a valid certificate, browsers show "Your connection is not private" warnings and many APIs refuse to connect entirely.

### What Let's Encrypt Is

Before Let's Encrypt, getting a TLS certificate meant paying $50-200/year per domain, emailing a CA, waiting days, and manually installing the certificate. Let's Encrypt changed this in 2015: free certificates, fully automated, issued in seconds.

The catch: Let's Encrypt certificates expire every 90 days (not 1-2 years like paid ones). This is intentional — it forces you to automate renewal rather than manually installing certificates and forgetting about them. This is where cert-manager comes in.

### What cert-manager Does

cert-manager is a Kubernetes operator (a program that runs inside your cluster and manages resources). It watches for Certificate requests and automatically:

1. Contacts Let's Encrypt's API
2. Proves you own the domain (via an ACME challenge — see below)
3. Receives the certificate
4. Stores it as a Kubernetes Secret
5. Renews it before it expires (at 60 days, so 30 days before expiry)

kube-hetzner installs cert-manager automatically when it creates your cluster. You don't install it yourself.

### How Domain Verification Works (ACME HTTP-01 Challenge)

Let's Encrypt needs to verify you actually own the domain before issuing a certificate. It can't just trust anyone who asks for a certificate for `google.com`. The ACME protocol (Automatic Certificate Management Environment) defines how this verification works.

The HTTP-01 challenge goes like this:

1. cert-manager asks Let's Encrypt: "I want a certificate for myappk8s.net"
2. Let's Encrypt responds: "Prove you own it. Put this random token at `http://myappk8s.net/.well-known/acme-challenge/abc123`"
3. cert-manager creates a temporary pod and Ingress rule that serves the token at that URL
4. Let's Encrypt makes an HTTP request to that URL from its servers
5. If the token is there, Let's Encrypt is satisfied: you control the domain's DNS (it points to your server) and you control the server (you served the token)
6. Let's Encrypt issues the certificate
7. cert-manager stores it as a Kubernetes Secret and cleans up the temporary pod

This is why DNS must be set up before requesting a certificate — Let's Encrypt needs to reach your server via the domain name.

### What a ClusterIssuer Is

cert-manager introduces two Kubernetes resource types: `Issuer` (works in one namespace) and `ClusterIssuer` (works across all namespaces). We use ClusterIssuer so both your app (in `default` namespace) and Grafana (in `monitoring` namespace) can use the same Let's Encrypt configuration.

The ClusterIssuer configuration tells cert-manager:
- **Which CA to use:** Let's Encrypt's production API (`acme-v02.api.letsencrypt.org`)
- **Your email:** Required by Let's Encrypt for account identification. Note: Let's Encrypt no longer sends expiry warnings to this address (see "What Can Go Wrong" below)
- **Where to store the account key:** A Kubernetes Secret called `letsencrypt-account-key` — this is your Let's Encrypt account credentials
- **How to prove domain ownership:** HTTP-01 challenges, routed through Traefik (the ingress controller)

### How It All Connects: The Chain from Domain to Certificate

```
1. You register a domain (e.g. myappk8s.net on Namecheap)
2. You create A records pointing to your Hetzner load balancer IP
3. Now: browser → DNS lookup → your load balancer → Traefik → your app

4. You create a ClusterIssuer (tells cert-manager how to talk to Let's Encrypt)
5. You deploy an Ingress with annotations:
     cert-manager.io/cluster-issuer: letsencrypt  ← "get me a certificate"
     tls:
       - secretName: myapp-tls                     ← "store it here"
         hosts: [myappk8s.net]                     ← "for this domain"

6. cert-manager sees the Ingress, requests a certificate from Let's Encrypt
7. Let's Encrypt verifies domain ownership via HTTP-01 challenge
8. Certificate is stored as a Kubernetes Secret called myapp-tls
9. Traefik reads the Secret and terminates TLS

Now: browser → HTTPS → Traefik (decrypts TLS) → HTTP → your app
Your app never sees TLS — it just serves plain HTTP on port 8080.
```

### Why the ClusterIssuer Doesn't Survive `bb tf-destroy`

The ClusterIssuer is a Kubernetes resource. When you destroy the cluster, all Kubernetes resources are deleted. The Packer snapshots and Hetzner project survive (they're outside the cluster), but everything inside the cluster — deployments, services, secrets, ClusterIssuers — is gone.

This is why the "bringing the cluster back up" steps include re-creating the ClusterIssuer. The certificate itself also needs to be re-issued (since the Secret that stored it was deleted), but cert-manager handles that automatically when you redeploy the Ingress.

### Setup Steps

**7a. Get the load balancer IP:**

```bash
kubectl get svc -A | grep traefik
# Look at the EXTERNAL-IP column
```

Traefik is the ingress controller — it's the front door to your cluster. All external traffic enters through the Hetzner load balancer, which forwards to Traefik, which routes to the right service based on the hostname in the request.

**7b. Create DNS records** at your registrar (Namecheap, Cloudflare, etc.):

| Type | Host | Value | Purpose |
|------|------|-------|---------|
| A | `@` | your load balancer IP | `myappk8s.net` → your cluster |
| A | `*` | your load balancer IP | `*.myappk8s.net` → your cluster |

The `@` record handles the root domain. The `*` wildcard handles all subdomains — `grafana.myappk8s.net`, `api.myappk8s.net`, anything. This means you can deploy new services with new subdomains without touching DNS again.

**7c. Wait for DNS propagation** (5-30 minutes):

DNS changes propagate across the internet's DNS servers. Some are fast (seconds), some cache old values. Check with:

```bash
dig yourdomain.com +short
# Should return your load balancer IP
```

If it returns nothing or the wrong IP, wait longer. Namecheap is typically 5-15 minutes. You can also try `dig @8.8.8.8 yourdomain.com +short` to check Google's DNS directly.

**7d. Create the Let's Encrypt ClusterIssuer:**

```bash
export ACME_EMAIL=your-email@example.com
bb cluster-issuer
# ✓ ClusterIssuer created (email: your-email@example.com, ingress: traefik)
```

This reads your email from `ACME_EMAIL` and the ingress class from `INGRESS_CLASS` (defaults to `traefik`). On a different cloud with nginx, you'd run `INGRESS_CLASS=nginx bb cluster-issuer`.

**7e. Deploy and verify:**

```bash
bb docker-push
bb helm-prod
```

The Helm chart's `ingress.yaml` template includes the cert-manager annotation, so deploying the Ingress automatically triggers certificate issuance.

**7f. Watch the certificate being issued:**

```bash
kubectl get certificate --watch
```

You'll see `READY: False` for 30-60 seconds while cert-manager runs the ACME challenge, then `READY: True` once the certificate is stored. Press Ctrl+C.

If it stays `False` for more than 2 minutes, check what went wrong:

```bash
kubectl describe certificate myapp-tls    # shows the certificate status
kubectl describe order -A                 # shows the ACME order status
kubectl describe challenge -A             # shows the HTTP-01 challenge status
```

Common failures: DNS not propagated yet (Let's Encrypt can't reach your server), wrong load balancer IP in DNS, or the ClusterIssuer has a typo.

**7g. Verify TLS works:**

```bash
curl https://yourdomain.com/health
# Should return: {"status":"ok"}
```

If you get `SSL certificate problem: unable to get local issuer certificate`, the certificate isn't ready yet. Wait and retry.

### The Trust Chain: Who Vouches for Your Certificate

When a browser connects to your site, it doesn't just trust your certificate blindly. It follows a chain of trust upward until it reaches a root certificate that's pre-installed in the browser's trust store.

Your certificate's chain looks like this:

```
ISRG Root X1 (root CA, pre-installed in every modern browser since 2016)
  └── RSA or ECDSA Intermediate (e.g. R10, E5 — rotated periodically)
        └── myappk8s.net (your certificate, valid 90 days)
```

**ISRG Root X1** is the root Certificate Authority, operated by the Internet Security Research Group (ISRG) — the nonprofit behind Let's Encrypt. It's been in every major browser and OS trust store since late 2016. Let's Encrypt is the world's largest certificate authority, used by over 700 million websites, so this is not a niche or experimental CA.

The root doesn't sign your certificate directly — that would be risky, because if the root's private key were compromised, every certificate in the world would be affected. Instead, the root signs intermediate certificates, and those intermediates sign your certificate. If an intermediate is compromised, only that intermediate's certificates need to be revoked, not the entire root.

ISRG is also building next-generation root certificates (ISRG Root YR and Root YE) that will eventually replace X1 and X2, but these haven't been incorporated into major trust stores yet. When they are, the transition will be transparent — cert-manager will handle it automatically.

### Automatic Certificate Renewal: What Happens Behind the Scenes

Let's Encrypt certificates are valid for 90 days. This sounds short, but it's intentional — short-lived certificates force you to automate renewal rather than manually installing certificates and forgetting about them for a year.

cert-manager handles renewal automatically. Here's the timeline for a typical certificate:

```
Day 0:   Certificate issued (valid for 90 days)
Day 1-59: Everything is fine, cert-manager does nothing
Day 60:  cert-manager triggers renewal (2/3 through the certificate's lifetime)
         → Contacts Let's Encrypt
         → Runs HTTP-01 challenge (Traefik serves the token)
         → Receives new certificate
         → Stores it in the K8s Secret
         → Traefik picks up the new certificate automatically
Day 61-90: Old certificate still valid as fallback
Day 90:  Old certificate expires (but was already replaced at day 60)
```

If the renewal at day 60 fails (Let's Encrypt is down, DNS is broken, Traefik is misconfigured), cert-manager retries with exponential backoff — 1 hour, 2 hours, 4 hours, up to 32 hours between attempts. It keeps trying until the certificate expires or the issue is resolved. This gives you 30 days of retries before the certificate actually expires.

You don't need to set up a cron job, run a renewal script, or do anything manual. As long as the cluster is running and cert-manager is healthy, certificates renew themselves.

### What Can Go Wrong (and How to Detect It)

Even with automatic renewal, things can fail silently:

- **cert-manager pod crashes or gets evicted** — if it's not running, it can't renew anything
- **DNS changes** — if your A record no longer points to the cluster, the HTTP-01 challenge fails
- **Let's Encrypt rate limits** — if you've issued too many certificates for the same domain in a short period
- **Cluster destroyed and recreated** — ClusterIssuer and certificates don't survive `bb tf-destroy`

**Important: Let's Encrypt no longer sends expiry warning emails.** As of June 2025, Let's Encrypt ended its email notification service. The email address in your ClusterIssuer will NOT receive warnings if renewal fails. You need your own monitoring.

**Check certificate status manually:**

```bash
# Quick status check
kubectl get certificate

# Detailed info including expiry date and renewal time
kubectl get certificate -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}READY={.status.conditions[0].status}{"\t"}EXPIRES={.status.notAfter}{"\t"}RENEWS={.status.renewalTime}{"\n"}{end}'
```

**Automated monitoring with Grafana:**

cert-manager exports a Prometheus metric called `certmanager_certificate_expiration_timestamp_seconds`. You can create a Grafana alert rule that fires if any certificate is less than 14 days from expiry — which means auto-renewal has been failing for at least 16 days and needs attention. This is covered in the monitoring section (Step 9).

---

## Step 8: The Full Picture

### Three Data Flows

This system has three distinct flows of data. Understanding them separately makes the whole architecture click.

**Flow 1: Deployment — how code gets to production**

```
Your laptop
  │  git push
  ▼
GitHub Actions
  │  ci.yaml: docker build (amd64) → push to GHCR
  │  cd.yaml: helm upgrade → wait for rollout → smoke test → rollback if failed
  ▼
Hetzner cluster
  │  kubelet pulls image from GHCR
  │  creates new pods with new image
  │  old pods terminated after new ones are healthy
  ▼
Live at https://yourdomain.com
```

You edit code locally, test in the REPL, push to Git. GitHub Actions builds a Docker image for the correct architecture (linux/amd64, not your Mac's ARM), pushes it to GitHub Container Registry, then tells Helm to deploy it to your Hetzner cluster. Helm creates new pods with the new image, waits for them to pass health checks, then terminates the old pods. If the new pods fail their smoke test, Helm rolls back to the previous version automatically. Your app has zero downtime during this process because K8s does a rolling update — the old pods keep serving traffic until the new ones are ready.

**Flow 2: Request — how users reach your app**

```
Browser
  │  DNS lookup: myappk8s.net → 46.225.42.154
  │  HTTPS (encrypted)
  ▼
Hetzner load balancer (LB11)
  │  TCP passthrough
  ▼
Traefik (ingress controller)
  │  Terminates TLS using certificate from cert-manager
  │  Reads Host header to pick the right Service
  │  Plain HTTP internally
  ▼
K8s Service (myapp)
  │  Load-balances across pods
  ▼
myapp pod 1  or  myapp pod 2
  │  Ring/Reitit handles the request
  │  Returns {"status":"ok"}
  ▼
Response flows back up the same path
```

The browser resolves your domain via DNS, connects to the Hetzner load balancer over HTTPS. The load balancer forwards the TCP connection to Traefik, which is the ingress controller running inside the cluster. Traefik has the TLS certificate (provisioned automatically by cert-manager from Let's Encrypt) and decrypts the traffic. It then reads the HTTP Host header to determine which K8s Service to route to, and forwards the request as plain HTTP. Your app never handles TLS — it just serves HTTP on port 8080.

The K8s Service acts as an internal load balancer, distributing requests across your two pods. If one pod is unhealthy (readiness probe fails), the Service stops sending traffic to it.

**Flow 3: Monitoring — how you see what's happening**

```
myapp pod
  ├── /metrics (iapetos)           ──→ Alloy scrapes every 15s  ──→ Mimir
  ├── stdout/stderr                ──→ Alloy reads log files    ──→ Loki
  └── OTel agent (traces)          ──→ Alloy receives OTLP      ──→ Tempo
                                                                      │
                                           Grafana queries all three ◄─┘
```

Your app produces three types of observability data, each collected differently:

Metrics are *pulled* — Alloy scrapes your app's `/metrics` endpoint every 15 seconds, parses the Prometheus text format, and writes the data points to Mimir via its remote-write API. This pull model means your app doesn't need to know where Mimir lives. It just serves `/metrics` and Alloy finds it via the `prometheus.io/scrape` pod annotation.

Logs are *collected* — Kubernetes captures stdout/stderr from every container to files on the node's filesystem. Alloy reads these files (tailing them in real-time) and ships each line to Loki with labels like namespace, pod name, and app name. Your app just uses `println`.

Traces are *pushed* — the OpenTelemetry Java agent inside your pod generates trace spans for every HTTP request, database query, and outgoing HTTP call. It pushes these spans via the OTLP protocol (gRPC on port 4317) to Alloy, which forwards them to Tempo. This push model means the agent needs to know Alloy's address (configured via environment variables in the deployment).

Grafana doesn't store any of this data. It queries Mimir (using PromQL), Loki (using LogQL), and Tempo (using TraceQL) on demand when you open a dashboard or run a query.

### Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  YOUR MACHINE (Rancher Desktop)                 │
│                                                 │
│  bb dev → REPL → edit → eval → instant feedback │
│                                                 │
│  bb helm-local → same Helm chart as prod        │
│  bb k8s-logs   → debug in real K8s locally      │
└────────────────────┬────────────────────────────┘
                     │ git push
                     ▼
┌─────────────────────────────────────────────────┐
│  GITHUB ACTIONS                                 │
│                                                 │
│  ci.yaml: build image (amd64) → push to GHCR   │
│  cd.yaml: helm deploy → smoke test → rollback   │
└────────────────────┬────────────────────────────┘
                     │ kubectl / helm
                     ▼
┌─────────────────────────────────────────────────┐
│  HETZNER (kube-hetzner k3s cluster)             │
│                                                 │
│  yourdomain.com → Traefik → TLS (Let's Encrypt) │
│  2 replicas → /health checked continuously      │
│  Grafana LGTM → metrics, logs, traces           │
└─────────────────────────────────────────────────┘
```

---

## DevOps: What It Means and How This Project Does It

### What DevOps Actually Is

DevOps isn't a tool or a job title. It's the idea that the people who write code (Dev) and the people who run it in production (Ops) should not be separate teams throwing work over a wall. Instead, you build systems where deploying, monitoring, and operating your code is as automated and reliable as writing it.

Before DevOps, deployment looked like this: developers write code and hand it to operations. Operations manually sets up servers, installs dependencies, copies files, restarts services, and crosses their fingers. When something breaks, developers say "it works on my machine" and operations says "your code is broken." Nobody wins.

DevOps replaces this with automation, shared responsibility, and fast feedback loops. You write code, push it, and a pipeline builds, tests, deploys, and monitors it — all without manual steps. If something breaks, you see it immediately in Grafana, not days later when a user complains.

### DevOps Principles in This Project

**Infrastructure as Code (IaC)** — your Hetzner cluster is defined in `terraform/main.tf`. It's not a server you configured by hand and documented in a wiki that nobody reads. You can destroy it and recreate an identical cluster in 5 minutes. If someone asks "how is our cluster configured?", the answer is in Git, not in someone's head.

**CI/CD (Continuous Integration / Continuous Delivery)** — every push to `main` triggers an automated pipeline that builds, deploys, tests, and rolls back if needed. There are no manual deployment steps, no "deploy Fridays", no "only Sarah knows how to deploy." Anyone can push code and it goes live safely.

**Immutable Infrastructure** — you don't SSH into servers to update code. You build a new Docker image, deploy it, and the old one is replaced. If the new version is bad, you roll back to the previous image. Servers are cattle, not pets — you don't name them, you don't fix them, you replace them.

**Monitoring and Observability** — the LGTM stack gives you visibility into what's running. You don't wait for users to report problems. Dashboards show you request rates, error rates, and latency in real-time. Logs let you search for specific errors. Traces show you exactly where time is being spent.

**Environment Parity** — the same Helm chart deploys to your local Rancher Desktop and to Hetzner production. The only difference is the values file. This means "it works on my machine" actually means something, because your machine runs the same Kubernetes manifests as production.

**Automated Recovery** — K8s restarts crashed pods automatically. Health probes detect stuck processes. The CD pipeline rolls back failed deployments. cert-manager renews TLS certificates before they expire. The system heals itself.

---

## GitOps: Git as the Source of Truth

### What GitOps Is

GitOps takes the DevOps principle of "infrastructure as code" to its logical conclusion: **Git is the single source of truth for everything.** Not just your application code, but your infrastructure, your deployment configuration, your monitoring setup — everything that defines what's running in production lives in a Git repository.

The core idea: the state of your production system should always match what's in Git. If you want to change something in production, you change it in Git. If production drifts from Git (someone manually edited something), the system should detect and correct it.

### How This Project Uses GitOps Principles

This project follows the **push-based GitOps** model. When you push to `main`, GitHub Actions pushes the changes to the cluster:

```
Git (source of truth)
  │
  │  push to main triggers GitHub Actions
  ▼
ci.yaml builds image → cd.yaml deploys to cluster
```

What's in Git:
- **Application code** — `src/myapp/core.clj`
- **Build definition** — `Dockerfile`, `build.clj`, `deps.edn`
- **Deployment manifests** — `helm/myapp/` (all K8s resources are templated here)
- **Infrastructure definition** — `terraform/main.tf` (the cluster itself)
- **Monitoring configuration** — `monitoring/` (every component's Helm values)
- **CI/CD pipeline** — `.github/workflows/ci.yaml` and `cd.yaml`

What's NOT in Git (deliberately):
- **Plaintext secrets** — `terraform.tfstate` (Hetzner token), `myapp_kubeconfig.yaml` (cluster credentials). These are stored as GitHub Secrets or local files excluded by `.gitignore`. Monitoring credentials (Grafana, MinIO) live in Git as encrypted Sealed Secrets under `monitoring/secrets/` — only the cluster's controller can decrypt them.
- **Runtime state** — PersistentVolumeClaims, TLS certificates, MinIO data. These are generated and managed by the cluster.

### Push-Based vs Pull-Based GitOps

There are two flavours of GitOps:

**Push-based** (what we use): an external system (GitHub Actions) pushes changes to the cluster when Git changes. The pipeline runs `helm upgrade` from outside the cluster. This is simpler to set up and understand. The trade-off: if someone manually changes something in the cluster (`kubectl edit deployment myapp`), Git won't know about it and won't correct it. The manual change persists until the next `git push` overwrites it.

**Pull-based** (ArgoCD, Flux): an agent *inside* the cluster continuously polls Git and pulls changes. If someone manually edits a deployment, the agent detects the drift and reverts it to match Git. This is the "purer" form of GitOps — the cluster is always self-correcting. The trade-off: more infrastructure to manage (ArgoCD itself is a complex system with its own UI, RBAC, and multi-cluster support).

For a personal project or small team, push-based is the right choice. You get 90% of the benefits of GitOps (automated deployment, audit trail in Git, reproducibility) without the overhead of running a GitOps controller. If you later need drift detection, multi-cluster deployment, or progressive delivery (canary releases, blue-green), that's when you'd add ArgoCD or Flux.

### The Audit Trail Benefit

One underrated benefit of GitOps: every production change has a Git commit. If something breaks after a deployment, you run `git log --oneline` and see exactly what changed. You can `git revert` a bad commit and push — the pipeline rolls back production. You don't need to remember what you changed, check Slack history, or ask "who deployed last?" The Git log is the definitive history of your production system.

### What Full GitOps Would Look Like

If you wanted to evolve this project to full pull-based GitOps:

1. Install ArgoCD in the cluster (`helm install argocd argo/argo-cd`)
2. Create an ArgoCD Application that points to your Git repo's `helm/myapp/` directory
3. Remove the `cd.yaml` workflow — ArgoCD replaces it
4. Keep `ci.yaml` — it still builds and pushes Docker images
5. ArgoCD watches Git, detects new image tags, and syncs the cluster

The CI pipeline builds the image and updates the image tag in Git. ArgoCD sees the tag change and deploys it. Nobody runs `kubectl` or `helm` against production directly — all changes flow through Git.

---

## Quick Reference: bb tasks

| Task | What it does |
|------|-------------|
| `bb dev` | Start nREPL on port 7888 |
| `bb build` | Build uberjar |
| `bb docker-build` | Build Docker image (native platform, for dev) |
| `bb docker-run` | Run image standalone |
| `bb docker-push` | Build for amd64 + push to GHCR (auto-detects GitHub user) |
| `bb helm-local` | Build + deploy to Rancher Desktop K8s + smoke test |
| `bb helm-uninstall` | Remove from local K8s |
| `bb helm-prod` | Deploy to Hetzner (auto-detects GitHub user, reads PROD_HOST) |
| `bb smoke-local` | Smoke test local K8s deployment |
| `bb smoke-prod` | Smoke test production |
| `bb k8s-status` | Show pod status |
| `bb k8s-logs` | Tail logs |
| `bb k8s-describe` | Debug pod issues (look at Events section) |
| `bb k8s-port-forward` | localhost:8080 → pod |
| `bb k8s-shell` | Shell into running pod |
| `bb tf-plan` | Preview Terraform changes |
| `bb tf-apply` | Create/update cluster (auto-inits) |
| `bb tf-destroy` | Destroy cluster (stops billing immediately) |
| `bb tf-kubeconfig` | Regenerate kubeconfig |
| `bb cluster-issuer` | Create Let's Encrypt ClusterIssuer (needs ACME_EMAIL) |
| `bb cert-status` | Show TLS certificate status and expiry |
| `bb ingress-install` | Install nginx-ingress (for clouds without Traefik) |
| `bb cert-manager-install` | Install cert-manager (for clouds without it) |
| `bb monitoring-seal-secrets` | Install Sealed Secrets controller + seal Grafana/MinIO credentials (run once per cluster, or to rotate) |
| `bb monitoring-install` | Install full LGTM stack (requires `monitoring-seal-secrets` first) |
| `bb monitoring-status` | Show monitoring pods |
| `bb monitoring-uninstall` | Remove LGTM stack |
| `bb grafana` | Port-forward Grafana → localhost:3000 |

**Environment variables needed for production commands:**

```bash
# Add these to your .zshrc
export PROD_HOST=yourdomain.com
export ACME_EMAIL=you@example.com
export HCLOUD_TOKEN="your-hetzner-token"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"
export KUBECONFIG=/path/to/myapp/myapp_kubeconfig.yaml
# export CLOUD=hetzner          # optional: for multi-cloud terraform
# export INGRESS_CLASS=traefik   # optional: defaults to traefik
```

---

## Step 9: Observability — Grafana LGTM Stack

### Why Monitoring Matters

Without monitoring, debugging looks like this: a user reports something is slow, you SSH into the server, tail logs, guess what's wrong, deploy a fix, and hope. With monitoring, you open Grafana and see: request latency spiked at 3:47am, the JVM heap was at 95%, garbage collection was running every 2 seconds, and it correlates with a spike in database query time. You fix the actual problem instead of guessing.

The three pillars of observability each answer different questions:

**Metrics** answer "how much?" and "how fast?" — request rate, error rate, latency percentiles, memory usage, CPU, queue depths. They're cheap to store (just numbers), great for dashboards and alerts, and perfect for spotting trends. "Is latency getting worse over time? Are we getting more errors than yesterday?"

**Logs** answer "what happened?" — the actual text your app printed. When you know something went wrong (from metrics), logs tell you the details. "What was the stack trace? What request caused it? What user was affected?"

**Traces** answer "where did the time go?" — a single request's journey through your system. Even with just one service, traces show you: "this request spent 200ms in Jetty, 50ms in your handler, 1.5 seconds waiting for a database query, and 100ms serializing the response." When you have multiple services, traces follow the request across all of them.

### What OpenTelemetry Is and Why It Matters

Before OpenTelemetry, every monitoring vendor had its own instrumentation library. If you used Datadog, you'd add the Datadog SDK to your app. If you switched to New Relic, you'd rip out Datadog and add New Relic. Same for Jaeger, Zipkin, Prometheus client libraries, and dozens of others. Your application code was coupled to your monitoring infrastructure.

OpenTelemetry (OTel) solves this by providing a single, vendor-neutral standard for generating metrics, logs, and traces. It's a CNCF project (the same foundation that governs Kubernetes) and has become the industry standard — every major monitoring vendor supports it. You instrument your app once with OTel, and you can send that data to any backend: Grafana/Tempo, Datadog, New Relic, Jaeger, Honeycomb, or anything else that speaks the OTLP (OpenTelemetry Protocol) format.

**The key benefit: you never rewrite instrumentation.** If you decide next year to switch from Grafana to Datadog, you change the exporter endpoint in one environment variable. Your application code stays identical. The OTel agent doesn't know or care where the data ends up.

**How OpenTelemetry works:**

OTel defines three things:

1. **An API** — the interfaces for creating spans (traces), recording metrics, and emitting logs
2. **An SDK** — the implementation that processes and exports that data
3. **The OTLP protocol** — the wire format for sending telemetry data between systems

For most languages, OTel provides auto-instrumentation — an agent or library that wraps common frameworks (HTTP servers, database drivers, HTTP clients) and generates telemetry without you writing any code. This is what we use.

### How We've Built In OTel Support

This project uses the **OpenTelemetry Java agent** — a JAR file that attaches to the JVM at startup and automatically instruments common libraries via bytecode manipulation. You write zero tracing code. The agent detects Jetty (our HTTP server), wraps its request handling, and creates a trace span for every incoming request. If you later add an HTTP client or JDBC database driver, the agent instruments those too — each outgoing call becomes a child span in the trace.

**In the Dockerfile:**

```dockerfile
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.11.0/opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar

ENTRYPOINT ["java", "-javaagent:/app/opentelemetry-javaagent.jar", "-jar", "/app/myapp.jar"]
```

The agent JAR is downloaded at build time and loaded via `-javaagent` at startup. This is the only OTel-related change to the Dockerfile. No code changes, no dependency additions to `deps.edn`.

**In the Helm deployment template:**

The agent's behaviour is controlled entirely via environment variables — this is an OTel design principle (configuration via environment, not code):

```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: myapp                    # identifies this service in traces
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://alloy.monitoring.svc:4318   # where to send data
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: http/protobuf            # OTLP over HTTP (not gRPC)
  - name: OTEL_METRICS_EXPORTER
    value: none                     # we use iapetos for metrics, not OTel
  - name: OTEL_LOGS_EXPORTER
    value: none                     # logs go to stdout → Alloy → Loki
  - name: OTEL_JAVAAGENT_ENABLED
    value: "false"                  # disabled by default
```

**Why metrics and logs exporters are set to "none":**

OTel can export all three pillars (metrics, logs, traces), but we only use it for traces. For metrics, we use iapetos (Prometheus client) because it integrates naturally with Clojure code and is scraped by Alloy via the pull model. For logs, we use `println` to stdout, which Kubernetes captures and Alloy collects. Using OTel for all three would work, but it would mean replacing iapetos with OTel metrics API calls and configuring OTel log bridging — more complexity with no practical benefit for our setup.

**Why it's disabled by default:**

The OTel agent adds 10-15 seconds to JVM startup time (it scans the classpath and instruments bytecode) and immediately tries to connect to Alloy at `alloy.monitoring.svc:4318`. If Alloy isn't running (because you haven't run `bb monitoring-install` yet), the agent logs connection errors every few seconds. These aren't fatal, but they're noisy and waste startup time.

Enable it after installing the monitoring stack:

```bash
bb monitoring-install                    # installs Alloy, Tempo, and everything else
# Edit helm/myapp/values-prod.yaml → otel.enabled: "true"
bb helm-prod                             # redeploy with tracing enabled
```

**What the agent instruments automatically:**

Without writing any code, the OTel Java agent creates trace spans for:

- Every incoming HTTP request (via Jetty instrumentation)
- Every outgoing HTTP request (via `java.net.HttpURLConnection`, Apache HttpClient, OkHttp)
- Every JDBC database query (query text, duration, database name)
- Every Redis, gRPC, Kafka, or RabbitMQ operation (if you add those later)

Each span includes: start time, duration, status code, the HTTP method and path, and a trace ID that links all spans in the same request together. In Grafana, you can search traces by any of these attributes, and click a trace ID in a log line to jump directly to the corresponding trace — Grafana links Loki and Tempo through trace IDs embedded in your logs.

**Where the data goes:**

```
OTel Java agent (in your app pod)
  → OTLP/HTTP to Alloy (port 4318)
    → Alloy forwards to Tempo
      → Grafana queries Tempo via TraceQL
```

Alloy acts as a relay — it receives spans from the OTel agent and forwards them to Tempo for storage. This is the standard OTel Collector pattern: apps push to a local collector, the collector batches and forwards to the backend. If you ever switch backends (e.g., from Tempo to Jaeger or Datadog), you change Alloy's configuration, not your app's.

**What a trace looks like in Grafana:**

When you open a trace in Grafana (Explore → Tempo), you see a waterfall diagram:

```
myapp: GET /hello                          [==========] 250ms
  └── HTTP GET /api/users (external call)  [====]       80ms
  └── JDBC SELECT * FROM users             [==]         45ms
  └── HTTP response serialization          [=]          12ms
```

This tells you exactly where the 250ms was spent: 80ms waiting for an external API, 45ms in the database, 12ms serializing, and ~113ms in Jetty overhead and your handler code. Without tracing, you'd just see "the request took 250ms" and have to guess which part was slow.

### The LGTM Stack: What Each Component Does

**Grafana** is the UI. It doesn't store anything — it queries the other components and visualizes the results. Think of it as the dashboard layer. It speaks to Mimir for metrics, Loki for logs, and Tempo for traces, all through standardized APIs. One interface for everything.

**Mimir** stores metrics. It's API-compatible with Prometheus, which means any Prometheus dashboard, alert rule, or query works with Mimir. The difference: Prometheus stores metrics locally and doesn't scale. Mimir stores them in object storage (MinIO/S3) and can scale horizontally. For a dev cluster this doesn't matter much, but it means your setup grows with you.

**Loki** stores logs. Unlike traditional log systems (Elasticsearch/ELK) that index the full text of every log line, Loki only indexes the metadata (labels like namespace, pod name, container). This makes it much cheaper to run — you search by label first, then grep through the results. The trade-off: full-text search is slower. But for most debugging, you know which service had the problem, so label-based search is fine.

**Tempo** stores traces. A trace is a tree of "spans" — each span represents one unit of work (an HTTP request, a database query, a function call). The OpenTelemetry Java agent creates these spans automatically by instrumenting Jetty, HTTP clients, and JDBC. You don't write any tracing code. Tempo stores the spans and lets you search by service name, duration, status code, etc.

**Alloy** is the collection agent. Before Alloy, you needed three separate tools: Prometheus to scrape metrics, Promtail to collect logs, and an OTel Collector to receive traces. Alloy replaces all three with one binary. It runs as a DaemonSet (one pod per node in the cluster) and:
- Scrapes `/metrics` from any pod with a `prometheus.io/scrape: "true"` annotation → sends to Mimir
- Collects stdout/stderr from every container on its node → sends to Loki
- Receives OTLP trace data from your app's OTel agent → forwards to Tempo

**MinIO** is S3-compatible object storage. Mimir and Loki need somewhere to store their data long-term. In production you'd use AWS S3 or GCS. For a dev cluster, MinIO gives you the same API running inside the cluster. Loki uses its own built-in MinIO (part of the Loki Helm chart). Mimir uses a separate standalone MinIO instance.

### How Your App Gets Instrumented (Zero to Three Pillars)

**Metrics — iapetos in core.clj:**

Your app creates a Prometheus registry with iapetos (a Clojure wrapper around the Prometheus Java client). The `wrap-metrics` middleware intercepts every HTTP request and records: how many requests, to which endpoint, with what status code, and how long they took. It also registers JVM collectors that expose heap usage, GC stats, thread counts, and class loading.

The middleware serves `/metrics` in Prometheus text format. You can see it yourself:

```bash
curl http://localhost:8080/metrics
# → http_requests_total{method="GET",path="/health",status="200"} 42
# → jvm_memory_bytes_used{area="heap"} 67108864
```

The Helm chart's deployment template adds `prometheus.io/scrape: "true"` as a pod annotation. Alloy sees this annotation and scrapes `/metrics` every 15 seconds.

**Logs — just println:**

Your app writes to stdout. That's it. Kubernetes captures stdout/stderr from every container and stores it on the node's filesystem. Alloy reads these log files and ships them to Loki with labels (namespace, pod name, container name, app name). In Grafana, you query `{namespace="default", app="myapp"}` and see your app's output.

This is why structured logging is valuable — if you print JSON (`{"level":"info","msg":"request","path":"/health","status":200}`), Loki can parse and filter on individual fields. But even plain `println` works.

**Traces — OpenTelemetry Java agent:**

The OTel Java agent creates trace spans automatically for every HTTP request, database query, and outgoing HTTP call. You write zero tracing code. See "How We've Built In OTel Support" above for the full details of how the agent is configured, what it instruments, and how to enable it.

### How Data Flows

See "Step 8: The Full Picture → Flow 3: Monitoring" for a detailed breakdown of how metrics, logs, and traces flow from your app through Alloy to Mimir, Loki, and Tempo, and how Grafana queries them.

### Components and Storage

| Component | Role | Storage | Why this storage |
|-----------|------|---------|------------------|
| MinIO (`minio-mimir`) | Object storage | Standalone PVC | Mimir needs S3-compatible storage for metric blocks |
| Mimir | Metrics | MinIO | Long-term storage that survives pod restarts |
| Loki | Logs | MinIO (built-in) | Has its own MinIO to avoid ServiceAccount conflicts with the standalone one |
| Tempo | Traces | Local filesystem | Simplest option for a dev cluster, no external dependencies |
| Alloy | Collection agent | None | Stateless DaemonSet — one pod per node, no storage needed |
| Grafana | Dashboards | PVC | Persists dashboard customizations and user sessions |

### Install Order and Why It Matters

Both Loki's built-in MinIO and our standalone MinIO use the same Helm chart, which creates a ServiceAccount called `minio-sa`. Two Helm releases can't own the same ServiceAccount — the second one fails with `ServiceAccount "minio-sa" already exists`.

The solution: install Loki first (its MinIO gets `minio-sa`), then install standalone MinIO with a custom SA name (`mimir-minio-sa`). The install script handles this automatically.

Loki is pinned to chart v6.33.0 and Tempo to v1.10.3 because newer versions have breaking configuration changes.

```bash
# One-time per cluster: install the Sealed Secrets controller and seal
# fresh random credentials for Grafana / MinIO. Save the printed
# credentials to your password manager — they are not stored in
# plaintext anywhere else, and the script overwrites them on rerun.
bb monitoring-seal-secrets

# Commit the encrypted SealedSecret YAMLs (safe — only your cluster
# can decrypt them).
git add monitoring/secrets/ && git commit -m "Seal monitoring credentials"

bb monitoring-install
# Takes ~5 minutes, installs 6 Helm releases into "monitoring" namespace

bb monitoring-status          # verify all pods are running
bb grafana                    # port-forward → http://localhost:3000
#                               Login with the credentials from your
#                               password manager.
```

### Using Grafana: A Quick Tour

After `bb grafana`, open `http://localhost:3000` and log in with the credentials you saved from `bb monitoring-seal-secrets` (or reset them with `kubectl exec -n monitoring deploy/grafana -- grafana-cli admin reset-admin-password '<new>'`).

**Explore → Loki** — log search. Enter `{namespace="default"}` to see all logs from your app's namespace. Add filters: `{namespace="default", app="myapp"} |= "error"` finds log lines containing "error". The query language is LogQL.

**Explore → Mimir** — metrics search. Type `http_requests_total` to see request counts. Use PromQL for more complex queries: `rate(http_requests_total[5m])` shows requests per second averaged over 5 minutes. `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))` shows p99 latency.

**Explore → Tempo** — trace search. Search by service name to find traces. Click a trace to see the waterfall view — every span (HTTP handler, database query, etc.) shown as a horizontal bar with its duration. This is where you find out why a specific request was slow.

**Dashboards** — pre-installed dashboards for JVM metrics (heap, GC, threads) and Kubernetes cluster overview (CPU, memory, pod counts per node). These are community dashboards from Grafana's dashboard registry.

**Enabling tracing in production:**

```bash
# Edit helm/myapp/values-prod.yaml → otel.enabled: "true"
bb helm-prod
```

**Accessing Grafana:**
Grafana ingress is disabled by default. Access via port-forward:

```bash
bb grafana
# → http://localhost:3000
```

**Monitoring TLS certificate renewal:**

Since Let's Encrypt no longer sends expiry emails (see Step 7), you need your own monitoring. cert-manager exports a Prometheus metric that Alloy scrapes automatically. Query it in Grafana:

```promql
# Seconds until certificate expires
certmanager_certificate_expiration_timestamp_seconds - time()

# Alert: certificate expires in less than 14 days (renewal has been failing)
certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 24 * 3600
```

To set up a Grafana alert: go to **Alerting → Alert rules → New alert rule**, use the PromQL expression above, set the threshold to fire when the value drops below `1209600` (14 days in seconds). Configure a notification channel (email, Slack, PagerDuty) to receive the alert.

If this alert fires, it means cert-manager has been failing to renew for at least 16 days (it normally renews at day 60 of a 90-day certificate). You still have 14 days to fix it before the certificate actually expires.

Quick manual check from the command line:

```bash
kubectl get certificate
# READY should be True, and the AGE tells you when it was last issued
```

**Rotating credentials:**

Grafana and MinIO credentials are no longer in the values files — they are stored in Sealed Secrets at `monitoring/secrets/`. To rotate:

```bash
bb monitoring-seal-secrets        # generates new passwords + reseals
git add monitoring/secrets/ && git commit -m "Rotate monitoring creds"

# Restart pods so they pick up the new values
kubectl rollout restart -n monitoring deploy/grafana deploy/mimir
kubectl rollout restart -n monitoring statefulset/minio-mimir

# Reset Grafana's admin password (it caches the user in its own DB):
kubectl exec -n monitoring deploy/grafana -- \
  grafana-cli admin reset-admin-password '<new-password-from-step-1>'
```

Mimir reads the same MinIO credentials via env vars (`global.extraEnvFrom`) and the `-config.expand-env=true` flag, so they always stay in sync — no manual matching required.

### How Alerting Works: From Dashboards to Notifications

Dashboards are great for investigating problems you already know about. But you can't stare at dashboards all day. Alerting is what wakes you up at 2am when something breaks.

Grafana's alerting system has four components:

**Alert rules** define the conditions. An alert rule is a PromQL or LogQL query with a threshold. For example: "fire if the error rate exceeds 5% for more than 5 minutes" or "fire if any TLS certificate expires in less than 14 days." Rules are evaluated on a schedule (every 1 minute by default).

**Contact points** define where notifications go. Grafana supports many channels out of the box: email (via SMTP), Slack (via webhook URL), PagerDuty (via integration key), Microsoft Teams (via webhook), Discord, Opsgenie, Telegram, and generic webhooks (for anything with an HTTP API). You can configure multiple contact points and use different ones for different alert severities.

**Notification policies** define the routing logic. They connect alert rules to contact points based on labels. For example: alerts with `severity=critical` go to PagerDuty (pages the on-call engineer), alerts with `severity=warning` go to a Slack channel (the team checks when they have time), and alerts with `severity=info` go to email (daily digest). Policies also control grouping (batch related alerts into one notification) and repeat intervals (don't page someone every minute for the same problem).

**Silences** suppress notifications during planned maintenance. You're upgrading the database and expect a 5-minute outage? Create a silence for the database alerts so nobody gets paged for a known event.

**Setting up a practical alert:**

1. In Grafana, go to **Alerting → Contact points → New contact point**
2. Choose your channel type (e.g. Slack) and enter the webhook URL
3. Click **Test** to verify it works — you should see a test message in your Slack channel
4. Go to **Alerting → Alert rules → New alert rule**
5. Write the query (e.g. `rate(http_requests_total{status=~"5.."}[5m]) > 0.05`)
6. Set the condition: "is above 0.05" (5% error rate)
7. Set the evaluation interval: every 1 minute, for 5 minutes (avoids false positives from brief spikes)
8. Under **Notifications**, select your contact point
9. Save

When the error rate exceeds 5% for 5 consecutive minutes, Grafana sends a notification to your Slack channel with the alert name, current value, and a link to the relevant dashboard. When the error rate drops back below the threshold, Grafana sends a "resolved" notification.

**Recommended alerts for this project:**

| Alert | Query | Threshold | Channel |
|-------|-------|-----------|---------|
| High error rate | `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])` | > 0.05 for 5m | Slack / PagerDuty |
| High latency | `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))` | > 2s for 5m | Slack |
| Pod restarts | `increase(kube_pod_container_status_restarts_total{namespace="default"}[1h])` | > 3 | Slack |
| TLS cert expiry | `certmanager_certificate_expiration_timestamp_seconds - time()` | < 14 days | Email / PagerDuty |
| Node disk full | `kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes` | < 0.1 for 10m | Slack |

### Switching Monitoring Backends

Because this project uses OpenTelemetry for traces and Prometheus-format metrics, switching to a different monitoring backend is straightforward. Your application code and Dockerfile don't change. The OTel agent and iapetos produce standard formats — you only change where the data is sent.

**Switching to Datadog:**

Datadog accepts OTLP data directly via the Datadog Agent. The migration:

1. Install the Datadog Agent in your cluster (via Helm chart `datadog/datadog`)
2. Point the OTel agent at the Datadog Agent's OTLP endpoint instead of Alloy:
   ```yaml
   # In values-prod.yaml, change:
   otel:
     endpoint: "http://datadog-agent.datadog.svc:4318"
   ```
3. The Datadog Agent also scrapes Prometheus `/metrics` endpoints, so your iapetos metrics flow to Datadog without changes
4. Datadog collects logs from stdout automatically via the Datadog Agent's Kubernetes log collection
5. Uninstall the LGTM stack (`bb monitoring-uninstall`) — Datadog replaces all of it

What you get: Datadog's dashboards, APM, log management, alerting, and anomaly detection — all managed by Datadog (no Mimir, Loki, Tempo, or MinIO to maintain). What it costs: Datadog charges per host, per million log events, and per million trace spans — typically $30-100+/host/mo depending on features.

**Switching to Azure Monitor (for AKS deployments):**

Azure Monitor integrates natively with AKS. The migration:

1. Enable Azure Monitor Container Insights when creating the AKS cluster (one Terraform flag: `oms_agent { enabled = true }`)
2. Azure Monitor automatically collects logs from stdout and Kubernetes metrics — no agent to install
3. For traces, configure the OTel agent to send to Azure Monitor's OTLP endpoint via the Azure Monitor OpenTelemetry exporter, or use Application Insights (Azure's APM)
4. For Prometheus metrics, AKS supports Azure Monitor managed Prometheus — it scrapes `/metrics` endpoints like Alloy does
5. Uninstall the LGTM stack

What you get: Azure Monitor dashboards, Log Analytics workspace (KQL queries instead of LogQL), Application Insights for traces, Azure Alerts for notifications. Integrated with Azure AD for access control. What it costs: Pay-per-GB for logs, pay-per-million for metrics samples — costs vary by volume.

**Switching to AWS CloudWatch + X-Ray (for EKS deployments):**

AWS has several monitoring services that together replace the LGTM stack:

1. Install the AWS Distro for OpenTelemetry (ADOT) collector in your cluster — it's AWS's OTel Collector distribution
2. ADOT receives OTLP traces from your OTel agent and sends them to AWS X-Ray (replaces Tempo)
3. For metrics, ADOT scrapes Prometheus `/metrics` endpoints and sends to Amazon Managed Prometheus (replaces Mimir), or CloudWatch Metrics
4. For logs, install Fluent Bit (AWS's preferred log collector) which ships stdout to CloudWatch Logs (replaces Loki)
5. Use Amazon Managed Grafana for dashboards (it's Grafana, managed by AWS) or CloudWatch dashboards
6. Uninstall the LGTM stack

What you get: Fully managed services, deep AWS integration (IAM, CloudWatch Alarms, SNS notifications), X-Ray service map. What it costs: Pay-per-use for each service — CloudWatch Logs ($0.50/GB ingested), X-Ray ($5/million traces), Managed Prometheus ($0.90/10K metric samples).

**What stays the same in every switch:**

| Component | Changes? | Why |
|-----------|----------|-----|
| `src/myapp/core.clj` | No | Application code is backend-agnostic |
| `Dockerfile` | No | OTel agent JAR is the same everywhere |
| iapetos `/metrics` endpoint | No | Prometheus format is the universal standard |
| OTel Java agent | No | OTLP is the universal trace format |
| Helm chart templates | No | Only values files change |
| `values-prod.yaml` | Yes | `otel.endpoint` changes to point at new collector |
| Monitoring Helm charts | Yes | Replace LGTM charts with new backend's agent/collector |

The key takeaway: because we use OpenTelemetry and Prometheus-format metrics (both open standards), switching backends is a configuration change, not a code change. This is exactly the vendor-neutrality that OTel was designed to provide.

---

## Extending to Multiple Environments: Dev, Test, UAT, Production

### Why You'd Want Separate Environments

Right now, this project has two environments: your laptop (local K8s via Rancher Desktop) and production (Hetzner). Code goes from your editor to the REPL to `git push` to production. This works for a solo developer or a small team, but it breaks down as the team and the stakes grow.

Imagine you're on a team of 10 developers. Three people push code on the same day. One change breaks the payment flow. In the current setup, that broken code is already in production — real users see it, and you're rolling back under pressure. The smoke test might catch a crash, but it won't catch a subtle logic bug in how order totals are calculated.

Separate environments create a series of gates between code and production. Each gate catches a different class of problem:

**Dev** — does my code work with everyone else's code? Individual developers test in the REPL, but Dev is the first place where all the branches merge together. Integration bugs show up here: your change works alone, but conflicts with something a colleague merged yesterday.

**Test** — does the system behave correctly? QA runs automated test suites and manual exploratory testing here. This is where you catch functional bugs — the feature works, but it doesn't match the acceptance criteria. The data in Test is synthetic (fake users, fake orders) so testers can do destructive things without consequences.

**UAT (User Acceptance Testing)** — do the stakeholders approve? Business analysts, product owners, or actual users verify that the feature does what was requested. This environment often has production-like data (anonymised copies) so people can test with realistic scenarios. This is the last gate before production.

**Production** — real users, real data, real money. By the time code reaches here, it's been through three environments and multiple people have verified it works.

### What Changes in the Project

Extending this project to four environments affects Helm, Terraform, CI/CD, and Git workflow. Here's what each layer looks like.

### Helm: One Chart, Four Values Files

The Helm chart doesn't change. The templates stay the same. You add more values files:

```
helm/myapp/
├── values.yaml            ← defaults
├── values-local.yaml      ← your laptop (Rancher Desktop)
├── values-dev.yaml        ← shared dev cluster
├── values-test.yaml       ← QA/testing
├── values-uat.yaml        ← user acceptance testing
└── values-prod.yaml       ← production
```

Each values file configures what's different per environment:

| Setting | Dev | Test | UAT | Prod |
|---------|-----|------|-----|------|
| Replicas | 1 | 1 | 2 | 2+ |
| Ingress host | dev.myappk8s.net | test.myappk8s.net | uat.myappk8s.net | myappk8s.net |
| Log level | DEBUG | INFO | INFO | WARN |
| Database | dev-db | test-db | uat-db (prod copy) | prod-db |
| TLS | yes | yes | yes | yes |
| OTel tracing | on | on | on | on |
| Resource limits | low | low | medium | high |

The values files also point to different database connection strings, API keys, and feature flags. In a real setup, sensitive values would come from a secrets manager (like Vault) rather than being hardcoded in the values files.

This is the beauty of Helm's design — the same templates produce the right configuration for every environment. Adding a new environment is just adding a new values file.

### Terraform: Cluster-per-Environment vs Namespace-per-Environment

There are two approaches to isolating environments, each with trade-offs:

**Option A: Separate namespaces in one cluster**

```
Single Hetzner cluster
  ├── namespace: dev        ← dev deployment
  ├── namespace: test       ← test deployment
  ├── namespace: uat        ← UAT deployment
  ├── namespace: prod       ← production deployment
  └── namespace: monitoring ← shared Grafana/LGTM stack
```

Cheaper (~€30/mo total). Simpler to manage. But environments share CPU, memory, and network — a runaway process in Dev could starve Prod. Namespace-level resource quotas mitigate this but don't eliminate it. Suitable for small teams where the risk is acceptable.

The Helm install commands would look like:

```bash
helm upgrade --install myapp ./helm/myapp -f values-dev.yaml  -n dev
helm upgrade --install myapp ./helm/myapp -f values-test.yaml -n test
helm upgrade --install myapp ./helm/myapp -f values-uat.yaml  -n uat
helm upgrade --install myapp ./helm/myapp -f values-prod.yaml -n prod
```

**Option B: Separate clusters per environment**

```
terraform/
├── environments/
│   ├── dev/
│   │   └── main.tf        ← small cluster (1 control + 1 worker)
│   ├── test/
│   │   └── main.tf        ← small cluster (1 control + 1 worker)
│   ├── uat/
│   │   └── main.tf        ← medium cluster (1 control + 2 workers)
│   └── prod/
│       └── main.tf        ← full cluster (1 control + 3 workers)
```

More expensive (~€15-30/mo per environment). More infrastructure to manage. But complete isolation — Dev cannot affect Prod, different clusters can have different K8s versions, and you can destroy Dev without touching anything else. This is what larger teams and regulated industries use.

You could also use a hybrid: Dev and Test share a cluster (with namespaces), UAT and Prod each get their own. This balances cost with isolation where it matters most.

**Terraform workspaces** are another option — one `main.tf` with different variable files per environment. But for clusters with genuinely different specs (Dev is 1 worker, Prod is 3), separate directories are clearer.

### CI/CD: Pipeline Stages and Promotion

The current CI/CD pipeline has two steps: build and deploy to prod. With multiple environments, the pipeline becomes a promotion chain:

```
git push to main
  ↓
CI: Build image → push to GHCR (tagged with commit SHA)
  ↓
CD Stage 1: Deploy to Dev → automated tests → pass?
  ↓ (automatic)
CD Stage 2: Deploy to Test → QA test suite → pass?
  ↓ (manual approval)
CD Stage 3: Deploy to UAT → stakeholder signs off
  ↓ (manual approval)
CD Stage 4: Deploy to Prod → smoke test → rollback if failed
```

The first two promotions (Dev → Test) can be automatic — if the tests pass, the same image is deployed to the next environment. The later promotions (Test → UAT → Prod) require manual approval — a human clicks "approve" in the GitHub Actions UI after verifying the environment looks good.

The critical principle: **the same Docker image moves through all environments.** You don't rebuild the image for each stage. The image tagged `sha-abc123` that was tested in Dev is the exact same image that deploys to Prod. This eliminates "it worked in Test but broke in Prod" caused by different build artifacts.

The CI/CD files would evolve:

```
.github/workflows/
├── ci.yaml              ← build + push (unchanged)
├── deploy-dev.yaml      ← auto-deploy to Dev after CI
├── deploy-test.yaml     ← auto-deploy to Test after Dev tests pass
├── deploy-uat.yaml      ← manual trigger, deploys to UAT
└── deploy-prod.yaml     ← manual trigger, deploys to Prod
```

Each deploy workflow uses the same Helm chart but a different values file and kubeconfig:

```yaml
# deploy-test.yaml (simplified)
steps:
  - name: Deploy to Test
    run: |
      helm upgrade --install myapp ./helm/myapp \
        -f ./helm/myapp/values-test.yaml \
        --set image.tag=${{ github.sha }}
```

### Git Workflow: Branches, Pull Requests, and Release Management

With multiple environments, you need a branching strategy. Here's a practical one for a team of 5-15 developers:

**Trunk-based development with feature branches:**

```
main (always deployable)
  ├── feature/add-payment-endpoint    ← developer works here
  ├── feature/fix-order-total         ← another developer
  └── feature/upgrade-database-driver ← another developer
```

1. Developer creates a feature branch from `main`
2. Developer works in the REPL (Workflow 1), tests locally with `bb helm-local` (Workflow 2)
3. Developer opens a Pull Request → CI builds the image (catches build failures)
4. Code review from a colleague
5. PR is merged to `main`
6. Merge triggers the promotion chain: Dev → Test → UAT → Prod

**For hotfixes (urgent production patches):**

```
main
  └── hotfix/fix-payment-crash      ← created from main, fast-tracked
```

1. Developer creates a hotfix branch from `main`
2. Minimal change, focused fix
3. PR opened, reviewed quickly (one reviewer, not the full team)
4. Merged to `main`
5. Promotion chain runs, but UAT approval can be expedited or skipped for critical fixes
6. The hotfix deploys to Prod within minutes to hours, not days

**For large features (multi-week work):**

Large features use feature flags instead of long-lived branches. The code is merged to `main` behind a flag that's off in production. The feature goes through Dev → Test → UAT with the flag on. When stakeholders approve, the flag is turned on in Prod — no deployment needed, just a configuration change. This avoids merge conflicts that plague long-lived branches.

### What the Flow to Production Looks Like for a Team

Here's a day in the life of a 10-person team:

**Morning:**

- Alice finishes a feature, opens a PR. CI builds. Bob reviews. PR is merged to `main`.
- The image auto-deploys to Dev. Automated integration tests run. They pass.
- The image auto-deploys to Test. The QA engineer runs the test suite.

**Afternoon:**

- QA finds a bug in Alice's feature in Test. She fixes it, pushes a new commit.
- New image builds, auto-deploys to Dev and Test. QA re-tests. It passes.
- Meanwhile, Charlie's PR is also merged. His image goes through Dev and Test independently.
- QA approves both. Product owner clicks "deploy to UAT" in GitHub Actions.

**Next day:**

- Product owner tests in UAT with realistic data. Approves Alice's feature. Charlie's feature needs a small wording change — sent back.
- Alice's feature is approved for production. Release manager clicks "deploy to Prod."
- Smoke test passes. The feature is live. Grafana dashboards show no increase in errors or latency.
- Charlie fixes the wording, pushes, goes through the pipeline again.

**Hotfix scenario (can happen any time):**

- 3pm: Grafana alert fires — error rate spiked 10x in the last 5 minutes.
- Developer checks Loki logs: `NullPointerException in PaymentHandler.processRefund`
- Developer creates hotfix branch, fixes the null check, opens PR.
- One reviewer approves immediately. PR merged.
- Image deploys to Dev → Test (automated tests pass) → Prod (UAT skipped for critical fix).
- 3:45pm: Fix is live. Error rate returns to normal. Total downtime: ~45 minutes.

### A Realistic Path from Where You Are Now

You don't need to build all four environments at once. Evolve gradually:

**Phase 1 (where you are now):** Local + Production. Solo developer. Fine for learning and personal projects.

**Phase 2: Add a staging namespace.** Before adding full environments, add a single `staging` namespace in your existing cluster. Deploy to staging before prod. This gives you one gate with minimal infrastructure cost.

```bash
# Add values-staging.yaml
helm upgrade --install myapp ./helm/myapp -f values-staging.yaml -n staging
# Test it, then deploy to prod
helm upgrade --install myapp ./helm/myapp -f values-prod.yaml -n prod
```

**Phase 3: Add automated testing.** Write a basic test suite (even just a few HTTP endpoint tests) that runs against the staging deployment. Wire it into CI/CD — deploy to staging, run tests, deploy to prod if they pass.

**Phase 4: Separate Dev and Test namespaces.** When you have 2-3 developers, split staging into Dev (always latest `main`) and Test (QA-controlled). Add manual approval gates in the pipeline.

**Phase 5: UAT and cluster separation.** When you have stakeholders who need to approve features, add UAT. When isolation becomes important (regulated industry, data sensitivity, performance testing), move to separate clusters per environment.

Each phase is a natural response to a real problem — you add complexity only when the current setup isn't sufficient. Don't build four environments for a solo project. Do build them when "it worked on my machine" isn't good enough anymore.

---

## Infrastructure Agnosticism: Running Anywhere Kubernetes Runs

### Why This Matters

Right now, this project runs on Hetzner. Hetzner is great — cheap, fast, European. But what if you need to move? Maybe your company's compliance team requires AWS. Maybe a client demands Azure. Maybe you want multi-cloud for resilience. Maybe Hetzner doubles their prices.

If your application is tightly coupled to one cloud provider, moving is a rewrite. If your application runs on Kubernetes and your cloud-specific code is isolated in one directory, moving is a configuration change.

This section maps exactly what's portable today, what's cloud-specific, and what you'd need to change to deploy on AWS, Azure, GCP, Alibaba Cloud, Exoscale, or any provider that supports Kubernetes and Terraform.

### What's Already Cloud-Agnostic (You Don't Touch These)

The good news: most of the project is already portable. These layers are pure Kubernetes — they don't know or care which cloud they're running on:

**Application code** — `src/myapp/core.clj`. A Clojure Ring app that serves HTTP. It runs identically on any JVM, in any container, on any cloud.

**Dockerfile** — builds a standard OCI container image. Docker images are the universal packaging format. Every cloud provider, every Kubernetes distribution, every container runtime runs them identically.

**Helm chart** — `helm/myapp/templates/`. The Deployment, Service, and Ingress templates use standard Kubernetes APIs. A Deployment is a Deployment whether it's on Hetzner, AWS, or a Raspberry Pi. The only cloud-sensitive parts are in the values files, not the templates (more on this below).

**CI workflow** — `.github/workflows/ci.yaml`. Builds a Docker image and pushes to GHCR. This doesn't interact with any cloud provider. The image it produces runs anywhere.

**Monitoring stack** — `monitoring/`. Grafana, Loki, Mimir, Tempo, Alloy are all Kubernetes-native Helm charts. They use PersistentVolumeClaims for storage, which Kubernetes abstracts — the monitoring stack doesn't know if the volume is a Hetzner Cloud Volume, an AWS EBS disk, or an Azure Managed Disk.

**Application logic in bb.edn** — `bb dev`, `bb build`, `bb docker-build`, `bb docker-push`, `bb helm-local`, all K8s operation tasks. These don't reference Hetzner.

### What's Cloud-Specific (This Is What Changes)

The cloud-specific code is concentrated in a small number of files. This is by design — Terraform is the abstraction layer for infrastructure, and Helm values are the abstraction layer for deployment configuration.

**1. Terraform — `terraform/main.tf`**

This is the most cloud-specific file. It uses the `hcloud` provider and the `kube-hetzner` module. Every cloud provider has its own Terraform provider and its own way of creating a Kubernetes cluster:

| Cloud | Terraform provider | K8s service | Module/resource |
|-------|-------------------|-------------|-----------------|
| Hetzner | `hetznercloud/hcloud` | k3s (self-managed) | `kube-hetzner/kube-hetzner/hcloud` |
| AWS | `hashicorp/aws` | EKS (managed) | `terraform-aws-modules/eks/aws` |
| Azure | `hashicorp/azurerm` | AKS (managed) | `Azure/aks/azurerm` |
| GCP | `hashicorp/google` | GKE (managed) | `terraform-google-modules/kubernetes-engine/google` |
| Alibaba | `aliyun/alicloud` | ACK (managed) | `alibaba/China` community modules |
| Exoscale | `exoscale/exoscale` | SKS (managed) | `exoscale_sks_cluster` resource |

To move to a different cloud, you'd replace `main.tf` entirely. You don't modify it — you write a new one. The structure of the new file is different (different resources, different parameters, different naming), but the output is the same: a Kubernetes cluster with a kubeconfig file.

A recommended project structure for multi-cloud:

```
terraform/
├── hetzner/
│   └── main.tf          ← current setup (kube-hetzner, k3s)
├── aws/
│   └── main.tf          ← EKS cluster + VPC + node groups
├── azure/
│   └── main.tf          ← AKS cluster + resource group
└── gcp/
    └── main.tf          ← GKE cluster + VPC
```

Each directory is self-contained with its own state file. You run `terraform apply` in the directory for whichever cloud you're deploying to.

**2. Helm values — ingress class and annotations**

Different Kubernetes distributions ship different ingress controllers:

| Distribution | Default ingress controller | Ingress class |
|-------------|---------------------------|---------------|
| k3s (Hetzner) | Traefik | `traefik` |
| EKS (AWS) | AWS ALB Ingress Controller | `alb` |
| AKS (Azure) | NGINX | `nginx` |
| GKE (GCP) | GCE Ingress | `gce` |

Your ClusterIssuer references `class: traefik` for HTTP-01 challenges. On AWS, that becomes `class: alb` or `class: nginx`. Your ingress template may need cloud-specific annotations — for example, AWS ALB requires:

```yaml
annotations:
  kubernetes.io/ingress.class: alb
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
```

The solution: put cloud-specific annotations in the values file, not the template. The template reads `{{ .Values.ingress.annotations }}` and each cloud's values file provides the right ones.

**3. Helm values — storage classes**

Each cloud provider names its storage classes differently:

| Cloud | Default storage class | What it provisions |
|-------|----------------------|-------------------|
| Hetzner (k3s) | `hcloud-volumes` | Hetzner Cloud Volume |
| AWS (EKS) | `gp2` or `gp3` | EBS volume |
| Azure (AKS) | `managed-premium` | Azure Managed Disk |
| GCP (GKE) | `standard` | Persistent Disk |

The monitoring stack's PersistentVolumeClaims use the cluster's default storage class, so this usually works automatically. If not, you'd set `storageClassName` in the monitoring values files.

**4. CD workflow — kubeconfig and authentication**

The CD pipeline (`cd.yaml`) authenticates to the cluster using a kubeconfig stored as a GitHub Secret. This works for any cloud — you just store a different kubeconfig. But managed Kubernetes services often use cloud-specific authentication:

| Cloud | Authentication method |
|-------|----------------------|
| Hetzner (k3s) | Static kubeconfig (certificate-based) |
| AWS (EKS) | `aws-cli` + IAM role + `aws eks get-token` |
| Azure (AKS) | `az aks get-credentials` + Azure AD |
| GCP (GKE) | `gcloud container clusters get-credentials` |

For AWS, the CD workflow would need an extra step:

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: eu-west-1

- name: Update kubeconfig
  run: aws eks update-kubeconfig --name myapp-cluster
```

Each cloud has its own GitHub Action for authentication. The Helm commands that follow are identical.

**5. DNS and TLS**

DNS records are provider-independent — you point A records at an IP or CNAME at a hostname. The load balancer IP comes from whatever cloud you're using. cert-manager and Let's Encrypt work identically on every cloud — the HTTP-01 challenge doesn't care which cloud serves the response. The only difference is the ingress class in the ClusterIssuer's solver configuration.

**6. bb.edn — Terraform tasks**

The `bb tf-apply`, `bb tf-destroy`, and `bb tf-kubeconfig` tasks reference `terraform/` as the working directory. For multi-cloud, you'd parameterise this:

```clojure
;; Read CLOUD env var, default to hetzner
-cloud-dir
{:task (str "terraform/" (or (System/getenv "CLOUD") "hetzner"))}
```

Then `CLOUD=aws bb tf-apply` would run Terraform in `terraform/aws/`.

### Preparing for Portability: A Checklist

If you want to be ready to move clouds with minimal effort, follow these principles:

**1. Never use cloud-specific APIs in your application code.** Your Clojure app should not import AWS SDKs, Azure SDKs, or Hetzner SDKs. If you need object storage, use an S3-compatible API (MinIO, AWS S3, GCS with S3 compatibility, Azure Blob with S3 gateway). If you need a message queue, use a Kubernetes-native solution (NATS, RabbitMQ) rather than SQS or Azure Service Bus.

**2. Use environment variables for all external service endpoints.** Database connection strings, API endpoints, storage URLs — all should come from environment variables set in Helm values, not hardcoded. When you move clouds, you change the values file, not the code.

**3. Keep Terraform isolated.** Terraform files should be in their own directory, separate from application code. They should output exactly one thing the rest of the system needs: a kubeconfig. Everything else (Helm, CI/CD, monitoring) consumes the kubeconfig and doesn't know which cloud produced it.

**4. Keep Helm templates cloud-agnostic.** Cloud-specific settings (ingress annotations, storage classes, load balancer types) go in values files. Templates use `{{ .Values.xyz }}` and never hardcode cloud-specific values.

**5. Use standard Kubernetes APIs.** Stick to `apps/v1`, `networking.k8s.io/v1`, `policy/v1`. Avoid cloud-specific custom resources (AWS TargetGroupBinding, Azure IngressRoute) unless you genuinely need them.

**6. Container registry should be independent.** GHCR works from any cloud. If you used AWS ECR, your images would only be efficiently pullable from AWS. GHCR (or Docker Hub, or a self-hosted registry) is cloud-neutral.

### What a Cloud Migration Actually Looks Like

If you needed to move from Hetzner to AWS tomorrow, here's the concrete work:

```
Time estimate: 1-2 days

1. Write terraform/aws/main.tf (EKS cluster + VPC + node groups)    ~4 hours
2. Run terraform apply, get kubeconfig                               ~15 minutes
3. Install nginx-ingress (EKS doesn't ship with Traefik)             ~10 minutes
4. Create values-prod-aws.yaml with:                                 ~30 minutes
   - ingress class: nginx (instead of traefik)
   - AWS-specific ingress annotations
   - storage class if needed
5. Update ClusterIssuer solver to use nginx instead of traefik        ~5 minutes
6. Update GitHub Secrets (new kubeconfig, AWS credentials)            ~10 minutes
7. Update CD workflow with AWS authentication step                    ~20 minutes
8. Update DNS A records to point to new AWS load balancer             ~5 minutes
9. Run bb monitoring-seal-secrets (new cluster ⇒ new sealing key)    ~2 minutes
10. Run bb monitoring-install                                         ~5 minutes
11. Deploy: git push                                                  ~5 minutes
12. Verify: curl https://myappk8s.net/health                         ~1 minute
```

Your Clojure code doesn't change. Your Dockerfile doesn't change. Your Helm templates don't change. Your CI workflow doesn't change. Your monitoring values files might need minor storage class adjustments. The bulk of the work is writing the Terraform config for the new cloud and adjusting authentication.

### The Cost of Full Abstraction

There's a spectrum between "fully cloud-specific" and "fully cloud-agnostic":

**Fully cloud-specific** — you use AWS Lambda, DynamoDB, SQS, CloudFront, S3, and IAM directly. Migration means rewriting everything. But you get deep integration, managed services, and less infrastructure to maintain.

**Fully cloud-agnostic** — you use only standard Kubernetes APIs, self-hosted databases, S3-compatible storage, and no cloud-specific managed services. Migration is a Terraform swap. But you manage more infrastructure yourself (databases, caches, queues).

**This project sits in a good middle ground.** The application and deployment pipeline are fully portable. The infrastructure layer (Terraform) is cloud-specific but isolated. You could add cloud-managed databases (RDS, Cloud SQL) later — just connect via environment variables, and document that a cloud migration would need to provision equivalent databases on the target cloud.

The key principle: make the cloud-specific surface area as small and as isolated as possible. Right now, it's essentially one file (`main.tf`) and a few values in Helm. That's a good place to be.

### Portability Tasks in bb.edn

Two components that kube-hetzner installs automatically but managed Kubernetes services (EKS, AKS, GKE) do not: an ingress controller and cert-manager. To make migration easier, we added two `bb` tasks:

```bash
bb ingress-install       # installs nginx-ingress controller (for clouds without Traefik)
bb cert-manager-install  # installs cert-manager (for clouds without it pre-installed)
```

You don't need these on Hetzner (kube-hetzner handles it) or Civo (ships Traefik). You do need them on AWS, Azure, and GCP. The existing `bb cluster-issuer` task supports configurable ingress class via `INGRESS_CLASS` env var — for clouds using nginx, run `INGRESS_CLASS=nginx bb cluster-issuer`.

---

## Deploying to AWS (EKS)

*The following cloud guides provide Terraform configs, setup steps, cost estimates, and CI/CD changes. Your Clojure code, Dockerfile, and Helm templates don't change — only the Terraform config and a few values differ.*

AWS EKS is a fully managed Kubernetes service. AWS runs the control plane — you don't manage master nodes. You only manage worker nodes (via managed node groups). This is simpler operationally but more complex to set up because EKS requires a VPC, subnets, IAM roles, and security groups.

EKS does not ship with an ingress controller or cert-manager. You install both yourself.

### Prerequisites

```bash
brew install awscli
aws configure          # enter your AWS Access Key ID and Secret Access Key
```

### Terraform Configuration

Create `terraform/aws/main.tf`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"        # Ireland
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "myapp-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true

  # Tags required for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  cluster_name    = "myapp"
  cluster_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    workers = {
      instance_types = ["t3.medium"]     # 2 vCPU, 4GB (~$30/mo each)
      min_size       = 2
      max_size       = 4
      desired_size   = 3
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = "eu-west-1"
}
```

### Setup Steps

```bash
# 1. Provision cluster (~10 minutes)
CLOUD=aws bb tf-apply

# 2. Get kubeconfig (EKS uses AWS CLI, not terraform output)
aws eks --region eu-west-1 update-kubeconfig --name myapp

# 3. Install ingress controller + cert-manager (EKS doesn't include these)
bb ingress-install
bb cert-manager-install

# 4. Create ClusterIssuer (nginx, not traefik)
INGRESS_CLASS=nginx bb cluster-issuer

# 5. Create values-prod-aws.yaml (or use --set flags)
#    Key differences: className: nginx, no Hetzner-specific annotations

# 6. Deploy
bb docker-push
bb helm-prod

# 7. Get load balancer hostname (EKS uses a hostname, not an IP)
kubectl get svc -n ingress-nginx
# Create a CNAME DNS record pointing to the ELB hostname

# 8. Seal monitoring credentials, then install LGTM stack
bb monitoring-seal-secrets
git add monitoring/secrets/ && git commit -m "Seal monitoring credentials"
bb monitoring-install
```

### Cost Estimate

| Component | Monthly cost |
|-----------|-------------|
| EKS control plane | ~$73 |
| 3× t3.medium workers | ~$90 |
| NAT Gateway | ~$32 |
| Load Balancer | ~$16 |
| **Total** | **~$211/mo** |

This is ~7× the Hetzner cost for similar capacity. The EKS control plane fee ($0.10/hr) and NAT Gateway are the main drivers.

### CD Workflow Changes

```yaml
# deploy-aws.yaml — replace kubeconfig step with:
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: eu-west-1

- name: Update kubeconfig
  run: aws eks update-kubeconfig --name myapp --region eu-west-1
```

GitHub Secrets needed: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (instead of `KUBE_CONFIG`).

---

## Deploying to Google Cloud (GKE)

### What's Different from Hetzner

GKE is Google's managed Kubernetes. Like EKS, Google runs the control plane. GKE has a free tier: one zonal cluster per billing account has no management fee. GKE supports Autopilot mode (Google manages nodes too) and Standard mode (you manage node pools).

GKE does not ship with nginx-ingress or cert-manager by default. It has its own GCE Ingress, but nginx-ingress is more portable.

### Prerequisites

```bash
brew install google-cloud-sdk
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud services enable container.googleapis.com      # Enable K8s API
gcloud services enable compute.googleapis.com         # Enable Compute API
```

### Terraform Configuration

Create `terraform/gcp/main.tf`:

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = "your-project-id"
  region  = "europe-west1"
}

module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google"
  version = "~> 35.0"

  project_id = "your-project-id"
  name       = "myapp"
  region     = "europe-west1"
  zones      = ["europe-west1-b"]

  network    = "default"
  subnetwork = "default"

  ip_range_pods     = ""
  ip_range_services = ""

  node_pools = [
    {
      name         = "workers"
      machine_type = "e2-medium"       # 2 vCPU, 4GB (~$24/mo each)
      min_count    = 2
      max_count    = 4
      disk_size_gb = 50
    }
  ]

  deletion_protection = false
}

output "cluster_name" {
  value = module.gke.name
}
```

### Setup Steps

```bash
# 1. Provision cluster (~5 minutes)
CLOUD=gcp bb tf-apply

# 2. Get kubeconfig
gcloud container clusters get-credentials myapp --region europe-west1

# 3. Install ingress controller + cert-manager
bb ingress-install
bb cert-manager-install

# 4. Create ClusterIssuer
INGRESS_CLASS=nginx bb cluster-issuer

# 5. Deploy
bb docker-push
bb helm-prod

# 6. Get load balancer IP
kubectl get svc -n ingress-nginx
# Create A record in DNS

# 7. Seal monitoring credentials, then install LGTM stack
bb monitoring-seal-secrets
git add monitoring/secrets/ && git commit -m "Seal monitoring credentials"
bb monitoring-install
```

### Cost Estimate

| Component | Monthly cost |
|-----------|-------------|
| GKE control plane (zonal) | Free (1 per account) |
| 3× e2-medium workers | ~$72 |
| Load Balancer | ~$18 |
| **Total** | **~$90/mo** |

Significantly cheaper than AWS. The free zonal cluster control plane and no NAT Gateway fee make a big difference. GKE is the cheapest managed K8s option from the big three clouds.

### CD Workflow Changes

```yaml
# deploy-gcp.yaml — replace kubeconfig step with:
- name: Authenticate to Google Cloud
  uses: google-github-actions/auth@v2
  with:
    credentials_json: ${{ secrets.GCP_SA_KEY }}

- name: Set up Cloud SDK
  uses: google-github-actions/setup-gcloud@v2

- name: Get GKE credentials
  run: gcloud container clusters get-credentials myapp --region europe-west1
```

GitHub Secrets needed: `GCP_SA_KEY` (a service account key JSON file, base64-encoded).

---

## Deploying to Azure (AKS)

### What's Different from Hetzner

AKS is Azure's managed Kubernetes. Like EKS and GKE, Azure runs the control plane for free. AKS is tightly integrated with Azure Active Directory for RBAC, Azure Monitor for logging, and Azure CNI for networking.

AKS does not ship with cert-manager. It has its own Application Gateway Ingress Controller, but nginx-ingress is more portable.

### Prerequisites

```bash
brew install azure-cli
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
az provider register --namespace Microsoft.ContainerService
```

### Terraform Configuration

Create `terraform/azure/main.tf`:

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "your-subscription-id"
}

resource "azurerm_resource_group" "myapp" {
  name     = "myapp-rg"
  location = "West Europe"             # Netherlands
}

module "aks" {
  source  = "Azure/aks/azurerm"
  version = "~> 11.0"

  resource_group_name = azurerm_resource_group.myapp.name
  prefix              = "myapp"

  agents_size  = "Standard_D2s_v3"     # 2 vCPU, 8GB (~$70/mo each)
  agents_count = 3

  rbac_aad = false
}

output "cluster_name" {
  value = module.aks.aks_name
}

output "resource_group" {
  value = azurerm_resource_group.myapp.name
}
```

### Setup Steps

```bash
# 1. Provision cluster (~5 minutes)
CLOUD=azure bb tf-apply

# 2. Get kubeconfig
az aks get-credentials --resource-group myapp-rg --name myapp-aks

# 3. Install ingress controller + cert-manager
bb ingress-install
bb cert-manager-install

# 4. Create ClusterIssuer
INGRESS_CLASS=nginx bb cluster-issuer

# 5. Deploy
bb docker-push
bb helm-prod

# 6. Get load balancer IP
kubectl get svc -n ingress-nginx
# Create A record in DNS

# 7. Seal monitoring credentials, then install LGTM stack
bb monitoring-seal-secrets
git add monitoring/secrets/ && git commit -m "Seal monitoring credentials"
bb monitoring-install
```

### Cost Estimate

| Component | Monthly cost |
|-----------|-------------|
| AKS control plane | Free |
| 3× Standard_D2s_v3 workers | ~$210 |
| Load Balancer | ~$18 |
| **Total** | **~$228/mo** |

Azure is the most expensive of the three hyperscalers for equivalent specs. The VM pricing is higher than AWS or GCP. However, if your organisation already has an Azure Enterprise Agreement, the effective cost may be lower.

### CD Workflow Changes

```yaml
# deploy-azure.yaml — replace kubeconfig step with:
- name: Azure Login
  uses: azure/login@v2
  with:
    creds: ${{ secrets.AZURE_CREDENTIALS }}

- name: Set up kubeconfig
  uses: azure/aks-set-context@v4
  with:
    resource-group: myapp-rg
    cluster-name: myapp-aks
```

GitHub Secrets needed: `AZURE_CREDENTIALS` (a service principal JSON).

---

## Deploying to Civo

### What's Different from Hetzner

Civo is the most similar to Hetzner. It's a developer-focused cloud with simple pricing, fast cluster creation (~90 seconds), and Traefik pre-installed (because Civo uses k3s under the hood, just like kube-hetzner). The control plane is free.

Civo is the easiest migration from your current Hetzner setup because the ingress class (Traefik) and the k3s architecture are identical. You don't need to install nginx-ingress or change your ClusterIssuer.

However, Civo does not pre-install cert-manager, so you need to install it yourself.

### Prerequisites

```bash
brew install civo
civo apikey save mykey YOUR_API_KEY
civo region current LON1
```

### Terraform Configuration

Create `terraform/civo/main.tf`:

```hcl
terraform {
  required_providers {
    civo = {
      source  = "civo/civo"
      version = "~> 1.1"
    }
  }
}

provider "civo" {
  region = "LON1"                      # London
}

resource "civo_firewall" "myapp" {
  name = "myapp-firewall"

  ingress_rule {
    label      = "kubernetes-api"
    protocol   = "tcp"
    port_range = "6443"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  ingress_rule {
    label      = "http"
    protocol   = "tcp"
    port_range = "80"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  ingress_rule {
    label      = "https"
    protocol   = "tcp"
    port_range = "443"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }
}

resource "civo_kubernetes_cluster" "myapp" {
  name         = "myapp"
  firewall_id  = civo_firewall.myapp.id
  cluster_type = "k3s"

  pools {
    label      = "workers"
    size       = "g4s.kube.medium"     # 2 vCPU, 4GB
    node_count = 3
  }
}

output "kubeconfig" {
  value     = civo_kubernetes_cluster.myapp.kubeconfig
  sensitive = true
}
```

### Setup Steps

```bash
# 1. Provision cluster (~90 seconds!)
CLOUD=civo bb tf-apply

# 2. Get kubeconfig
CLOUD=civo bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml

# 3. Install cert-manager (Civo doesn't include it, but Traefik is already there)
bb cert-manager-install

# 4. Create ClusterIssuer (same as Hetzner — Traefik!)
bb cluster-issuer

# 5. Deploy
bb docker-push
bb helm-prod

# 6. Get load balancer IP
kubectl get svc -A | grep traefik
# Create A record in DNS

# 7. Seal monitoring credentials, then install LGTM stack
bb monitoring-seal-secrets
git add monitoring/secrets/ && git commit -m "Seal monitoring credentials"
bb monitoring-install
```

### Cost Estimate

| Component | Monthly cost |
|-----------|-------------|
| Civo control plane | Free |
| 3× g4s.kube.medium workers | ~$36 |
| Load Balancer | ~$10 |
| **Total** | **~$46/mo** |

Civo is the closest to Hetzner in price. No egress fees. The 90-second cluster creation time is dramatically faster than any other provider.

### CD Workflow Changes

Civo uses a static kubeconfig (like Hetzner), so the existing `cd.yaml` works unchanged. Store the kubeconfig as `KUBE_CONFIG` secret in GitHub — the same workflow as Hetzner.

### Why Civo Is the Easiest Migration

| Feature | Hetzner | Civo | AWS | Azure | GCP |
|---------|---------|------|-----|-------|-----|
| K8s distribution | k3s | k3s | EKS | AKS | GKE |
| Ingress controller | Traefik (built-in) | Traefik (built-in) | Install yourself | Install yourself | Install yourself |
| cert-manager | Built-in | Install yourself | Install yourself | Install yourself | Install yourself |
| Ingress class | traefik | traefik | nginx | nginx | nginx |
| CD auth method | Static kubeconfig | Static kubeconfig | AWS IAM | Azure AD | GCP SA |
| ClusterIssuer change | None | None | INGRESS_CLASS=nginx | INGRESS_CLASS=nginx | INGRESS_CLASS=nginx |
| Helm values changes | None | None | className: nginx | className: nginx | className: nginx |
| Cluster creation time | ~5 min | ~90 sec | ~10 min | ~5 min | ~5 min |
| Monthly cost (3 nodes) | ~$30 | ~$46 | ~$211 | ~$228 | ~$90 |

---

## Deploying to a Customer's On-Prem Environment (Harbor, ArgoCD, Rancher)

### Why This Scenario Comes Up

Enterprise customers often have their own infrastructure. They don't use public cloud, or they run a private cloud alongside it. They've already invested in tools: Harbor for their container registry, ArgoCD for GitOps deployments, and Rancher for managing Kubernetes clusters across their data centres. They want you to deploy your application into their environment using their tools — not bring your own.

This is a fundamentally different situation from deploying to your own Hetzner cluster. You don't provision infrastructure. You don't choose the CI/CD tool. You adapt to what the customer already has. The good news: because this project uses standard Kubernetes, standard Docker images, standard Helm charts, and OpenTelemetry, the adaptation is configuration work, not a rewrite.

### What Each Tool Replaces

| Your tool | Customer's tool | What changes |
|-----------|----------------|--------------|
| GHCR (GitHub Container Registry) | **Harbor** | Where Docker images are stored and pulled from |
| GitHub Actions `cd.yaml` | **ArgoCD** | How deployments are triggered (push → pull model) |
| Terraform + kube-hetzner | **Rancher** | How the K8s cluster is provisioned and managed |
| You manage everything | Customer manages infrastructure | Your responsibility shrinks to the application layer |

### What Stays Exactly the Same

This is the important part. Because we built on standards, most of the project is untouched:

- **Application code** — `src/myapp/core.clj` doesn't know or care about Harbor, ArgoCD, or Rancher
- **Dockerfile** — builds the same OCI-compliant image. Harbor, GHCR, ECR, any registry can store it
- **Helm chart templates** — `deployment.yaml`, `service.yaml`, `ingress.yaml`, `pdb.yaml` are standard Kubernetes. ArgoCD deploys them the same way `helm upgrade` does
- **Helm values files** — you'll add a `values-customer.yaml` with their specific settings
- **OTel agent** — traces go wherever the customer's collector endpoint is. One environment variable change
- **iapetos metrics** — `/metrics` is Prometheus format. Every monitoring system scrapes it the same way
- **CI workflow** (`ci.yaml`) — still builds the image, just pushes to Harbor instead of GHCR

### Adapting to Harbor

Harbor is an open-source container registry. It stores Docker images and Helm charts, provides RBAC, vulnerability scanning, and image signing. It replaces GHCR in your pipeline.

**What changes in CI:**

The customer gives you Harbor credentials (a robot account, not a personal login). You update `ci.yaml` to push to Harbor instead of GHCR:

```yaml
# ci.yaml — changes for Harbor
env:
  REGISTRY: harbor.customer.com
  IMAGE_NAME: myproject/myapp

steps:
  - name: Login to Harbor
    uses: docker/login-action@v3
    with:
      registry: harbor.customer.com
      username: ${{ secrets.HARBOR_USERNAME }}
      password: ${{ secrets.HARBOR_PASSWORD }}

  - name: Build and push
    uses: docker/build-push-action@v6
    with:
      push: true
      platforms: linux/amd64
      tags: harbor.customer.com/myproject/myapp:${{ github.sha }}
```

**What changes in Helm values:**

```yaml
# values-customer.yaml
image:
  repository: harbor.customer.com/myproject/myapp
  pullPolicy: Always
```

Unlike GHCR (which we made public), Harbor is typically private. The customer's cluster will already have an `imagePullSecret` configured for Harbor, or they use a cluster-wide pull secret. You may need to add this to the deployment:

```yaml
# If needed in values-customer.yaml
imagePullSecrets:
  - name: harbor-pull-secret
```

**Harbor can also store Helm charts** as OCI artifacts. If the customer wants the Helm chart in Harbor (not just in Git), you'd push it:

```bash
helm package ./helm/myapp
helm push myapp-0.1.0.tgz oci://harbor.customer.com/myproject
```

ArgoCD can then pull the chart from Harbor instead of from Git. This is optional — ArgoCD works with Git-based charts too.

### Adapting to ArgoCD

ArgoCD is a pull-based GitOps controller that runs inside the customer's cluster. It replaces your `cd.yaml` workflow entirely. Instead of GitHub Actions pushing deployments to the cluster, ArgoCD continuously watches your Git repository and pulls changes when it detects a difference between Git and the cluster.

**What you remove:** Delete `.github/workflows/cd.yaml`. ArgoCD replaces it.

**What you keep:** `.github/workflows/ci.yaml` stays. It still builds Docker images and pushes them to Harbor. CI and CD are decoupled — CI produces artifacts, ArgoCD deploys them.

**How ArgoCD works:**

```
Git repo (your Helm chart)
  ↑
  │  ArgoCD polls every 3 minutes (configurable)
  │
ArgoCD (runs in customer's cluster)
  │  Detects: Git has image tag sha-abc123, cluster has sha-def456
  │  Runs: helm template with values-customer.yaml
  │  Applies: kubectl apply of the rendered manifests
  │  Verifies: waits for rollout to complete
  ▼
Application updated in cluster
```

**Setting up the ArgoCD Application:**

The customer's platform team creates an ArgoCD Application resource that points to your repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/rorycawley/myapp.git
    targetRevision: main
    path: helm/myapp
    helm:
      valueFiles:
        - values-customer.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true        # remove resources deleted from Git
      selfHeal: true      # revert manual changes to match Git
    syncOptions:
      - CreateNamespace=true
```

With `selfHeal: true`, if someone manually edits a deployment in the cluster (`kubectl edit`), ArgoCD detects the drift and reverts it to match Git. This is the "purer" GitOps model discussed in the GitOps section — Git is always the truth, the cluster always converges to match it.

**The image tag update flow:**

There's one catch: when CI builds a new image with tag `sha-abc123`, ArgoCD needs to know about the new tag. There are several approaches:

1. **Image tag in values file (simplest):** CI updates `values-customer.yaml` with the new tag and commits it. ArgoCD sees the commit and syncs. This means CI needs write access to the repo.

2. **ArgoCD Image Updater (automated):** The ArgoCD Image Updater watches Harbor for new image tags and automatically updates the Application. No CI commit needed.

3. **Kustomize overlay:** Use a `kustomization.yaml` that references the image tag, and CI updates just the tag file.

For the simplest approach, add a step to `ci.yaml` that updates the image tag in Git after pushing to Harbor:

```yaml
  - name: Update image tag in Git
    run: |
      sed -i "s/tag: .*/tag: ${{ github.sha }}/" helm/myapp/values-customer.yaml
      git config user.name "CI Bot"
      git config user.email "ci@example.com"
      git add helm/myapp/values-customer.yaml
      git commit -m "ci: update image tag to ${{ github.sha }}"
      git push
```

ArgoCD detects the commit, sees the new tag, and deploys.

**ArgoCD provides its own rollback, health checks, and notifications.** You can configure ArgoCD to send Slack notifications on sync success/failure, and it has a web UI showing deployment history, sync status, and resource health. This replaces the smoke test and rollback logic in `cd.yaml`.

### Adapting to Rancher

Rancher is a Kubernetes management platform. It doesn't replace Kubernetes — it manages multiple Kubernetes clusters through a single UI. The customer uses Rancher to provision clusters (using RKE2, k3s, or imported clusters), manage access control, and provide a unified view across their infrastructure.

**From your perspective, Rancher is invisible.** You deploy to a Kubernetes cluster. Whether that cluster was created by Rancher, Terraform, or manually doesn't matter to your Helm chart. The Kubernetes API is the same.

What Rancher does affect:

**Cluster access:** The customer gives you a kubeconfig generated through Rancher's RBAC system. This kubeconfig may have limited permissions (deploy to one namespace, not cluster-admin). ArgoCD handles deployment, so you may not need direct kubectl access at all.

**Ingress controller:** Rancher clusters often use nginx-ingress (installed by Rancher) rather than Traefik. Your `values-customer.yaml` would set:

```yaml
ingress:
  className: nginx
  annotations: {}    # customer may require specific annotations
```

**Monitoring:** Rancher has its own monitoring stack (Rancher Monitoring, based on Prometheus + Grafana). The customer may want you to use their existing monitoring rather than installing the LGTM stack. In that case, your iapetos `/metrics` endpoint is already compatible — Rancher's Prometheus scrapes it automatically via the pod annotations. For traces, point the OTel agent at the customer's collector endpoint.

**Namespaces and RBAC:** Rancher projects group namespaces. The customer will assign your application to a Rancher project with appropriate resource quotas, network policies, and RBAC. You deploy into the namespace they provide.

### The Adapted Workflow

```
Developer (you)
  │  Edit code → REPL → bb helm-local → git push
  ▼
GitHub Actions (ci.yaml only)
  │  Build image → push to Harbor
  │  Update image tag in Git → commit
  ▼
ArgoCD (in customer's Rancher-managed cluster)
  │  Detects Git change → syncs Helm chart
  │  Pulls image from Harbor → deploys
  │  Self-heals if cluster drifts from Git
  ▼
Application running in customer's namespace
  │  /metrics scraped by Rancher's Prometheus
  │  OTel traces sent to customer's collector
  │  Logs collected by customer's log aggregator
```

### Summary of Changes

| File | Change | Why |
|------|--------|-----|
| `ci.yaml` | Push to Harbor instead of GHCR | Customer's registry |
| `ci.yaml` | Add step to update image tag in Git | ArgoCD needs to see the new tag |
| `cd.yaml` | **Delete entirely** | ArgoCD replaces it |
| `values-customer.yaml` | **New file** — Harbor image repo, nginx ingress class, customer-specific settings | Customer's environment |
| `helm/myapp/templates/` | No changes | Standard K8s — works everywhere |
| `Dockerfile` | No changes | OCI images are universal |
| `src/myapp/core.clj` | No changes | Application code is infrastructure-agnostic |
| `terraform/` | **Not used** | Customer manages infrastructure with Rancher |
| `monitoring/` | **Not used** (usually) | Customer has their own monitoring |
| `bb.edn` | Still useful for local dev (`bb dev`, `bb helm-local`) | Your laptop workflow doesn't change |

The customer provides: cluster access (via Rancher), Harbor credentials, the ArgoCD Application definition, and their ingress/monitoring configuration. You provide: the Git repo with the Helm chart, and a CI pipeline that pushes images to their Harbor.

---

## Secrets Management

### Where Secrets Live Today (and Why That's a Problem)

This project currently stores secrets in several places:

| Secret | Where it lives | Risk |
|--------|---------------|------|
| Hetzner API token | `.zshrc` env var + `terraform.tfstate` | Laptop compromise exposes cloud access |
| Kubeconfig | `myapp_kubeconfig.yaml` (local file) | Full cluster admin access if stolen |
| GHCR credentials | `gh` CLI token | Can push images to your registry |
| MinIO root password | `monitoring/secrets/minio-root-creds.sealedsecret.yaml` (Sealed Secret in Git) | Encrypted with the cluster's controller key — only that cluster can decrypt |
| Grafana admin password | `monitoring/secrets/grafana-admin-creds.sealedsecret.yaml` (Sealed Secret in Git) | Same — encrypted, safe to commit |
| GitHub Actions secrets | GitHub's encrypted secrets store | Reasonable, but GitHub-specific |

For a personal learning project, this is fine. For a production system with real users and real data, it's not. The remaining plaintext exposures are: the Hetzner token in your shell profile means anyone with access to your laptop has access to your cloud infrastructure, and the kubeconfig grants full cluster admin — if someone copies that file, they own your cluster. The monitoring credentials are no longer in plaintext anywhere in Git, but the older `admin-change-me` / `minio-secret-key-change-me` defaults remain in pre-migration commits and must be considered burned (the seal helper generates fresh random values).

### What a Secrets Manager Solves

A secrets manager is a dedicated service for storing, accessing, and rotating sensitive values. Instead of passwords living in YAML files, environment variables, or Git, they live in one secured, audited, access-controlled vault. Applications request secrets at runtime, and the secrets manager authenticates the request, checks permissions, and returns the value — or denies access.

The key benefits:

**Centralisation** — all secrets in one place, not scattered across `.zshrc`, Helm values, GitHub secrets, and Kubernetes Secrets. One place to audit, one place to rotate, one place to revoke.

**Access control** — each application, service, and person gets only the secrets they need. Your web app can read the database password but not the Hetzner token. The CI pipeline can read the Harbor credentials but not the Grafana admin password.

**Audit logging** — every secret access is logged. You can answer "who accessed the production database password at 3am last Tuesday?" This is critical for compliance (SOC 2, ISO 27001, GDPR).

**Rotation** — secrets can be rotated (changed) without redeploying. The secrets manager pushes the new value to applications automatically. No more "update the password in 14 different places."

**Dynamic secrets** — instead of static database passwords, the secrets manager can generate short-lived database credentials on demand. Each pod gets its own credentials that expire in hours. If one is compromised, it's already expired.

### HashiCorp Vault

Vault is the most widely used secrets manager in Kubernetes environments. It's open source (with an enterprise version), runs inside or outside your cluster, and integrates deeply with Kubernetes via service account authentication.

Vault stores secrets in a hierarchical path structure:

```
secret/
  ├── myapp/
  │   ├── database         → { username: "app", password: "..." }
  │   ├── grafana           → { admin-password: "..." }
  │   └── minio             → { root-password: "..." }
  ├── infrastructure/
  │   ├── hetzner           → { api-token: "..." }
  │   └── harbor            → { robot-password: "..." }
```

Each path has policies controlling who can read, write, list, or delete secrets at that path.

### How Vault Integrates with Kubernetes

Vault authenticates pods using their Kubernetes service account token. When a pod starts, it presents its service account token to Vault. Vault verifies the token with the Kubernetes API, checks which Vault role the service account is bound to, and returns a Vault token scoped to the appropriate policies. No passwords are baked into the pod spec.

There are three ways to get secrets from Vault into your pods:

**Option 1: Vault Sidecar Injector (recommended for most cases)**

A sidecar container runs alongside your app. It authenticates to Vault, fetches secrets, and writes them to a shared in-memory volume. Your app reads secrets from files — it doesn't need to know Vault exists.

```yaml
# Add annotations to your deployment template
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "myapp"
    vault.hashicorp.com/agent-inject-secret-db-password: "secret/myapp/database"
    vault.hashicorp.com/agent-inject-template-db-password: |
      {{- with secret "secret/myapp/database" -}}
      {{ .Data.data.password }}
      {{- end }}
```

The secret appears as a file at `/vault/secrets/db-password` inside the container. Your app reads it like any file. The sidecar automatically renews the Vault token and re-fetches secrets if they're rotated.

**Option 2: Vault CSI Driver**

The Secrets Store CSI Driver mounts secrets as ephemeral volumes. You create a `SecretProviderClass` that defines which secrets to fetch:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: myapp-secrets
spec:
  provider: vault
  parameters:
    roleName: "myapp"
    objects: |
      - objectName: "db-password"
        secretPath: "secret/data/myapp/database"
        secretKey: "password"
```

Your pod mounts the SecretProviderClass as a volume, and the secrets appear as files. The CSI driver can also sync secrets to Kubernetes Secrets for use as environment variables.

**Option 3: Vault Secrets Operator (VSO)**

The newest approach. The Vault Secrets Operator is a Kubernetes operator that watches custom resources (`VaultStaticSecret`, `VaultDynamicSecret`) and syncs their values into Kubernetes Secrets. Your pod consumes standard K8s Secrets — it doesn't know Vault is involved.

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: myapp-db-creds
spec:
  mount: secret
  path: myapp/database
  type: kv-v2
  destination:
    name: myapp-db-secret    # creates a K8s Secret with this name
    create: true
```

The operator handles authentication, renewal, and rotation. When a secret changes in Vault, the operator updates the Kubernetes Secret, and your pod sees the new value on the next restart (or immediately if using a volume mount).

### What the Migration Would Look Like

Starting from the current project, migrating to Vault involves:

**1. Install Vault in the cluster:**

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  -n vault --create-namespace \
  --set "server.dev.enabled=true"    # dev mode for testing (not for production)
```

For production, you'd use Vault with auto-unseal (via a cloud KMS), high availability (3 replicas), and persistent storage.

**2. Store your secrets in Vault:**

```bash
# Port-forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200

# Write secrets
export VAULT_ADDR=http://localhost:8200
vault kv put secret/myapp/database username=app password=db-secret-password
vault kv put secret/myapp/grafana admin-password=grafana-secret
vault kv put secret/myapp/minio root-password=minio-secret
```

**3. Create a Vault policy and role for your app:**

```bash
# Policy: myapp can only read its own secrets
vault policy write myapp - <<EOF
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
EOF

# Role: bind the policy to the myapp service account
vault write auth/kubernetes/role/myapp \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=myapp \
  ttl=1h
```

**4. Add Vault annotations to the Helm deployment template:**

Add annotations to `helm/myapp/templates/deployment.yaml` (behind a values toggle so Vault is optional):

```yaml
{{- if .Values.vault.enabled }}
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: {{ .Values.vault.role | quote }}
  {{- range $key, $val := .Values.vault.secrets }}
  vault.hashicorp.com/agent-inject-secret-{{ $key }}: {{ $val.path | quote }}
  {{- end }}
{{- end }}
```

**5. Update values files:**

```yaml
# values-prod.yaml (with Vault)
vault:
  enabled: true
  role: myapp
  secrets:
    db-password:
      path: "secret/data/myapp/database"
```

**6. Remove hardcoded passwords from Git:**

Replace the passwords in `monitoring/values-minio.yaml` and `monitoring/values-grafana.yaml` with references to Vault secrets, or manage the monitoring stack separately via Vault.

### Staying Vendor-Agnostic: The Secrets Store CSI Driver Approach

Vault is open source and runs anywhere, which makes it infrastructure-agnostic. But there's an even more portable approach: the **Kubernetes Secrets Store CSI Driver**.

The CSI Driver is a standard Kubernetes interface that supports multiple secret providers via plugins. The same CSI Driver works with:

| Provider | Plugin | Use case |
|----------|--------|----------|
| HashiCorp Vault | `vault` | Self-hosted, any cloud or on-prem |
| AWS Secrets Manager | `aws` | AWS-native secrets |
| Azure Key Vault | `azure` | Azure-native secrets |
| GCP Secret Manager | `gcp` | GCP-native secrets |

If you use the CSI Driver interface, switching from Vault to AWS Secrets Manager (or vice versa) means changing the `provider` field in the `SecretProviderClass` and the parameters — not changing your application or deployment templates.

Your deployment template always looks the same:

```yaml
volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: myapp-secrets
```

Only the `SecretProviderClass` changes between providers. This is the same pattern as the ingress class abstraction — your templates are provider-agnostic, the provider-specific config is in a separate resource.

### Cloud-Native Alternatives (and When to Use Them)

If you're already on a single cloud and don't need portability, cloud-native secrets managers are simpler than running Vault yourself:

**AWS Secrets Manager** — fully managed, integrates with IAM, supports automatic rotation for RDS credentials. No infrastructure to manage. Use via the AWS CSI provider or the External Secrets Operator.

**Azure Key Vault** — fully managed, integrates with Azure AD, supports certificates and encryption keys as well as secrets. Use via the Azure CSI provider or AKS-native integration.

**GCP Secret Manager** — fully managed, integrates with IAM, supports automatic replication across regions. Use via the GCP CSI provider or Workload Identity.

**When to use Vault instead:** when you're multi-cloud, on-prem, or need features like dynamic secrets (short-lived database credentials generated on demand), encryption as a service (transit backend), or PKI certificate issuance. Vault is more work to operate but gives you capabilities that cloud-native solutions don't have.

### The Pragmatic Path

You don't need to migrate everything to Vault on day one. A gradual approach:

**Phase 1 (now):** Move passwords out of Git. Use Kubernetes Secrets created via `kubectl create secret` or sealed-secrets (encrypted secrets stored in Git). This removes the most obvious problem (passwords in plain text in your repo) with minimal effort.

**Phase 2:** Install Vault in dev mode on your cluster. Move the MinIO and Grafana passwords there. Learn the workflow (write secrets, create policies, add annotations). Use the sidecar injector for the simplest integration.

**Phase 3:** Configure Vault for production (auto-unseal, HA, audit logging). Migrate all application secrets. Set up dynamic database credentials if you add a database later.

**Phase 4:** If you're deploying to customer environments, configure Vault to federate with their identity provider. Or use the CSI Driver with whatever secrets manager they already run — Vault, AWS Secrets Manager, Azure Key Vault — your deployment templates don't change.

---

## Business Continuity

### What Business Continuity Means

Business continuity is the plan for keeping your service running (or getting it running again quickly) when something goes wrong. "Something going wrong" ranges from small incidents (a pod crash, a bad deploy) to catastrophic failures (data centre fire, cloud region outage, ransomware attack).

Two numbers define your business continuity requirements:

**RTO (Recovery Time Objective)** — the maximum acceptable downtime. If your RTO is 1 hour, the service must be back within 1 hour of a failure. If your RTO is 5 minutes, you need a much more robust (and expensive) setup.

**RPO (Recovery Point Objective)** — the maximum acceptable data loss, measured in time. If your RPO is 1 hour, you can lose up to 1 hour of data. If your RPO is zero, you need real-time replication.

These aren't technical decisions — they're business decisions. An internal tool used by 10 people can tolerate hours of downtime. An e-commerce site processing orders can't tolerate 5 minutes. The cost of achieving lower RTO/RPO increases exponentially, so you match the investment to the business risk.

### What Needs Protecting in This Project

| Component | Contains | If lost | Recovery method |
|-----------|----------|---------|-----------------|
| Application code | Source, Dockerfile, Helm charts | Rebuild from Git | Git is the backup — clone and redeploy |
| Docker images | Built container images | Rebuild from code | CI pipeline rebuilds from Git |
| Terraform state | Cluster resource mapping | Can't manage existing cluster | Back up `terraform.tfstate` to remote backend |
| Kubernetes cluster state | Deployments, Services, Ingress, Secrets | Service is down | Recreate with `bb tf-apply` + `bb helm-prod` |
| Monitoring data | Metrics, logs, traces | Lose historical visibility | Accept the loss, or back up MinIO/Mimir/Loki data |
| TLS certificates | HTTPS encryption | Browser warnings until re-issued | cert-manager re-issues automatically on redeploy |
| Database (if added later) | User data, transactions | Data loss — the critical concern | Database-specific backup + replication |

The good news: this project is largely stateless. The application serves HTTP responses and doesn't store user data. The most critical things are already in Git (code, Helm charts, CI/CD pipelines). If you lose the entire cluster, you can rebuild from scratch in about 15 minutes — `bb tf-apply`, `bb cluster-issuer`, `bb monitoring-seal-secrets`, `bb monitoring-install`, `bb helm-prod`. Your RPO for the application itself is effectively zero (no data to lose). Your RTO is ~15 minutes (cluster provisioning time).

The picture changes dramatically when you add a database. At that point, your RPO and RTO depend on your database backup strategy, not your Kubernetes setup.

### Levels of Business Continuity

| Level | What it protects against | RTO | Cost | This project today |
|-------|------------------------|-----|------|-------------------|
| **1. Reproducible infrastructure** | Cluster failure, accidental deletion | ~15 min | Free (IaC in Git) | ✓ Yes — Terraform + Helm |
| **2. Automated backups** | Data corruption, accidental deletion of K8s resources | Minutes | Low (Velero + object storage) | Not yet |
| **3. Multi-zone / HA** | Single node failure, hardware failure | Seconds | Moderate (extra nodes across zones) | Partial (3 workers, PDB) |
| **4. Multi-region standby** | Entire region/data centre failure | Minutes to hours | High (duplicate infrastructure) | No |
| **5. Multi-region active-active** | Any single-region failure, zero downtime | Near-zero | Very high (full duplication + data sync) | No |

Most projects start at Level 1 (where this project is) and add levels as the business requires. Don't build Level 5 for a project that needs Level 2.

### Level 1: Reproducible Infrastructure (You Have This)

Because everything is Infrastructure as Code, your cluster is disposable and rebuildable:

```bash
# Total loss scenario: cluster gone, rebuild from scratch
bb tf-apply                    # recreate cluster (~5 min)
bb tf-kubeconfig               # get new kubeconfig
bb cluster-issuer              # recreate ClusterIssuer
bb monitoring-seal-secrets     # new cluster ⇒ new sealing key, reseal credentials
git add monitoring/secrets/ && git commit -m "Reseal monitoring creds for rebuilt cluster"
bb monitoring-install          # reinstall LGTM stack
bb helm-prod                   # deploy app
# Wait for TLS certificate (~1 min)
# Total: ~15 minutes to full recovery
```

Your RTO is ~15 minutes. Your RPO for the application is zero (no data lost — code is in Git, images in GHCR). You lose monitoring history (metrics, logs, traces) because MinIO data wasn't backed up, but that's rarely critical.

**The one thing that breaks this: losing Terraform state.** If `terraform.tfstate` is lost, Terraform can't manage the existing cluster. The fix: use a remote state backend.

```hcl
# Add to main.tf for remote state
terraform {
  backend "s3" {
    bucket = "myapp-terraform-state"
    key    = "hetzner/terraform.tfstate"
    region = "eu-central-1"
  }
}
```

This stores the state file in S3 (or MinIO, or any S3-compatible storage) instead of on your laptop. Multiple team members can access it, and it's backed up by the storage provider.

### Level 2: Automated Backups with Velero

Velero is the standard open-source tool for backing up Kubernetes clusters. It captures cluster resources (Deployments, Services, Secrets, ConfigMaps) and persistent volume data, stores them in object storage, and can restore them to the same or a different cluster.

**What Velero backs up:**

```
Cluster state (via Kubernetes API):
  ├── Deployments, StatefulSets, DaemonSets
  ├── Services, Ingresses
  ├── ConfigMaps, Secrets
  ├── PersistentVolumeClaims
  └── Custom Resources (ClusterIssuers, Certificates, etc.)

Persistent volume data (via snapshots or file-level backup):
  ├── MinIO data (metrics storage for Mimir, logs for Loki)
  ├── Grafana dashboards and settings
  └── Any future database volumes
```

**Installing Velero (Hetzner with MinIO as backup target):**

```bash
# Install Velero CLI
brew install velero

# Install Velero in the cluster (using MinIO as backup storage)
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backups \
  --secret-file ./credentials-minio \
  --use-volume-snapshots=false \
  --backup-location-config \
    region=minio,s3ForcePathStyle="true",s3Url=http://minio.monitoring.svc:9000
```

**Scheduled backups:**

```bash
# Daily backup of everything, retained for 30 days
velero schedule create daily-full \
  --schedule="0 2 * * *" \
  --ttl=720h

# Hourly backup of just the app namespace, retained for 7 days
velero schedule create hourly-app \
  --schedule="0 * * * *" \
  --include-namespaces=default \
  --ttl=168h
```

**Restoring after a disaster:**

```bash
# List available backups
velero backup get

# Restore everything from the most recent daily backup
velero restore create --from-backup daily-full-20260405020000

# Restore just the app namespace
velero restore create --from-backup hourly-app-20260405100000 \
  --include-namespaces default
```

With Velero, your RTO drops to minutes (restore from backup instead of rebuilding) and your RPO is the time since the last backup (1 hour if using hourly schedules).

### Level 3: High Availability Within a Region

This project already has some HA: 3 worker nodes, 2 app replicas, a PodDisruptionBudget, and rolling updates. If one node dies, K8s reschedules pods to the remaining nodes. If one pod crashes, the other keeps serving traffic.

To strengthen this:

**Spread pods across nodes** with anti-affinity rules (prevent both replicas landing on the same node):

```yaml
# In deployment template
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: myapp
          topologyKey: kubernetes.io/hostname
```

**Spread nodes across availability zones** (where supported). On Hetzner, nodes are in one location. On AWS, GCP, and Azure, you can spread workers across 2-3 availability zones within a region. If one zone has an outage, the others continue serving.

### Business Continuity by Deployment Environment

Each environment has different tools and constraints:

**Hetzner:**

Hetzner doesn't have multiple availability zones in the traditional cloud sense. All your nodes are in one data centre (e.g. Nuremberg). For basic BC: use Velero with an off-site backup target (e.g. Backblaze B2, Wasabi, or a different Hetzner location's object storage). For disaster recovery from a full data centre failure: maintain a cold standby cluster definition in a different Hetzner location (e.g. `terraform/hetzner-fsn1/main.tf` for Falkenstein) and restore Velero backups there.

**AWS:**

AWS provides the most BC options. EKS clusters can span multiple availability zones within a region, giving you HA against zone failures. For multi-region DR: use Velero with cross-region S3 replication. AWS also offers managed database replication (RDS Multi-AZ, Aurora Global), Route 53 health checks with DNS failover, and EBS snapshot copying across regions. For the highest tier: run active-active EKS clusters in two regions with Global Accelerator routing traffic to the healthy region.

**Azure:**

AKS supports availability zones. For DR: use Velero with Azure Blob Storage (geo-redundant replication built in). Azure provides Azure Site Recovery for VM-level DR, Azure Cosmos DB with multi-region writes for database BC, and Azure Front Door for global traffic management with health probes. AKS also integrates with Azure Backup for managed backup of cluster resources and persistent volumes.

**Google Cloud:**

GKE regional clusters automatically spread the control plane and nodes across 3 zones. This is the strongest single-region HA of the major clouds. For DR: use Velero with Cloud Storage (multi-region buckets replicate automatically). GCP also offers Cloud SQL cross-region replicas, Multi-Cluster Ingress for spanning multiple GKE clusters, and Backup for GKE (a managed backup service built on Velero).

**On-prem (Rancher-managed):**

On-prem BC depends heavily on the customer's infrastructure. Key questions: do they have multiple data centres? Is there shared storage (Ceph, NetApp) with replication? Do they run Rancher in HA? For Velero, use the customer's S3-compatible storage (often MinIO running on-prem) or replicate to a cloud bucket. For multi-site DR: Rancher can manage clusters across multiple data centres from a single control plane, and Velero can restore workloads to a cluster in a different site.

### The Portable BC Strategy

Velero is the common denominator across all environments. It works with any Kubernetes cluster (managed or self-hosted) and supports multiple storage backends via plugins:

| Storage backend | Plugin | Environment |
|----------------|--------|-------------|
| AWS S3 | `velero-plugin-for-aws` | AWS, Hetzner (via MinIO), on-prem (via MinIO) |
| Azure Blob | `velero-plugin-for-microsoft-azure` | Azure |
| GCP Cloud Storage | `velero-plugin-for-gcp` | GCP |
| MinIO (S3-compatible) | `velero-plugin-for-aws` | Anywhere (self-hosted) |

By standardising on Velero, your backup and restore procedures are the same regardless of where the cluster runs. The only difference is the storage backend configuration — the same `velero backup` and `velero restore` commands work everywhere.

### Testing Your BC Plan

A backup you've never restored is not a backup — it's hope. Schedule regular DR drills:

```bash
# Monthly: test a restore to a separate namespace
velero restore create dr-test-$(date +%Y%m) \
  --from-backup daily-full-latest \
  --namespace-mappings default:dr-test

# Verify the restored app works
kubectl get pods -n dr-test
curl http://myapp.dr-test.svc:8080/health

# Clean up
kubectl delete namespace dr-test
```

Document the results: how long did the restore take (measure your actual RTO), did everything come back correctly, were there manual steps needed? This is your evidence for compliance audits and your confidence that the plan actually works.

---

## Downtime, Upgrades, and Zero-Downtime Deployments

### Do We Need to Upgrade Kubernetes?

Yes. Kubernetes releases a new minor version roughly every 3 months. If you don't upgrade, within a year you're two or three versions behind, and you start missing security patches, bug fixes, and API deprecations that eventually break things.

k3s (the Kubernetes distribution running on your Hetzner cluster) tracks upstream Kubernetes releases. kube-hetzner manages upgrades through the system-upgrade-controller — a Kubernetes-native operator that runs inside your cluster and handles the upgrade process automatically.

When you update the k3s version in `main.tf` and run `bb tf-apply`, the system-upgrade-controller:

1. Upgrades the control plane node first (replaces the k3s binary, restarts the process)
2. Waits for the control plane to be healthy
3. Upgrades worker nodes one at a time (drains pods, upgrades, uncordons)
4. Pods are rescheduled onto upgraded nodes

During a node upgrade, containers on that node are stopped and rescheduled onto other nodes. Because you have 3 worker nodes and your app runs 2 replicas, there's always at least one healthy node running your app. The Kubernetes version skew policy requires that you don't skip minor versions — upgrade 1.32 → 1.33 → 1.34, not 1.32 → 1.34 directly.

### How Rolling Updates Work (Application Deployments)

Every time you deploy a new version of your app (via `git push` → CI/CD, or `bb helm-prod`), Kubernetes performs a rolling update. This is the default strategy, and it's designed for zero downtime.

Here's what happens step by step when you deploy a new image with 2 replicas running:

```
Before deployment:
  Pod A (v1) ✓ serving traffic
  Pod B (v1) ✓ serving traffic

Step 1: K8s creates Pod C (v2), waits for readiness probe to pass
  Pod A (v1) ✓ serving traffic
  Pod B (v1) ✓ serving traffic
  Pod C (v2) ✓ starting up...

Step 2: Pod C passes readiness probe, K8s adds it to the Service
  Pod A (v1) ✓ serving traffic
  Pod B (v1) ✓ serving traffic
  Pod C (v2) ✓ serving traffic

Step 3: K8s terminates Pod A, sends SIGTERM, waits for graceful shutdown
  Pod A (v1) ✗ terminating
  Pod B (v1) ✓ serving traffic
  Pod C (v2) ✓ serving traffic

Step 4: K8s creates Pod D (v2), waits for readiness probe
  Pod B (v1) ✓ serving traffic
  Pod C (v2) ✓ serving traffic
  Pod D (v2)   starting up...

Step 5: Pod D passes readiness, K8s terminates Pod B
  Pod C (v2) ✓ serving traffic
  Pod D (v2) ✓ serving traffic

Done. Zero downtime. Users saw no interruption.
```

At every step, at least one pod is serving traffic. The Service (internal load balancer) only routes traffic to pods that pass their readiness probe. Users never hit a pod that isn't ready.

### Making It Bulletproof: maxUnavailable and PodDisruptionBudgets

The current setup achieves zero downtime for normal deployments. But there are two improvements that make it robust against edge cases:

**1. Set maxUnavailable: 0 in the deployment strategy**

By default, Kubernetes allows some pods to be unavailable during a rolling update. Setting `maxUnavailable: 0` guarantees that the full replica count is always running — K8s must start a new pod and confirm it's ready before terminating any old pod.

In `helm/myapp/templates/deployment.yaml`, the strategy section would look like:

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0    # never reduce below desired count
      maxSurge: 1           # create one extra pod at a time
```

The trade-off: deployments take slightly longer because K8s is more cautious. For a 2-replica app, the difference is seconds.

**2. Add a PodDisruptionBudget (PDB)**

Rolling updates aren't the only thing that removes pods. Node upgrades, cluster autoscaling, and `kubectl drain` also evict pods. A PDB tells Kubernetes: "you must always keep at least N pods running for this app, even during voluntary disruptions."

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: myapp-pdb
spec:
  minAvailable: 1          # at least 1 pod must always be running
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp
```

Without a PDB, a k3s node upgrade could drain both of your pods simultaneously (if they happen to be on the same node). With `minAvailable: 1`, Kubernetes will only drain one pod at a time, ensuring the other keeps serving traffic.

For 2 replicas, `minAvailable: 1` is the right setting. If you scale to 4 replicas, you'd increase it to 2 or 3.

### Graceful Shutdown: Don't Drop In-Flight Requests

When Kubernetes terminates a pod, it sends SIGTERM and waits for `terminationGracePeriodSeconds` (default 30s) before force-killing with SIGKILL. During this window, the app should:

1. Stop accepting new connections
2. Finish processing in-flight requests
3. Exit cleanly

The JVM's Jetty server handles this correctly by default — when the process receives SIGTERM, Jetty stops accepting new connections and waits for active requests to complete.

There's a subtle race condition: Kubernetes sends SIGTERM and updates the Service endpoints simultaneously, but the load balancer (Traefik) might not pick up the endpoint change immediately. For a few seconds, Traefik might still route requests to the terminating pod. A `preStop` hook with a short sleep solves this:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]
```

This gives Traefik 5 seconds to notice the endpoint change before the app starts shutting down.

### Expected Downtime by Scenario

| Scenario | What happens | Expected downtime |
|----------|-------------|-------------------|
| **Code deploy** (git push) | Rolling update replaces pods one at a time | **Zero** — at least 1 pod always serving |
| **Hotfix** | Same rolling update, just faster cycle | **Zero** — identical to any deploy |
| **Feature deploy** | Same rolling update | **Zero** — the deployment mechanism is the same regardless of change size |
| **k3s version upgrade** | Nodes upgraded one at a time, pods rescheduled | **Zero** for your app (with PDB). Brief K8s API blip (~seconds per node) for kubectl commands |
| **Node failure** (hardware) | K8s detects, reschedules pods to healthy nodes | **Brief** — ~30-60s while K8s detects the failure and starts new pods |
| **Cluster destroy + recreate** | Full rebuild of all infrastructure | **~10 minutes** — unavoidable, but this is a deliberate action |
| **Helm chart change** | Rolling update with new pod spec | **Zero** — same rolling update mechanism |
| **Monitoring stack update** | Helm upgrade of LGTM components | **Zero for your app** — monitoring is in a separate namespace |

### The Key Insight

Application deployments (patches, hotfixes, features) are all the same mechanism — a rolling update triggered by a new Docker image tag. There's no difference in downtime between a one-line hotfix and a major feature release. The deployment mechanism doesn't know or care about the size of the change. This is one of the major benefits of containerised deployments: every deploy is the same predictable, tested process.

The only scenario with real downtime is a full cluster destroy and recreate — and that's a deliberate infrastructure operation, not something that happens during normal development.

---

## Gotchas & Tips

### Apple Silicon / ARM Macs

**Docker images must be built for linux/amd64 for Hetzner.** Your Mac builds ARM images by default. If you deploy an ARM image to Hetzner (x86), K8s will fail with `no match for platform in manifest`. Use `bb docker-push` which builds for amd64 automatically. For local dev (`bb docker-build`, `bb helm-local`), native ARM is fine.

### Rancher Desktop

**Use the dockerd backend, not containerd.** If `docker build` doesn't work, go to Rancher Desktop → Preferences → Container Engine → dockerd.

**Interactive prompts may print `^M`.** This is a terminal encoding issue with some macOS shells. The bb tasks use `-auto-approve` and `TERM=dumb` to avoid this. If it happens elsewhere, run `stty sane`.

### GHCR (GitHub Container Registry)

**Your `gh` token needs `write:packages` scope** to push images. Fix with `gh auth refresh --scopes write:packages`, then re-login Docker.

**GHCR packages are private by default.** Your Hetzner cluster can't pull private images without an imagePullSecret. Making the package public is the simplest solution for personal projects.

**When using GitHub Actions**, the package must be linked to the repo. Go to `github.com/YOUR_USER?tab=packages` → `myapp` → **Package settings → Manage Actions access → Add Repository → myapp → Write**.

**Workflow permissions** must be Read and Write. Go to your repo → **Settings → Actions → General → Workflow permissions → Read and write permissions**.

### Hetzner / Terraform

**Packer snapshots are a prerequisite.** kube-hetzner uses OpenSUSE MicroOS as the node OS. Packer creates snapshot images in your Hetzner project. This only needs to be done once per project — the snapshots persist even after `terraform destroy`.

**SSH key conflicts.** Packer and Terraform both try to create an SSH key called "k3s". If one already exists from a previous run, delete it from the Hetzner Console (Security → SSH Keys).

**Server types were renamed.** Hetzner deprecated CX22/CX32 and replaced them with CX23/CX33 (Gen3). The config already uses the new names.

**Location availability varies.** Not all server types are available in all locations. The config uses `nbg1` (Nuremberg). If it's unavailable, try `hel1` (Helsinki) or `fsn1` (Falkenstein).

**Billing is hourly.** `bb tf-destroy` deletes everything and billing stops immediately. You pay cents for a few hours of testing.

**Terraform state is critical.** `terraform.tfstate` maps your config to real resources. If you lose it, Terraform tries to create duplicates and fails. Back it up. The `.gitignore` keeps it out of git because it contains secrets.

### JVM Startup & Health Probes

**The JVM takes 15-30 seconds to start** on small instances, longer with the OTel agent. Kubernetes health probes check if the app is alive (`livenessProbe`) and ready for traffic (`readinessProbe`). If the app isn't responding when the probe fires, K8s kills and restarts it — creating a restart loop (`CrashLoopBackOff`). The `initialDelaySeconds` is set to 45 to give the JVM plenty of time.

**OTel agent is disabled by default** because it adds startup time and tries to connect to Alloy. Enable it only after `bb monitoring-install`.

### TLS Certificates

**Certificates renew automatically.** cert-manager renews at day 60 of 90 with retry backoff. See Step 7 for details.

**Let's Encrypt no longer sends expiry emails** (discontinued June 2025). Monitor with `bb cert-status` or the Grafana alert described in Step 9.

**ClusterIssuer must be recreated after `bb tf-destroy`.** Run `bb cluster-issuer` each time you bring the cluster back up.

**Rate limits:** 50 certificates per domain per week. Unlikely to hit with a single domain, but be aware if you destroy/recreate frequently.

### Monitoring

**Install order matters.** Loki first (claims `minio-sa`), then standalone MinIO as `mimir-minio-sa`. If you see a ServiceAccount conflict, run `bb monitoring-uninstall` then `bb monitoring-install`. See Step 9 for details.

**Grafana:** access via `bb grafana` (port-forward). Login: credentials from your password manager (set when you ran `bb monitoring-seal-secrets`).

### Debugging Checklist

When pods aren't starting, work through this in order:

```bash
bb k8s-status         # What state are pods in?
bb k8s-describe       # Look at the Events section at the bottom
bb k8s-logs           # What is the app printing to stdout?
```

Common patterns in `bb k8s-describe` Events:

| Event | Meaning | Fix |
|-------|---------|-----|
| `ImagePullBackOff` + `401 Unauthorized` | GHCR package is private | Make it public on GitHub |
| `ImagePullBackOff` + `no match for platform` | Built for ARM, Hetzner needs amd64 | `bb docker-push` |
| `Liveness probe failed` + `connection refused` | App not ready in time | Increase `initialDelaySeconds` |
| `CrashLoopBackOff` | App crashes on startup | Check `bb k8s-logs` for the exception |
| `Pending` + `no nodes available` | Cluster full or node not ready | `kubectl get nodes` |
