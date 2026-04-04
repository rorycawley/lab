# Clojure on Kubernetes: End-to-End Guide

## Project Structure

```
myapp/
├── src/myapp/core.clj          ← the app (ring + reitit + metrics)
├── dev/user.clj                ← REPL dev namespace
├── deps.edn                   ← dependencies
├── build.clj                  ← uberjar build script
├── bb.edn                     ← babashka task runner
├── Dockerfile                 ← multi-stage build + OTel agent
├── .github/workflows/
│   └── deploy.yaml            ← CI/CD pipeline
├── helm/myapp/
│   ├── Chart.yaml
│   ├── values.yaml            ← defaults
│   ├── values-local.yaml      ← Rancher Desktop
│   ├── values-prod.yaml       ← Hetzner production
│   └── templates/
│       ├── deployment.yaml    ← includes OTel + Prometheus annotations
│       ├── service.yaml
│       └── ingress.yaml
├── monitoring/                ← Grafana LGTM stack
│   ├── install.sh             ← one-command setup
│   ├── values-minio.yaml      ← object storage
│   ├── values-loki.yaml       ← logs
│   ├── values-tempo.yaml      ← traces
│   ├── values-mimir.yaml      ← metrics
│   ├── values-grafana.yaml    ← dashboards (datasources pre-configured)
│   └── values-alloy.yaml      ← collection agent
└── terraform/
    └── main.tf                ← kube-hetzner cluster (3× CX33 workers)
```

---

## Step 1: The Development Loop (REPL)

This is the heart of Clojure development. You rarely restart anything.

**Start the REPL:**

```bash
bb dev
# → nREPL server started on port 7888
```

**Connect your editor** (Calva, Cursive, or CIDER) to `localhost:7888`.

**Boot the server** — evaluate in your editor's REPL:

```clojure
(start)
;; → Server running → http://localhost:8080/health
```

**The key trick:** `dev/user.clj` passes `#'core/app` (the *var*) to Jetty, not `core/app` (the *value*). This means when you re-evaluate a route definition in `core.clj`, the running server picks it up immediately. No restart needed.

**Typical flow:**

1. Edit a route in `core.clj`
2. Eval the changed form (Ctrl+Enter in Calva, C-c C-c in CIDER)
3. Hit the endpoint in your browser — change is live
4. Only call `(restart)` if you change server config like the port

---

## Step 2: Dockerfile Explained

The Dockerfile has two stages:

**Stage 1 (builder):** Starts from a full Clojure+JDK image. Copies `deps.edn` first and runs `clj -P` to download dependencies. This layer is cached — rebuilds are fast unless you change dependencies. Then copies source and builds the uberjar.

**Stage 2 (runtime):** Starts from a tiny JRE-only Alpine image (~80MB). Copies only the uberjar. Runs as a non-root user. That's it.

**Test locally:**

```bash
bb docker-build          # build the image
bb docker-run            # run standalone (no K8s)
curl localhost:8080/health
```

---

## Step 3: Local Kubernetes with Rancher Desktop

Since you use Rancher Desktop, you already have a K8s cluster and Helm available. The Helm chart works identically locally and in production — only the `values-*.yaml` file changes.

**Key difference for local:** `imagePullPolicy: Never` tells K8s to use the Docker image you built locally instead of trying to pull from a registry.

**Deploy locally:**

```bash
bb helm-local
# This runs:  docker build → helm upgrade --install

bb k8s-status            # check pods are running
bb k8s-logs              # tail the logs
```

**Access the app:**

```bash
# Option A: via ingress (if Traefik is running in Rancher Desktop)
curl http://myapp.localhost/health

# Option B: port-forward (always works)
bb k8s-port-forward
curl http://localhost:8080/health
```

**Debug a failing pod:**

```bash
bb k8s-describe          # shows events (image pull errors, crash loops, etc.)
bb k8s-logs              # application-level logs
bb k8s-shell             # get a shell inside the container
```

**Tear it down:**

```bash
bb helm-uninstall
```

---

## Step 4: Manual Deploy to Hetzner

