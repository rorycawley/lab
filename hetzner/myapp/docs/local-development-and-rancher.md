# Local Development and Rancher Desktop

> **What this doc is:** Your daily reference for the local development loop. It covers the REPL workflow, Docker builds, deploying to local K8s, and debugging when things go wrong. This is the doc you'll use most often.
>
> **What this doc is not:** A conceptual explainer. If you want to understand *why* we use Helm, what Kubernetes concepts mean, or how the Helm chart maps to K8s resources, see the main [GUIDE.md](../GUIDE.md), Step 3.

---

## Prerequisites

Before starting, you need these installed:

| Tool | Install | Verify |
|------|---------|--------|
| Java (JDK 21+) | `brew install openjdk@21` | `java -version` |
| Clojure | `brew install clojure/tools/clojure` | `clj -version` |
| Babashka | `brew install borkdude/brew/babashka` | `bb --version` |
| Docker | Via Rancher Desktop (see below) | `docker version` |
| Helm | Via Rancher Desktop (pre-installed) | `helm version` |
| kubectl | Via Rancher Desktop (pre-installed) | `kubectl version --client` |

**Rancher Desktop setup:**

1. Download from [rancherdesktop.io](https://rancherdesktop.io)
2. Preferences → Container Engine → **dockerd** (not containerd)
3. Preferences → Kubernetes → enable, pick a stable version
4. Wait for the cluster to be ready (green indicator in the menu bar)

If `docker build` doesn't work, check the container engine setting. containerd doesn't support `docker build`.

---

## The Two Local Workflows

You have two distinct workflows on your laptop. They catch different problems.

**Workflow 1: REPL** — for application logic. Millisecond feedback. Use every day.

**Workflow 2: Local K8s** — for deployment validation. Catches container and Helm issues. Use before pushing changes that affect Dockerfile, Helm charts, environment variables, or health endpoints.

```
Edit code ──→ REPL (Workflow 1) ──→ Works? ──→ git push
                                       │
                               Deployment change?
                                       │
                                       ▼
                              bb helm-local (Workflow 2)
                                       │
                                  Works? ──→ git push
```

---

## Workflow 1: REPL Development

### Start

```bash
bb dev
# → nREPL server started on port 7888
```

Connect your editor to `localhost:7888`:
- **Calva (VS Code):** Ctrl+Shift+P → "Calva: Connect to a Running REPL Server"
- **Cursive (IntelliJ):** Run → Edit Configurations → Remote nREPL → port 7888
- **CIDER (Emacs):** `M-x cider-connect-clj` → localhost → 7888

### Boot the server

Evaluate in the REPL:

```clojure
(start)
;; → Server running on port 8080
```

### Verify

```bash
curl http://localhost:8080/health
# → {"status":"ok"}

curl http://localhost:8080/hello
# → {"message":"Hello, World!"}

curl http://localhost:8080/metrics
# → Prometheus text format (http_requests_total, jvm_memory_bytes_used, etc.)
```

### Edit → eval → verify

1. Edit a function in `src/myapp/core.clj`
2. Eval the changed form: `Ctrl+Enter` (Calva), `C-c C-c` (CIDER), `Ctrl+Shift+P` (Cursive)
3. Hit the endpoint — the change is live immediately

No restart needed. The server stays running.

### When to restart

Only call `(restart)` if you change server configuration (port, middleware stack, Jetty options). Route changes, handler changes, and business logic changes are picked up instantly via the var-based reloading trick.

**How the trick works:** `dev/user.clj` passes `#'core/app` (the *var*) to Jetty, not `core/app` (the *value*). Jetty dereferences the var on every request, so it always gets the latest version of your app.

### Files involved

| File | Role |
|------|------|
| `src/myapp/core.clj` | Application routes and handlers |
| `dev/user.clj` | REPL helpers: `(start)`, `(stop)`, `(restart)` |
| `deps.edn` | Dependencies |

### What this catches

Logic errors, wrong status codes, broken routes, incorrect response bodies, missing fields. Everything about whether your code does the right thing.

### What this doesn't catch

Whether your app starts inside a Docker container. Whether health probes pass. Whether Helm templates render correctly. Whether environment variables are set. That's Workflow 2.

---

## Workflow 2: Local Kubernetes (Rancher Desktop)

### Build and deploy

```bash
bb helm-local
```

This single command:
1. Builds the Docker image (native ARM for your Mac)
2. Deploys to Rancher Desktop's K8s cluster via Helm
3. Waits for pods to be healthy
4. Runs a smoke test against `/health`

### Verify

```bash
# Via ingress (Traefik routes by hostname)
curl http://myapp.localhost/health
# → {"status":"ok"}

# Via port-forward (always works, bypasses ingress)
bb k8s-port-forward
# then in another terminal:
curl http://localhost:8080/health
```

### What success looks like

```bash
bb k8s-status
# NAME                     READY   STATUS    RESTARTS   AGE
# myapp-6f7b8c9d4-abc12    1/1     Running   0          30s
```

`READY 1/1` and `STATUS Running` means the container started and the readiness probe passed.

### Clean up

```bash
bb helm-uninstall
```

### What this catches

| Problem | How it manifests | REPL would miss it? |
|---------|-----------------|---------------------|
| Dockerfile build failure | `bb helm-local` fails at build step | Yes — REPL doesn't use Docker |
| Missing dependency in uberjar | Pod crashes on startup | Yes — REPL loads deps directly |
| Health probe too aggressive | `CrashLoopBackOff` (K8s kills pod before JVM starts) | Yes — no probes in REPL |
| Environment variable missing | App starts but returns errors | Yes — your Mac has different env vars |
| Ingress routing broken | `curl` returns 404 | Yes — no ingress in REPL |
| `imagePullPolicy` wrong | `ImagePullBackOff` error | Yes — no image pulling in REPL |

### Why it works like production

`bb helm-local` uses `values-local.yaml`, and `bb helm-prod` uses `values-prod.yaml`. Both use the same templates in `helm/myapp/templates/`. The only differences:

| Setting | Local | Production |
|---------|-------|------------|
| `replicaCount` | 1 | 2 |
| `imagePullPolicy` | `Never` (use local image) | `Always` (pull from GHCR) |
| `ingress.host` | `myapp.localhost` | your domain |
| `ingress.tls` | false | true |

If it works in Rancher Desktop, it will work on Hetzner — with the exception of CPU architecture (local builds ARM, production needs amd64, but `bb docker-push` handles the cross-build).

---

## Docker (Without Kubernetes)

Sometimes you want to test the Docker image without K8s. This is useful for verifying the Dockerfile itself — the build stages, the uberjar, the JRE runtime, the non-root user.

### Build

```bash
bb docker-build
```

Builds for your Mac's native architecture (ARM). Fast — Docker caches the dependency layer, so only code changes trigger a rebuild.

### Run

```bash
bb docker-run
```

Runs the container standalone, mapping port 8080.

### Verify

```bash
curl http://localhost:8080/health
# → {"status":"ok"}
```

### What the Dockerfile does

```
Stage 1 (builder):
  Clojure + JDK image (~800MB)
  → copies deps.edn, downloads dependencies (cached layer)
  → copies source, builds uberjar

Stage 2 (runtime):
  JRE-only Alpine image (~80MB)
  → creates non-root user
  → copies uberjar from stage 1
  → copies OpenTelemetry Java agent
  → ENTRYPOINT: java -javaagent:otel.jar -jar myapp.jar
```

The `.dockerignore` excludes `terraform/`, `monitoring/`, `helm/`, etc. to keep the build context small.

---

## Debugging

### The three-command sequence

When something isn't working in local K8s, work through these in order:

```bash
bb k8s-status         # 1. What state are pods in?
bb k8s-describe       # 2. What do the Events say?
bb k8s-logs           # 3. What is the app printing?
```

### Reading `bb k8s-status`

```
NAME                     READY   STATUS             RESTARTS   AGE
myapp-6f7b8c9d4-abc12    1/1     Running            0          5m    ← healthy
myapp-6f7b8c9d4-def34    0/1     CrashLoopBackOff   3          2m    ← problem
myapp-6f7b8c9d4-ghi56    0/1     ImagePullBackOff   0          1m    ← problem
myapp-6f7b8c9d4-jkl78    0/1     Pending            0          30s   ← stuck
```

| Status | Meaning | Next step |
|--------|---------|-----------|
| `Running` + `1/1` | Healthy | Nothing to do |
| `Running` + `0/1` | Running but readiness probe failing | `bb k8s-logs` — app started but `/health` isn't responding |
| `CrashLoopBackOff` | App crashes on startup, K8s keeps restarting | `bb k8s-logs` — look for the exception |
| `ImagePullBackOff` | Can't pull the Docker image | `bb k8s-describe` — look at the Events |
| `Pending` | Pod can't be scheduled | `kubectl get nodes` — is the cluster ready? |
| `ContainerCreating` | Image pulled, container starting | Wait a moment, then re-check |

### Reading `bb k8s-describe` Events

Scroll to the bottom of the output — the **Events** section is what matters.

| Event | Meaning | Fix |
|-------|---------|-----|
| `ImagePullBackOff` + `401 Unauthorized` | Private image, no pull credentials | For local: set `imagePullPolicy: Never` in values-local.yaml |
| `ImagePullBackOff` + `not found` | Image doesn't exist locally | Run `bb docker-build` first |
| `Liveness probe failed` + `connection refused` | App not ready when probe fired | Increase `initialDelaySeconds` in values.yaml |
| `Back-off restarting failed container` | App crashed, K8s is waiting before retry | Check `bb k8s-logs` for the root cause |
| `FailedScheduling` + `Insufficient cpu/memory` | Cluster doesn't have enough resources | Reduce resource requests in values.yaml, or restart Rancher Desktop |

### Reading `bb k8s-logs`

This shows your app's stdout/stderr. Look for:

- Java stack traces (the actual exception that crashed the app)
- `Address already in use` (another process on port 8080 — stop it or change the port)
- `ClassNotFoundException` (dependency missing from the uberjar)
- `Connection refused` to an external service (the service isn't reachable from inside the container)

### Getting a shell inside the container

```bash
bb k8s-shell
# You're now inside the running container as the non-root 'app' user
# Useful for checking: file paths, env vars, network connectivity

env | grep OTEL          # check OTel environment variables
cat /app/myapp.jar       # verify the JAR exists
wget -qO- localhost:8080/health   # test from inside the pod
```

### Port-forwarding for direct access

```bash
bb k8s-port-forward
# Forwards localhost:8080 → pod:8080 (bypasses ingress entirely)
```

This is useful when ingress routing is broken — you can verify the app is healthy inside the pod even when the external URL returns 404.

---

## Quick Reference

### Commands

| Command | What it does | When to use |
|---------|-------------|-------------|
| `bb dev` | Start nREPL on port 7888 | Every day, first thing |
| `bb build` | Build uberjar | Rarely (Docker builds it for you) |
| `bb docker-build` | Build Docker image (ARM, local) | Before `bb docker-run` or `bb helm-local` |
| `bb docker-run` | Run container standalone | Testing the Dockerfile without K8s |
| `bb helm-local` | Build + deploy to Rancher Desktop | Before pushing deploy-related changes |
| `bb helm-uninstall` | Remove from local K8s | Cleaning up |
| `bb smoke-local` | Smoke test local K8s | Verifying after manual Helm changes |
| `bb k8s-status` | Show pod status | First debug step |
| `bb k8s-logs` | Tail app logs | Reading stdout/stderr |
| `bb k8s-describe` | Describe pods (Events section) | Diagnosing image pull and probe failures |
| `bb k8s-port-forward` | localhost:8080 → pod:8080 | Bypassing ingress for direct pod access |
| `bb k8s-shell` | Shell into running container | Checking env vars, files, connectivity |

### Files you'll edit

| File | What it is | Edit frequency |
|------|-----------|----------------|
| `src/myapp/core.clj` | App routes and handlers | Every day |
| `dev/user.clj` | REPL start/stop helpers | Rarely |
| `deps.edn` | Dependencies | When adding libraries |
| `Dockerfile` | Container build definition | When changing build/runtime |
| `helm/myapp/values.yaml` | Helm defaults | When changing resource limits, probes, ports |
| `helm/myapp/values-local.yaml` | Local overrides | When changing local-specific settings |
| `helm/myapp/templates/*.yaml` | K8s resource templates | When changing deployment structure |

### REPL commands

| REPL form | Effect |
|-----------|--------|
| `(start)` | Boot the HTTP server |
| `(stop)` | Stop the HTTP server |
| `(restart)` | Stop + start (use for config changes) |

---

## Common Scenarios

### "I changed a route and want to test it"

```
Edit core.clj → eval the form → curl the endpoint
```

No restart, no rebuild, no redeploy. Milliseconds.

### "I changed the Dockerfile and want to verify it builds"

```bash
bb docker-build
bb docker-run
curl localhost:8080/health
# Ctrl+C to stop
```

### "I changed Helm templates and want to test locally"

```bash
bb helm-local
curl http://myapp.localhost/health
```

### "I added a new dependency to deps.edn"

```bash
# In the REPL:
(restart)    # picks up new deps

# For Docker:
bb docker-build    # rebuilds dependency layer (slower, but cached next time)
```

### "My pod is in CrashLoopBackOff"

```bash
bb k8s-logs
# Look for the Java exception. Most common causes:
#   - Port conflict
#   - Missing env var
#   - Dependency not in uberjar
#   - OTel agent can't connect (disable it: otel.enabled: "false" in values)
```

### "bb helm-local worked but curl returns 404"

```bash
# Test the pod directly (bypasses ingress)
bb k8s-port-forward
curl localhost:8080/health
# If this works, the problem is ingress routing, not your app.

# Check ingress:
kubectl get ingress
# HOST should be myapp.localhost, ADDRESS should be populated
```

### "Docker build is slow"

Docker caches layers. The dependency layer (`clj -P`) is the slowest step but only rebuilds when `deps.edn` changes. If every build is slow, check:

```bash
cat .dockerignore
# Should exclude: terraform/, monitoring/, helm/, .git/, target/
# If .dockerignore is missing, Docker sends everything to the builder
```

### "I want a clean slate"

```bash
bb helm-uninstall                    # remove from K8s
docker rmi myapp:dev                 # remove local image
bb clean                             # remove target/
```
