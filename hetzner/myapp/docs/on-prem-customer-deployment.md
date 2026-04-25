# Deploying to a Customer's On-Prem Environment

> **Context:** This document is a companion to the main [GUIDE.md](../GUIDE.md). The guide covers deploying to your own Hetzner cluster. This document covers a different scenario: deploying into infrastructure that a customer owns and operates, where they dictate the tools. The example stack used throughout is Harbor (container registry), ArgoCD (GitOps deployments), and Rancher (cluster management) — a common enterprise combination.

---

## When This Scenario Comes Up

Enterprise customers often have their own Kubernetes platform. They've invested in tooling, security policies, and operational processes. They don't want you to bring your own infrastructure — they want your application to run on theirs, managed by their tools, governed by their policies.

This is fundamentally different from deploying to your own cluster:

| Your Hetzner setup | Customer on-prem |
|---------------------|-----------------|
| You provision infrastructure | Customer provides infrastructure |
| You choose the tools | Customer dictates the tools |
| You have cluster-admin | You get a namespace with limited permissions |
| You manage monitoring | Customer has existing monitoring |
| You manage secrets | Customer has existing secrets management |
| You control DNS and TLS | Customer controls DNS and TLS |
| You push deploys via GitHub Actions | Customer uses ArgoCD (pull-based GitOps) |
| Images are public on GHCR | Images are in private Harbor registry |

The good news: because this project uses standard Kubernetes manifests, standard OCI container images, standard Helm charts, Prometheus-format metrics, and OpenTelemetry for traces, the adaptation is configuration work — not a rewrite.

---

## What You Need to Know Before Starting

Before writing any code or configuration, have a conversation with the customer's platform team. The answers determine your `values-customer.yaml` and CI pipeline changes.

### Questions to Ask the Customer

**Registry:**
- What is the Harbor URL? (e.g. `harbor.customer.com`)
- Which Harbor project should we push to? (e.g. `myproject`)
- Will you provide a robot account for CI, or do we use OIDC?
- Is the cluster pre-configured with imagePullSecrets for Harbor, or do we need to create one?

**Deployment:**
- Is ArgoCD managing deployments? If so, do you create the ArgoCD Application or do we provide the YAML?
- Which Git server does ArgoCD watch? (GitHub, GitLab, Bitbucket, or an internal server)
- If ArgoCD watches our GitHub repo, does it need a deploy key or access token?
- Which namespace should the application deploy into?

**Networking:**
- Which ingress controller is installed? (nginx, Traefik, HAProxy, or a custom one)
- What ingress class should we use?
- Are there required ingress annotations? (e.g. proxy timeouts, body size limits, WAF integration)
- Is TLS terminated at the ingress, at a load balancer in front of the cluster, or somewhere else?
- Do you provide the TLS certificate, or should we use cert-manager with your internal CA?
- Is there a network proxy for outbound traffic? (affects image pulls and OTel exports)

**Monitoring:**
- Do you have an existing Prometheus/Grafana stack? If so, does it auto-discover pods with `prometheus.io/scrape` annotations?
- Where should OpenTelemetry traces be sent? What is the collector endpoint?
- Where do logs go? Is there a Fluentd/Fluent Bit/Loki already collecting stdout?

**Secrets:**
- Do you use HashiCorp Vault, or another secrets manager?
- Should we use the Vault sidecar injector, the CSI driver, or Kubernetes Secrets?
- Which Vault path should our application's secrets be stored under?

**Constraints:**
- Are there resource quotas on the namespace? (CPU/memory limits we must respect)
- Are there network policies restricting pod-to-pod or egress traffic?
- Is the cluster air-gapped (no outbound internet access)?
- Are there required pod security standards? (non-root, read-only filesystem, no privilege escalation)

### What You Provide to the Customer

- The Git repository URL containing the Helm chart
- Documentation of the `/health` endpoint (for their health monitoring)
- Documentation of the `/metrics` endpoint (Prometheus format, what metrics are exposed)
- The OTel service name and which spans are generated
- Resource requirements: CPU/memory requests and limits
- The container port (8080)
- Any environment variables the app needs (documented in `values.yaml`)

---

## What Stays the Same

This is the most important section. The reason the adaptation is manageable is that most of the project is untouched:

| Component | Changes? | Why it's portable |
|-----------|----------|-------------------|
| `src/myapp/core.clj` | No | It's a Clojure Ring app. It doesn't know what cluster it runs on. |
| `Dockerfile` | No | Produces a standard OCI image. Any registry can store it, any K8s can run it. |
| `helm/myapp/templates/` | No | Standard Kubernetes APIs (`apps/v1`, `networking.k8s.io/v1`, `policy/v1`). ArgoCD renders them identically to `helm upgrade`. |
| `deps.edn`, `build.clj` | No | Build tooling is environment-independent. |
| iapetos `/metrics` | No | Prometheus format is the universal standard. Every monitoring system scrapes it. |
| OTel Java agent | No | OTLP is vendor-neutral. Change the endpoint, not the agent. |
| `bb dev`, `bb helm-local` | No | Your local development workflow is unaffected. |

What changes is limited to: where images are pushed, where ArgoCD looks, and what values are in the customer-specific values file.

---

## Adapting to Harbor

Harbor is an open-source container registry with enterprise features: RBAC, vulnerability scanning, image signing, replication, and audit logging. It replaces GHCR in your pipeline.

### CI Pipeline Changes

The customer provides Harbor credentials — typically a robot account (a service account with push-only access, not a personal login). Update `ci.yaml`:

```yaml
# ci.yaml — Harbor version
name: CI
on:
  push:
    branches: [main]
  pull_request:

env:
  REGISTRY: harbor.customer.com
  IMAGE_NAME: myproject/myapp

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Login to Harbor
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ secrets.HARBOR_USERNAME }}
          password: ${{ secrets.HARBOR_PASSWORD }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          push: ${{ github.ref == 'refs/heads/main' }}
          platforms: linux/amd64
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
```

GitHub Secrets needed: `HARBOR_USERNAME`, `HARBOR_PASSWORD`.

If the customer uses an internal Git server (GitLab, Bitbucket) instead of GitHub, the same CI logic applies — GitLab CI and Bitbucket Pipelines have equivalent Docker build/push steps.

### Helm Values Changes

Create `values-customer.yaml`:

```yaml
# values-customer.yaml — customer on-prem with Harbor + nginx
replicaCount: 2

image:
  repository: harbor.customer.com/myproject/myapp
  tag: latest          # overridden by ArgoCD or CI commit
  pullPolicy: Always

# Harbor is private — the cluster needs credentials to pull
imagePullSecrets:
  - name: harbor-pull-secret

ingress:
  enabled: true
  className: nginx                  # customer's ingress controller
  host: myapp.customer.internal     # customer provides the hostname
  tls: true
  clusterIssuer: customer-ca        # customer's internal CA, not Let's Encrypt
  annotations: {}                   # customer may add WAF, rate limiting, etc.

# Point OTel at customer's collector
otel:
  enabled: "true"
  endpoint: "http://otel-collector.monitoring.svc:4318"

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Deployment Template: Adding imagePullSecrets Support

The current deployment template doesn't support `imagePullSecrets`. For Harbor (and any private registry), add this to `helm/myapp/templates/deployment.yaml`:

```yaml
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      terminationGracePeriodSeconds: 30
      containers:
        # ... rest of container spec
```

And add the default to `values.yaml`:

```yaml
imagePullSecrets: []
```

This is a no-op for Hetzner (where GHCR is public) and active for Harbor (where the registry is private). The change is backward-compatible.

### Storing Helm Charts in Harbor

Harbor supports OCI artifacts, which means it can store Helm charts alongside Docker images. If the customer wants the chart in Harbor (not just in Git):

```bash
# Package the chart
helm package ./helm/myapp

# Login to Harbor's OCI registry
helm registry login harbor.customer.com -u $HARBOR_USERNAME