Before setting up CI/CD, deploy manually. There are several one-time setup steps.

**4a. GHCR authentication:**

Your GitHub token needs the `write:packages` scope:

```bash
gh auth refresh --scopes write:packages
```

**4b. Build and push (one command):**

```bash
bb docker-push
```

This builds for `linux/amd64` (required — Hetzner runs x86, not ARM), logs into GHCR via `gh`, and pushes.

If `bb docker-push` fails, do it manually:

```bash
GH_USER=$(gh api user -q .login)
gh auth token | docker login ghcr.io -u $GH_USER --password-stdin
docker build --platform linux/amd64 -t ghcr.io/$GH_USER/myapp:latest .
docker push ghcr.io/$GH_USER/myapp:latest
```

**4c. Make the GHCR package public (first time only):**

GHCR packages are private by default. Your Hetzner cluster can't pull private images without an imagePullSecret.

Go to `github.com/YOUR_USER?tab=packages` → click `myapp` → **Package settings → Danger Zone → Change visibility → Public**.

**4d. Update values-prod.yaml:**

Change the two placeholder values:

```yaml
image:
  repository: ghcr.io/YOUR_GITHUB_USER/myapp    # ← your GitHub username
ingress:
  host: YOUR_DOMAIN.com                          # ← your domain
```

**4e. Point kubectl at your Hetzner cluster and deploy:**

```bash
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
bb helm-prod
```

`bb helm-prod` will check that `values-prod.yaml` has no unfilled placeholders before deploying. If you forgot to update them, it will tell you exactly what to change.

**4f. Verify:**

```bash
bb k8s-status            # pods should be Running
kubectl port-forward svc/myapp 8080:8080
curl http://localhost:8080/health
```

---

## Step 5: GitHub Actions CI/CD (optional)

The pipeline (`.github/workflows/deploy.yaml`) automates this on every push to `main`:

1. Builds the Docker image for linux/amd64
2. Pushes it to GitHub Container Registry (GHCR) tagged with the commit SHA
3. Deploys via Helm, waits for rollout, runs smoke test
4. Auto-rolls back if the smoke test fails

**One-time setup — two GitHub secrets needed:**

1. `GITHUB_TOKEN` — already available automatically, used for GHCR push
2. `KUBE_CONFIG` — your Hetzner cluster kubeconfig, base64-encoded:

```bash
base64 -w0 < myapp_kubeconfig.yaml | pbcopy   # macOS
# Paste into GitHub → Settings → Secrets → KUBE_CONFIG
```

**Important:** Update `values-prod.yaml` with your actual GitHub username and domain before your first deploy.

---

## Step 6: Hetzner Cluster with kube-hetzner

This is a one-time setup that creates a k3s cluster on Hetzner Cloud.

**Estimated cost: ~€30–35/month** (includes capacity for LGTM stack)
- 1× control plane (CX23: 2 vCPU, 4GB) — ~€4/mo
- 3× worker nodes (CX33: 4 vCPU, 8GB each) — ~€24/mo
- 1× load balancer (LB11) — ~€6/mo

**Setup steps:**

```bash
# 1. Create Hetzner Cloud project + API token
#    https://console.hetzner.cloud → Security → API Tokens

# 2. Generate SSH key for the cluster
ssh-keygen -t ed25519 -f ~/.ssh/hetzner

# 3. Export token
export HCLOUD_TOKEN="your-token-here"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"

# 4. Create MicroOS snapshots (one-time, takes ~5 minutes)
cd terraform
curl -sL https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/packer-template/hcloud-microos-snapshots.pkr.hcl -o hcloud-microos-snapshots.pkr.hcl
packer init hcloud-microos-snapshots.pkr.hcl
packer build hcloud-microos-snapshots.pkr.hcl

# 5. Create the cluster
terraform init
bb tf-plan               # preview what will be created
bb tf-apply              # create it (takes ~5 minutes)

# 6. Get kubeconfig
bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
kubectl get nodes        # should show 4 nodes

# 7. Tear down when done (stops billing)
bb tf-destroy
```

**⚠️ Terraform state file:** The file `terraform/terraform.tfstate` tracks what Terraform has created. If you delete it (e.g. by re-extracting the project tarball), Terraform loses track of your cluster. The cluster keeps running and billing, but Terraform can't manage it. If this happens, delete all resources from the Hetzner Console (servers, load balancers, networks, firewalls, SSH keys, placement groups) and run `terraform apply` again.

**Getting the kubeconfig:** After `bb tf-apply`, regenerate it with:

```bash
bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
```

This handles the `^M` character stripping automatically.

**Bringing the cluster back up after `bb tf-destroy`:**

```bash
# 1. Set tokens
export HCLOUD_TOKEN="your-token-here"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"

# 2. Recreate cluster (terraform init runs automatically if needed)
bb tf-apply

# 3. Get kubeconfig
bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml

# 4. Check if load balancer IP changed
kubectl get svc -A | grep traefik
# If IP changed → update A records in your DNS provider

# 5. Recreate ClusterIssuer (not persisted across destroys)
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            class: traefik
EOF

# 6. Deploy app
bb helm-prod

# 7. Wait for TLS certificate
kubectl get certificate --watch
# READY=True → Ctrl+C

# 8. Verify
curl https://yourdomain.com/health
```

---

## Step 6b: DNS + TLS

**6b.1. Get the load balancer IP:**

```bash
kubectl get svc -A | grep traefik
# Look at the EXTERNAL-IP column
```

**6b.2. Register a domain** (or use one you have) and create DNS records:

| Type | Host | Value |
|------|------|-------|
| A | `@` | your load balancer IP |
| A | `*` | your load balancer IP |

The `*` wildcard covers subdomains like `grafana.yourdomain.com`.

**6b.3. Wait for DNS propagation** (5-30 minutes):

```bash
dig yourdomain.com +short
# Should return your load balancer IP
```

**6b.4. Create the Let's Encrypt ClusterIssuer:**

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            class: traefik
EOF
```

**6b.5. Deploy with TLS:**

Make sure `values-prod.yaml` has your domain set, then:

```bash
bb docker-push
bb helm-prod
```

**6b.6. Wait for the certificate:**

```bash
kubectl get certificate --watch
# Wait until READY shows True, then Ctrl+C
```

**6b.7. Verify:**

```bash
curl https://yourdomain.com/health
# Should return: {"status":"ok"}
```

---

## Step 7: The Full Picture

```
┌─────────────────────────────────────────────────┐
│  YOUR MACHINE (Rancher Desktop)                 │
│                                                 │
│  bb dev → REPL → edit → eval → instant feedback │
│                                                 │
│  bb helm-local → same Helm chart as prod        │
│  bb k8s-logs   → debug in real K8s locally      │
└────────────────────┬────────────────────────────┘
                     │ bb docker-push + bb helm-prod
                     │ (or: git push → GitHub Actions)
                     ▼