# Push the chart
helm push myapp-0.1.0.tgz oci://harbor.customer.com/myproject
```

ArgoCD can then reference the chart from Harbor instead of Git. This is optional — most setups use Git-based charts because ArgoCD's Git integration is simpler and provides the audit trail.

---

## Adapting to ArgoCD

ArgoCD replaces your `cd.yaml` workflow. Instead of GitHub Actions pushing deployments, ArgoCD (running inside the customer's cluster) pulls changes from Git.

For the general ArgoCD concepts, push vs pull trade-offs, and the full migration steps, see [`docs/devops-and-gitops.md`](devops-and-gitops.md). This section focuses on the customer-specific considerations.

### What You Delete

Remove `.github/workflows/cd.yaml`. ArgoCD replaces it entirely. Your CI pipeline (`ci.yaml`) continues to build and push images — CI and CD are decoupled.

### The ArgoCD Application

The customer's platform team creates this. You provide them with the values to fill in:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default          # or a customer-specific ArgoCD project
  source:
    repoURL: https://github.com/rorycawley/myapp.git
    targetRevision: main
    path: helm/myapp
    helm:
      valueFiles:
        - values-customer.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp         # the namespace they've assigned to you
  syncPolicy:
    automated:
      prune: true            # delete resources removed from Git
      selfHeal: true          # revert manual kubectl edits
    syncOptions:
      - CreateNamespace=true
```

Key settings:

- `selfHeal: true` — if anyone manually edits a K8s resource, ArgoCD reverts it to match Git within minutes. This is the drift-detection benefit of pull-based GitOps.
- `prune: true` — if you remove a resource from the Helm chart, ArgoCD deletes it from the cluster. Without this, orphaned resources accumulate.
- `targetRevision: main` — ArgoCD watches the `main` branch. Some customers use a dedicated `deploy` or `release` branch instead.

### The Image Tag Problem

ArgoCD watches Git, not the container registry. When CI pushes a new image to Harbor, ArgoCD doesn't know about it until the image tag changes in Git. Three approaches:

**Approach 1: CI commits the tag (simplest)**

Add a step to `ci.yaml` that updates the image tag in `values-customer.yaml` and pushes the commit:

```yaml
- name: Update image tag
  run: |
    sed -i "s/tag: .*/tag: ${{ github.sha }}/" helm/myapp/values-customer.yaml
    git config user.name "CI Bot"
    git config user.email "ci@example.com"
    git add helm/myapp/values-customer.yaml
    git commit -m "ci: update image tag to ${{ github.sha }}"
    git push
```

ArgoCD sees the commit, detects the tag changed, and syncs. Simple, but CI needs write access to the repo, and it creates a lot of "ci: update" commits in the Git history.

**Approach 2: ArgoCD Image Updater**

The ArgoCD Image Updater is an add-on that watches the container registry for new tags and automatically updates the ArgoCD Application. No CI commit needed, no Git noise. The customer's platform team installs it:

```yaml
# Annotation on the ArgoCD Application
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: myapp=harbor.customer.com/myproject/myapp
    argocd-image-updater.argoproj.io/myapp.update-strategy: latest
```

This is cleaner but requires the Image Updater to be installed in the customer's cluster.

**Approach 3: Separate config repo**

Some enterprises keep application code and deployment config in separate repositories. CI pushes images to Harbor, then updates the image tag in a `myapp-deploy` repo. ArgoCD watches the deploy repo. This provides a cleaner separation of concerns and lets the platform team control the deploy repo's branch protection rules independently.

### What ArgoCD Replaces

| `cd.yaml` feature | ArgoCD equivalent |
|--------------------|-------------------|
| `helm upgrade --install` | ArgoCD sync (automatic or manual) |
| `kubectl rollout status` | ArgoCD health checks (built-in) |
| Smoke test (`curl /health`) | ArgoCD resource health assessment + custom health checks |
| `helm rollback` on failure | ArgoCD rollback (manual via UI or automatic via sync policies) |
| Slack notification of deploy | ArgoCD notifications controller (Slack, email, webhook) |

---

## Adapting to Rancher

Rancher is a Kubernetes management platform. It provisions and manages clusters (using RKE2, k3s, or imported clusters), provides centralised RBAC, and gives a unified UI across multiple clusters and data centres.

### Why Rancher Is Mostly Invisible to You

Rancher manages the cluster. You deploy to the cluster. From your Helm chart's perspective, a Rancher-provisioned cluster is just a Kubernetes cluster with a standard API. Your templates work identically whether the cluster was created by Rancher, Terraform, `kubeadm`, or a cloud provider.

What Rancher does affect is the environment around your application:

### Cluster Access

The customer provides a kubeconfig generated through Rancher's RBAC system. This kubeconfig is typically scoped:

- To a specific namespace (not cluster-admin)
- With a limited set of permissions (create/update deployments, services, ingress — not create namespaces or install CRDs)
- With a time-limited token that requires periodic refresh