┌─────────────────────────────────────────────────┐
│  HETZNER (kube-hetzner k3s cluster, nbg1)       │
│                                                 │
│  yourdomain.com → Traefik → TLS (Let's Encrypt) │
│  2 replicas → /health checked continuously      │
│  Grafana LGTM → metrics, logs, traces           │
└─────────────────────────────────────────────────┘
```

---

## Quick Reference: bb tasks

| Task | What it does |
|------|-------------|
| `bb dev` | Start nREPL on port 7888 |
| `bb build` | Build uberjar |
| `bb docker-build` | Build Docker image (native platform, for dev) |
| `bb docker-run` | Run image standalone |
| `bb docker-push` | Build for amd64 + push to GHCR (for Hetzner) |
| `bb helm-local` | Build + deploy to Rancher Desktop K8s + smoke test |
| `bb helm-uninstall` | Remove from local K8s |
| `bb helm-prod` | Deploy to Hetzner production + smoke test |
| `bb smoke-local` | Smoke test local K8s deployment |
| `bb smoke-prod` | Smoke test production (reads host from values-prod.yaml) |
| `bb k8s-status` | Show pod status |
| `bb k8s-logs` | Tail logs |
| `bb k8s-describe` | Debug pod issues |
| `bb k8s-port-forward` | localhost:8080 → pod |
| `bb k8s-shell` | Shell into running pod |
| `bb tf-plan` | Preview Terraform changes |
| `bb tf-apply` | Apply Terraform (auto-inits if needed) |
| `bb tf-destroy` | Destroy Hetzner cluster (stops billing) |
| `bb tf-kubeconfig` | Regenerate kubeconfig from Terraform state |
| `bb monitoring-install` | Install full LGTM stack |
| `bb monitoring-status` | Show monitoring pods |
| `bb monitoring-uninstall` | Remove LGTM stack |
| `bb grafana` | Port-forward Grafana → localhost:3000 |

---

## Step 8: Observability — Grafana LGTM Stack

The full stack gives you three pillars of observability:

```
Your Clojure App
  ├── /metrics endpoint (iapetos)  ──→  Alloy  ──→  Mimir   ──→ ┐
  ├── stdout logs                  ──→  Alloy  ──→  Loki    ──→ ├─→ Grafana
  └── OTel Java agent (traces)    ──→  Alloy  ──→  Tempo   ──→ ┘
                                                        ▲
                                          MinIO (object storage for all three)
```

**Components:**

| Component | Role | Mode |
|-----------|------|------|
| MinIO | S3-compatible object storage | standalone |
| Mimir | Metrics storage (replaces Prometheus) | monolithic |
| Loki | Log aggregation | monolithic |
| Tempo | Distributed tracing | monolithic |
| Alloy | Collection agent (scrapes + ships everything) | DaemonSet |
| Grafana | Dashboards + alerting | single replica |

All components run in monolithic/single-binary mode to keep pod count and memory usage reasonable on a small cluster.

**Install the stack:**

```bash
bb monitoring-install
# Takes ~3 minutes, installs 6 Helm releases into the "monitoring" namespace

bb monitoring-status          # verify all pods are running
bb grafana                    # port-forward → http://localhost:3000
```

**What you get out of the box:**

1. **Metrics** — Alloy auto-scrapes any pod with the `prometheus.io/scrape: "true"` annotation. Your app exposes JVM metrics (heap, GC, threads) and HTTP request metrics (count, latency histogram) via iapetos at `/metrics`.

2. **Logs** — Alloy collects stdout/stderr from every pod and ships to Loki. In Grafana, go to Explore → Loki → `{app="myapp"}` to search your logs.

3. **Traces** — The OpenTelemetry Java agent (bundled in the Docker image) auto-instruments Jetty, HTTP clients, and JDBC. Trace spans are sent via OTLP to Alloy → Tempo. In Grafana, Explore → Tempo to search traces. Click a traceID in a log line to jump directly to the trace.

**How your app is instrumented (zero code needed for traces):**

- `iapetos` (in `core.clj`) → exposes `/metrics` with Prometheus format
- `opentelemetry-javaagent.jar` (in Dockerfile) → auto-instruments Jetty, emits trace spans via OTLP
- Logs → just `println` to stdout, Alloy picks them up

**Disabling tracing locally:**
The `values-local.yaml` sets `otel.enabled: "false"` so the OTel agent doesn't try to connect to a non-existent Alloy when running on Rancher Desktop.

**Enabling tracing in production:**
OTel is disabled by default in all values files. After installing the LGTM stack (`bb monitoring-install`), enable it:

```bash
# Edit helm/myapp/values-prod.yaml → otel.enabled: "true"
# Then redeploy:
bb helm-prod
```

**Changing credentials:**
Before going to production, update the passwords in:
- `monitoring/values-minio.yaml` → `rootPassword`
- `monitoring/values-grafana.yaml` → `adminPassword`
- Update the matching credentials in `values-loki.yaml`, `values-tempo.yaml`, `values-mimir.yaml`

---

## Gotchas & Tips

### Apple Silicon / ARM Macs

**Docker images must be built for linux/amd64 for Hetzner.** If you build on an M1/M2/M3 Mac without specifying the platform, K8s will fail with `no match for platform in manifest: not found`. Use `bb docker-push` which handles this automatically, or build manually with `docker build --platform linux/amd64`. For local dev (`bb docker-build`, `bb helm-local`), native ARM is fine since Rancher Desktop runs on your Mac.

### Rancher Desktop

**Use the dockerd backend, not containerd.** If `docker build` doesn't work, go to Rancher Desktop → Preferences → Container Engine → dockerd.

**Interactive prompts may print `^M`.** This is a terminal encoding issue. Either use non-interactive flags (e.g. `terraform apply -auto-approve`, which the bb tasks already do) or run `stty sane` to fix your terminal.

### GHCR (GitHub Container Registry)

**Your GitHub token needs `write:packages` scope** to push images. Fix with: `gh auth refresh --scopes write:packages`, then re-login Docker: `gh auth token | docker login ghcr.io -u YOUR_USER --password-stdin`.

**GHCR packages are private by default.** Your Hetzner cluster can't pull them. Either make the package public at `github.com/YOUR_USER?tab=packages → myapp → Package settings → Change visibility → Public`, or create a K8s imagePullSecret.

### Hetzner / Terraform

**Packer snapshots are a prerequisite.** Before your first `terraform apply`, you must create MicroOS snapshots with Packer. This only needs to be done once per Hetzner project. See Step 5 above.

**SSH key conflicts.** If Packer creates an SSH key called "k3s" and then Terraform tries to create one with the same name, you'll get `SSH key not unique`. Delete it from the Hetzner Console (Security → SSH Keys) and retry.

**Server types were renamed.** Hetzner deprecated CX22/CX32 and replaced them with CX23/CX33 (Gen3). If you see `server type cx22 not found`, update your `main.tf`.

**Location availability varies.** Some server types aren't available in all locations. If you see `server location disabled`, try a different location (`nbg1`, `hel1`, `fsn1`). Check availability with `hcloud server-type describe cx33`.

**Billing is hourly.** You're only charged for the time resources exist. `bb tf-destroy` deletes everything and billing stops immediately.

### JVM Startup & Health Probes

**The JVM takes 15–30 seconds to start** with the OTel agent, sometimes longer on small instances. `health.initialDelaySeconds` is set to 45 to account for this. If pods keep restarting (`CrashLoopBackOff`), check `bb k8s-describe` for `Liveness probe failed` and increase the delay.

**Disable OTel until the LGTM stack is installed.** The OTel Java agent tries to connect to Alloy on startup. If Alloy isn't running, it retries in a loop, adding startup time and noise to logs. OTel is disabled by default in all values files. Enable it in `values-prod.yaml` (`otel.enabled: "true"`) only AFTER running `bb monitoring-install`.

### Monitoring

**MinIO credentials:** All LGTM components reference the same MinIO password. If you change it in `values-minio.yaml`, you must also update it in `values-loki.yaml`, `values-tempo.yaml`, and `values-mimir.yaml`. A production setup would use K8s Secrets instead of inline passwords.

**kube-hetzner updates:** The Terraform module pins k3s and MicroOS versions. Run `terraform apply` periodically to pick up updates, but read the changelog first.

### Debugging Checklist

If your pods aren't starting, work through this:

```bash
bb k8s-status         # What state are pods in?
bb k8s-describe       # Look at Events section at the bottom
bb k8s-logs           # What is the app printing?
```

Common patterns in `bb k8s-describe`:

| Event | Meaning | Fix |
|-------|---------|-----|
| `ImagePullBackOff` + `401 Unauthorized` | GHCR package is private | Make it public on GitHub |
| `ImagePullBackOff` + `no match for platform` | Built for ARM, need amd64 | `bb docker-push` |
| `Liveness probe failed` + `connection refused` | App not ready in time | Increase `initialDelaySeconds` |
| `CrashLoopBackOff` | App crashes on startup | Check `bb k8s-logs` for the exception |