Since ArgoCD handles deployment, you may not need direct `kubectl` access at all. But it's useful for debugging: `kubectl logs`, `kubectl describe`, `kubectl exec`.

### Ingress Controller

Rancher clusters typically use nginx-ingress (installed by Rancher as part of cluster provisioning), not Traefik. Your `values-customer.yaml` sets `ingress.className: nginx`. The Helm ingress template already supports custom annotations via `{{ .Values.ingress.annotations }}`, so customer-specific annotations (proxy timeouts, body size limits, IP whitelisting) go in the values file, not the template.

### TLS

The customer's environment may handle TLS differently from your Hetzner setup:

- **Customer provides the certificate** — TLS termination happens at a load balancer or reverse proxy in front of the cluster. Your ingress doesn't need TLS config at all. Set `ingress.tls: false`.
- **Customer runs cert-manager with an internal CA** — same pattern as Let's Encrypt, but the ClusterIssuer points to their internal CA instead of `acme-v02.api.letsencrypt.org`. Set `ingress.clusterIssuer` to their issuer name.
- **Customer uses a service mesh** (Istio, Linkerd) — mutual TLS is handled by the mesh. Your ingress may be replaced by an Istio VirtualService. This requires a different Helm template, but the application code is unaffected.

### Monitoring

Rancher installs its own monitoring stack — Rancher Monitoring, based on Prometheus Operator and Grafana. This means:

- **Metrics**: Your app's `prometheus.io/scrape: "true"` pod annotation is automatically discovered by Rancher's Prometheus. Your iapetos `/metrics` endpoint works without changes. The customer sees your metrics alongside their other applications in their shared Grafana.
- **Logs**: The customer typically runs Fluentd, Fluent Bit, or a similar log collector as a DaemonSet. It collects stdout/stderr from all containers. Your app writes to stdout — it works automatically.
- **Traces**: Point the OTel agent at the customer's collector endpoint. Change one value in `values-customer.yaml`: `otel.endpoint`. If the customer runs Jaeger instead of Tempo, it doesn't matter — OTLP is the standard, and both Jaeger and Tempo accept it.

You do **not** install the LGTM stack (`bb monitoring-install`) in the customer's cluster. They already have monitoring. You adapt to it.

### Namespaces, Quotas, and Network Policies

The customer assigns your application to a Rancher project — a logical grouping of namespaces with shared RBAC and resource quotas. Expect:

- **Resource quotas**: "Your namespace gets a maximum of 4 CPU cores and 8GB memory." Your Helm values must respect this — set `resources.requests` and `resources.limits` accordingly.
- **Network policies**: "Pods in your namespace can only talk to pods in your namespace and to the ingress controller." If your app needs to reach an external API, the customer may need to add an egress rule.
- **Pod security standards**: "Containers must run as non-root." The Dockerfile already creates a non-root user (`appuser`), so this is covered.

---

## The Complete Adapted Workflow

```
Your laptop
  │  bb dev → REPL → edit code → test
  │  bb helm-local → validate in local K8s
  │  git push
  ▼
GitHub Actions (ci.yaml only)
  │  Build Docker image for linux/amd64
  │  Push to harbor.customer.com/myproject/myapp:sha-abc123
  │  Update image tag in Git (commit + push)
  ▼
ArgoCD (in customer's Rancher-managed cluster)
  │  Detects Git commit with new image tag
  │  Renders Helm chart with values-customer.yaml
  │  Pulls image from Harbor
  │  Deploys to customer's namespace
  │  Self-heals if cluster state drifts from Git
  ▼
Application running
  │  /metrics → Rancher's Prometheus → Rancher's Grafana
  │  OTel traces → customer's collector → customer's trace backend
  │  stdout logs → customer's log aggregator
  │  TLS → handled by customer's ingress/load balancer
```

Your daily workflow doesn't change: `bb dev` → edit → test → `git push`. The difference is what happens after the push — ArgoCD pulls instead of GitHub Actions pushing. From your perspective as a developer, it's still "push code, it deploys."

---

## Complete Change Summary

### Files That Change

| File | Change | Details |
|------|--------|---------|
| `ci.yaml` | Registry target | Push to Harbor instead of GHCR |
| `ci.yaml` | Image tag commit | Add step to update tag in Git for ArgoCD |
| `cd.yaml` | **Delete** | ArgoCD replaces it |
| `values-customer.yaml` | **New file** | Harbor image repo, nginx ingress, customer OTel endpoint, resource limits |
| `values.yaml` | Add `imagePullSecrets: []` | Default for backward compatibility |
| `deployment.yaml` | Add `imagePullSecrets` block | Support private registries |

### Files That Don't Change

| File | Why |
|------|-----|
| `src/myapp/core.clj` | Application code is infrastructure-agnostic |
| `Dockerfile` | OCI images are universal |
| `helm/myapp/templates/` (except `imagePullSecrets` addition) | Standard Kubernetes APIs |
| `deps.edn`, `build.clj` | Build tooling is environment-independent |
| `bb.edn` | Local dev tasks (`bb dev`, `bb helm-local`) still work |

### Things You Don't Use

| Component | Why |
|-----------|-----|
| `terraform/` | Customer manages infrastructure via Rancher |
| `monitoring/` | Customer has their own monitoring stack |
| `helm/cluster-issuer.yaml` | Customer manages TLS |
| `bb tf-apply`, `bb tf-destroy` | No infrastructure to provision |
| `bb monitoring-install` | Customer's monitoring, not yours |
| `bb cluster-issuer` | Customer's cert-manager configuration |

### What the Customer Provides

| Item | How you use it |
|------|---------------|
| Harbor URL + robot account credentials | GitHub Secrets for CI |
| Namespace name | `values-customer.yaml` + ArgoCD Application destination |
| Ingress class + required annotations | `values-customer.yaml` |
| OTel collector endpoint | `values-customer.yaml` |
| ArgoCD Application YAML (or they create it) | Points to your Git repo |
| kubeconfig (optional, for debugging) | `export KUBECONFIG=...` |
| Resource quota limits | `values-customer.yaml` resources section |
| imagePullSecret name (if not cluster-wide) | `values-customer.yaml` |

---

## Common Complications

### Air-Gapped Environments

Some enterprise environments have no outbound internet access. This affects:

- **Docker build**: CI runs outside the cluster (on GitHub), so the build itself isn't affected. But if CI also runs inside the customer's network, the Dockerfile's `ADD` step (downloading the OTel agent from GitHub) will fail. Solution: pre-download the agent JAR and include it in the repo, or host it on an internal artifact server.
- **Helm chart dependencies**: If your chart depends on subcharts from public repos, they need to be vendored (included in the repo) or mirrored to Harbor.
- **Container base images**: The `eclipse-temurin` and `clojure` images come from Docker Hub. In an air-gapped environment, they need to be mirrored to Harbor. The customer's platform team usually handles this.

### Customer Uses GitLab/Bitbucket Instead of GitHub

ArgoCD supports GitHub, GitLab, Bitbucket, and generic Git servers. If the customer wants the source in their own Git server:

- Mirror or fork the repo to their Git server
- Point ArgoCD at their Git server URL
- CI runs on their GitLab CI / Bitbucket Pipelines instead of GitHub Actions
- The CI logic is the same — build, push to Harbor, update image tag

### Multiple Customer Deployments

If you deploy to several customers, each with different infrastructure:

```
helm/myapp/
├── values.yaml                 ← defaults
├── values-local.yaml           ← your laptop
├── values-prod.yaml            ← your Hetzner
├── values-customer-acme.yaml   ← ACME Corp (Harbor + nginx + Vault)
├── values-customer-globex.yaml ← Globex (Harbor + Traefik + Azure Key Vault)
└── values-customer-initech.yaml ← Initech (ECR + nginx + AWS Secrets Manager)
```

Each customer gets a values file. The templates are identical. This is the Helm portability payoff — one chart, many environments.

---

## Related Docs

| Topic | Document |
|-------|----------|
| Push vs pull GitOps, ArgoCD migration steps | [`docs/devops-and-gitops.md`](devops-and-gitops.md) |
| Vault integration for customer secrets | [`docs/secrets-management.md`](secrets-management.md) |
| Backup and DR in customer environments | [`docs/business-continuity.md`](business-continuity.md) |
| Cloud-specific deployment (AWS, Azure, GCP, Civo) | [`docs/multi-cloud.md`](multi-cloud.md) |
| Main deployment guide (Hetzner path) | [`GUIDE.md`](../GUIDE.md) |
