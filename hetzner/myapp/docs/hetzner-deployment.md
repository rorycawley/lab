# Deploying to Production on Hetzner

> **Context:** This document is a companion to the main [GUIDE.md](../GUIDE.md). It covers the complete production deployment path: provisioning a Kubernetes cluster on Hetzner, setting up DNS and TLS, deploying manually to learn the pipeline, then automating with GitHub Actions CI/CD. It also covers the cluster lifecycle (destroy, rebuild, billing) and Hetzner-specific troubleshooting.
>
> **Prerequisites:** You've completed the local development steps in the main guide (REPL works, Docker builds, `bb helm-local` deploys to Rancher Desktop). You're now ready to go to production.

---

## What You'll Have at the End

```
yourdomain.com → HTTPS → Hetzner load balancer → Traefik → your app (2 replicas)
                 ↑                                           ↑
         cert-manager auto-renews              health-checked, auto-restarted
         via Let's Encrypt                     rolling updates, auto-rollback
```

Specifically: a k3s Kubernetes cluster on Hetzner Cloud, running your Clojure app with TLS, health checks, rolling updates, and automated CI/CD. Push code to `main`, it's live in minutes.

**Estimated cost:** ~€30–35/month (billed hourly — destroy when not using it to stop billing).

---

## What You Need Before Starting

**Accounts:**
- Hetzner Cloud account ([console.hetzner.cloud](https://console.hetzner.cloud))
- GitHub account with a public repo for your app
- A domain name (any registrar — Namecheap, Cloudflare, etc.)

**Tools** (install once):

```bash
brew install terraform packer hcloud
```

You should already have `kubectl`, `helm`, `docker`, `gh`, and `bb` from the local dev setup.

**Environment variables** (add to your `.zshrc`):

```bash
export HCLOUD_TOKEN="your-hetzner-api-token"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"
export PROD_HOST="yourdomain.com"
export ACME_EMAIL="you@example.com"
```

---

## Step 1: Provision the Cluster

### Why Hetzner

Hetzner is 5-10× cheaper than AWS, GCP, or Azure for equivalent specs. The trade-off: no managed Kubernetes service (no EKS/GKE/AKS). Instead, we use kube-hetzner, an open-source Terraform module that provisions k3s — a lightweight, CNCF-certified Kubernetes distribution.

### What You Get

| Component | Spec | Cost |
|-----------|------|------|
| 1× control plane | CX23: 2 vCPU, 4GB RAM | ~€4/mo |
| 3× worker nodes | CX33: 4 vCPU, 8GB RAM each | ~€24/mo |
| 1× load balancer | LB11 | ~€6/mo |
| **Total** | | **~€34/mo** |

kube-hetzner also installs Traefik (ingress controller), cert-manager (TLS certificates), and Hetzner CSI driver (persistent volumes) automatically.

### Create Packer Snapshots (One-Time)

kube-hetzner uses OpenSUSE MicroOS as the node OS. Packer creates snapshot images in your Hetzner project. This only needs to be done once — the snapshots persist even after `terraform destroy`.

```bash
cd terraform
curl -sL https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/packer-template/hcloud-microos-snapshots.pkr.hcl \
  -o hcloud-microos-snapshots.pkr.hcl
packer init hcloud-microos-snapshots.pkr.hcl
packer build hcloud-microos-snapshots.pkr.hcl
```

**What success looks like:** Packer outputs snapshot IDs. You can see them in Hetzner Console → Snapshots.

**Common failure:** `SSH key "k3s" already exists`. Delete the stale key from Hetzner Console → Security → SSH Keys.

### Generate an SSH Key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hetzner
```

### Create the Cluster

```bash
bb tf-plan          # preview what will be created
bb tf-apply         # create it (takes ~5 minutes)
```

**What success looks like:** Terraform outputs `Apply complete! Resources: N added`. The cluster is running.

### Get the Kubeconfig

```bash
bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
```

**Verify:**

```bash
kubectl get nodes
# NAME          STATUS   ROLES                       AGE   VERSION
# control-1     Ready    control-plane,etcd,master   5m    v1.32.x+k3s1
# worker-1      Ready    <none>                      4m    v1.32.x+k3s1
# worker-2      Ready    <none>                      4m    v1.32.x+k3s1
# worker-3      Ready    <none>                      4m    v1.32.x+k3s1
```

Four nodes, all `Ready`. If any show `NotReady`, wait a minute — they're still initialising.

### ⚠️ Terraform State

`terraform/terraform.tfstate` is critical. It maps your Terraform config to real Hetzner resources. If you lose it, Terraform can't manage the cluster and will try to create duplicates.

The `.gitignore` excludes it from Git (it contains your API token). Back it up manually, or use a remote backend:

```hcl
# Add to main.tf for shared/backed-up state
terraform {
  backend "s3" {
    bucket = "myapp-terraform-state"
    key    = "hetzner/terraform.tfstate"
    region = "eu-central-1"
  }
}
```

---

## Step 2: DNS and TLS

### Why You Need Both

Without DNS, users can't reach your app by domain name. Without TLS, all traffic is unencrypted — browsers show warnings, search engines penalise you, and anyone on the network can read the data.

### How TLS Works in This Setup

```
Browser
  │  DNS: myappk8s.net → 46.225.42.154 (your load balancer)
  │  HTTPS (encrypted)
  ▼
Hetzner load balancer
  │  TCP passthrough (doesn't decrypt)
  ▼
Traefik (inside the cluster)
  │  Holds the TLS certificate (from cert-manager)
  │  Decrypts TLS → plain HTTP internally
  ▼
Your app (port 8080, plain HTTP)
```

Your app never handles TLS. It serves plain HTTP on port 8080. Traefik handles encryption at the edge. Note that traffic between Traefik and your app inside the cluster is unencrypted — this is standard for most Kubernetes deployments and is acceptable because in-cluster traffic doesn't traverse public networks. For environments requiring full end-to-end encryption (e.g., PCI-DSS), you'd add mTLS via a service mesh like Istio or Linkerd.

### The Certificate Trust Chain

Your certificate is issued by Let's Encrypt and vouched for by a trust chain:

```
ISRG Root X1 (root CA, in every browser since 2016)
  └── RSA or ECDSA Intermediate (e.g. R10, E5)
        └── yourdomain.com (your certificate, valid 90 days)
```

ISRG Root X1 is operated by the Internet Security Research Group, the nonprofit behind Let's Encrypt. It's the world's largest CA, used by over 700 million websites.

### How Automatic Renewal Works

cert-manager handles renewal without any manual intervention:

```
Day 0:   Certificate issued (valid 90 days)
Day 1-59: cert-manager does nothing
Day 60:  Triggers renewal → ACME challenge → new cert → stored in K8s Secret
Day 61-90: Old cert still valid as fallback
Day 90:  Old cert expires (already replaced at day 60)
```

If renewal fails, cert-manager retries with exponential backoff (1–32 hours between attempts), giving you 30 days of retries before the certificate actually expires.

**Important:** Let's Encrypt discontinued expiry warning emails in June 2025. You need your own monitoring — see the cert monitoring section below.

### Set Up DNS

**Get the load balancer IP:**

```bash
kubectl get svc -A | grep traefik
# Look at the EXTERNAL-IP column
```

**Create DNS records** at your registrar:

| Type | Host | Value | Purpose |
|------|------|-------|---------|
| A | `@` | load balancer IP | Root domain → your cluster |
| A | `*` | load balancer IP | All subdomains → your cluster |

The wildcard means you can add services at `grafana.yourdomain.com`, `api.yourdomain.com`, etc. without touching DNS again.

**Wait for propagation** (5-30 minutes):

```bash
dig yourdomain.com +short
# Should return your load balancer IP
```

### Set Up TLS

**Create the ClusterIssuer:**

```bash
bb cluster-issuer
# ✓ ClusterIssuer created (email: you@example.com, ingress: traefik)
```

This tells cert-manager how to talk to Let's Encrypt and which ingress controller to use for HTTP-01 challenges.

The ClusterIssuer is a Kubernetes resource — it doesn't survive `bb tf-destroy`. You must recreate it every time you rebuild the cluster. The certificate itself re-issues automatically when you redeploy the Ingress.

### Verify TLS After Deploying

After deploying (Step 3 or 4 below):

```bash
kubectl get certificate --watch
# Wait for READY: True (30-60 seconds)
```

Then:

```bash
curl https://yourdomain.com/health
# {"status":"ok"}
```

**If `READY` stays `False` for more than 2 minutes:**

```bash
kubectl describe certificate myapp-tls     # certificate status
kubectl describe order -A                  # ACME order status
kubectl describe challenge -A             # HTTP-01 challenge status
```

Common causes: DNS not propagated yet, wrong IP in DNS, ClusterIssuer misconfigured.

### Monitor Certificate Health

```bash
# Manual check
bb cert-status

# Grafana alert (PromQL) — fires if cert expires in < 14 days
certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 24 * 3600
```

If this alert fires, cert-manager has been failing to renew for at least 16 days. You still have 14 days to fix it.

---

## Step 3: First Manual Deploy

**Why do this manually?** CI/CD automates the deploy, but you need to understand each step before automating it. Once the manual deploy works, you automate it and never do it manually again.

### Push the Docker Image

Your `gh` CLI token needs `write:packages` scope:

```bash
gh auth refresh --scopes write:packages
```

Build for `linux/amd64` (Hetzner runs x86 — your Mac is ARM) and push:

```bash
bb docker-push
```

This auto-detects your GitHub username and pushes to `ghcr.io/YOUR_USER/myapp:latest`.

### Make the GHCR Package Public (First Time)

GHCR packages are private by default. Your Hetzner cluster doesn't have credentials to pull private images — it would need an `imagePullSecret`.

> **⚠️ Note:** Making the image public is a pragmatic shortcut for personal projects. For production services with proprietary code, you should configure an `imagePullSecret` instead, or use a private registry like Harbor. See [docs/on-prem-customer-deployment.md](on-prem-customer-deployment.md) for the private registry approach.

Go to `github.com/YOUR_USER?tab=packages` → click `myapp` → **Package settings → Danger Zone → Change visibility → Public**.

### Deploy

```bash
bb helm-prod
```

This auto-detects your GitHub username from `gh` and reads `PROD_HOST` from the environment. These are passed as `--set` flags to Helm, so `values-prod.yaml` never needs manual editing.

**What success looks like:**

```bash
curl https://yourdomain.com/health
# {"status":"ok"}
```

---

## Step 4: Automate with CI/CD

### Why Automate

Without CI/CD, deploying means: build image, push to GHCR, run Helm, check it worked — every time. With CI/CD, deploying means: `git push`. The pipeline builds, deploys, tests, and rolls back automatically.

### How It Works

CI and CD are separate workflows with different triggers:

| File | Trigger | What it does |
|------|---------|-------------|
| `ci.yaml` | Every push + PRs | Build Docker image (amd64), push to GHCR |
| `cd.yaml` | After CI succeeds on `main` | Deploy via Helm, smoke test, auto-rollback |

CI also runs on pull requests (builds but doesn't push) to catch build failures before merging. CD can be triggered manually from the GitHub Actions UI for redeploying without a code change.

### One-Time GitHub Setup

**1. `KUBE_CONFIG` secret** — your kubeconfig, base64-encoded:

```bash
base64 < myapp_kubeconfig.yaml | pbcopy
```

Go to your repo → **Settings → Secrets and variables → Actions → New repository secret** → paste.

> **⚠️ Note:** Storing a full kubeconfig as a CI secret is a pragmatic shortcut. It grants cluster-admin access to anyone who can read the secret. For production teams, consider OIDC federation (GitHub Actions → cloud IAM → short-lived tokens) or a service account with minimal RBAC permissions scoped to the app namespace.

**2. `PROD_HOST` variable** — your domain name (not a secret, it's not sensitive):

Go to **Settings → Secrets and variables → Actions → Variables tab → New repository variable**:
- Name: `PROD_HOST`
- Value: `yourdomain.com`

**3. GHCR package must be public** — GitHub Actions pushes the image, but the Hetzner cluster pulls it. If it's private, the pull fails with `ImagePullBackOff`.

**4. Workflow permissions** — your repo needs read/write permissions for `GITHUB_TOKEN`:

Go to **Settings → Actions → General → Workflow permissions → Read and write permissions**.

**5. Link GHCR package to repo** (if the package was created before the repo):

Go to `github.com/YOUR_USER?tab=packages` → `myapp` → **Package settings → Manage Actions access → Add Repository → myapp → Write**.

`GITHUB_TOKEN` is provided automatically by GitHub — no setup needed for GHCR push.

### The Daily Workflow

Once CI/CD is set up:

```
bb dev → edit code → test in REPL → git push → done
```

GitHub Actions does the rest. The deployment pipeline achieves zero-downtime rolling updates when replicas, probes, and rollout settings are configured correctly (which they are — `maxUnavailable: 0`, `maxSurge: 1`, readiness probes, and a PodDisruptionBudget are all in the Helm chart).

---

## How Traffic Flows

Once everything is deployed, three data flows are active.

### Deployment Flow

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
  │  creates new pods → waits for readiness → terminates old pods
  ▼
Live at https://yourdomain.com
```

### Request Flow

```
Browser
  │  DNS: yourdomain.com → load balancer IP
  │  HTTPS (encrypted)
  ▼
Hetzner load balancer (LB11)
  │  TCP passthrough
  ▼
Traefik (ingress controller)
  │  Decrypts TLS → reads Host header → routes to Service
  │  Plain HTTP from here
  ▼
K8s Service (myapp)
  │  Load-balances across healthy pods
  ▼
myapp pod 1  or  myapp pod 2
  │  Ring/Reitit handles the request
  ▼
Response flows back up the same path
```

### Monitoring Flow

```
myapp pod
  ├── /metrics (iapetos)           → Alloy scrapes every 15s  → Mimir
  ├── stdout/stderr                → Alloy reads log files    → Loki
  └── OTel agent (traces)          → Alloy receives OTLP      → Tempo
                                                                    │
                                         Grafana queries all three ◄─┘
```

Metrics are pulled (Alloy scrapes `/metrics`). Logs are collected (Alloy reads stdout). Traces are pushed (the OTel agent sends spans via OTLP/HTTP on port 4318 to Alloy). Grafana queries all three backends on demand.

---

## Managing the Cluster Lifecycle

### Destroying the Cluster

Billing is hourly. When you're done testing, destroy everything:

```bash
bb tf-destroy
```

This uninstalls apps and monitoring, deletes PVCs, waits for volumes to detach, destroys all Hetzner resources, and cleans up orphaned volumes. Billing should stop once all resources are removed — verify in Hetzner Console that no servers, load balancers, or volumes remain.

### Bringing the Cluster Back Up

```bash
# 1. Set tokens
export HCLOUD_TOKEN="your-token"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"

# 2. Recreate cluster
bb tf-apply

# 3. Get kubeconfig
bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml

# 4. Check if load balancer IP changed
kubectl get svc -A | grep traefik
# If EXTERNAL-IP changed → update DNS A records

# 5. Recreate ClusterIssuer
bb cluster-issuer

# 6. Install monitoring (optional, but recommended)
bb monitoring-install

# 7. Deploy app
bb helm-prod

# 8. Wait for TLS certificate
kubectl get certificate --watch
# READY=True → Ctrl+C

# 9. Verify
curl https://yourdomain.com/health
```

Total time: ~15 minutes from nothing to HTTPS.

### Updating GitHub Secrets After Rebuild

If you destroy and recreate the cluster, the kubeconfig changes. Update the `KUBE_CONFIG` secret in GitHub:

```bash
base64 < myapp_kubeconfig.yaml | pbcopy
```

Go to repo → **Settings → Secrets → KUBE_CONFIG** → update.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  YOUR MACHINE                                   │
│                                                 │
│  bb dev → REPL → edit → eval → instant feedback │
│  bb helm-local → test in local K8s              │
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

## Troubleshooting

### Packer / Snapshots

**`SSH key "k3s" already exists`** — delete it from Hetzner Console → Security → SSH Keys. Packer and Terraform both try to create this key.

**Snapshots persist across destroys.** You only run Packer once per Hetzner project. The snapshots survive `terraform destroy`.

### Terraform

**`terraform.tfstate` lost** — Terraform can't manage the cluster. Delete all resources from Hetzner Console manually (servers, load balancers, networks, volumes, SSH keys, firewalls), then `bb tf-apply` to start fresh.

**Server types unavailable** — not all types exist in all locations. The config uses `nbg1` (Nuremberg). Try `hel1` (Helsinki) or `fsn1` (Falkenstein) if unavailable.

**Server types renamed** — Hetzner deprecated CX22/CX32 and replaced them with CX23/CX33 (Gen3). The config already uses the new names.

### Docker / GHCR

**`ImagePullBackOff` + `401 Unauthorized`** — GHCR package is private. Make it public (see Step 3 above).

**`ImagePullBackOff` + `no match for platform in manifest`** — image was built for ARM (your Mac), but Hetzner needs `linux/amd64`. Use `bb docker-push` which builds for amd64 automatically.

**`gh auth` issues** — run `gh auth refresh --scopes write:packages`, then `echo $CR_PAT | docker login ghcr.io -u YOUR_USER --password-stdin`.

### Pods

**`CrashLoopBackOff`** — the app crashes on startup. Check `bb k8s-logs` for the exception. Common cause: the JVM needs more time to start than the liveness probe allows. `initialDelaySeconds` is set to 45, but if you've added heavy startup logic, increase it.

**Pods stuck in `Pending`** — not enough resources. Check `kubectl describe pod <name>` for `Insufficient cpu` or `Insufficient memory` events. Either reduce resource requests in `values-prod.yaml` or add a worker node in `main.tf`.

**OTel agent connection errors in logs** — the agent tries to connect to Alloy, which doesn't exist until you run `bb monitoring-install`. These errors are noisy but not fatal. Disable with `otel.enabled: "false"` in values (the default), or install monitoring first.

### TLS

**Certificate stays `READY: False`** — DNS not propagated (Let's Encrypt can't reach your server), wrong IP in DNS records, or ClusterIssuer misconfigured. Run `kubectl describe challenge -A` for the specific error.

**`SSL certificate problem: unable to get local issuer certificate`** — certificate hasn't been issued yet. Wait and retry.

**Rate limits** — Let's Encrypt allows 50 certificates per domain per week. Unlikely to hit with one domain, but be aware if you destroy/recreate frequently.

### Debugging Sequence

When something isn't working, follow this order:

```bash
bb k8s-status         # What state are pods in?
bb k8s-describe       # Look at Events section at the bottom
bb k8s-logs           # What is the app printing to stdout?
bb k8s-shell          # Shell into a running pod to investigate
```

The Events section of `bb k8s-describe` almost always tells you what went wrong — image pull errors, probe failures, resource limits, scheduling issues.

---

## Quick Reference

### Commands

| Task | Command |
|------|---------|
| Preview cluster changes | `bb tf-plan` |
| Create/update cluster | `bb tf-apply` |
| Get kubeconfig | `bb tf-kubeconfig` |
| Destroy cluster (stop billing) | `bb tf-destroy` |
| Create ClusterIssuer | `bb cluster-issuer` |
| Check certificate status | `bb cert-status` |
| Build + push image | `bb docker-push` |
| Deploy to production | `bb helm-prod` |
| Smoke test production | `bb smoke-prod` |
| Install monitoring | `bb monitoring-install` |
| Open Grafana | `bb grafana` |
| Show pod status | `bb k8s-status` |
| Tail app logs | `bb k8s-logs` |
| Debug pod issues | `bb k8s-describe` |
| Shell into pod | `bb k8s-shell` |

### Environment Variables

```bash
export HCLOUD_TOKEN="your-hetzner-api-token"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"
export PROD_HOST="yourdomain.com"
export ACME_EMAIL="you@example.com"
export KUBECONFIG="$(pwd)/myapp_kubeconfig.yaml"
```

### GitHub Repository Setup (One-Time)

| Setting | Where | Value |
|---------|-------|-------|
| `KUBE_CONFIG` secret | Settings → Secrets → Actions | base64-encoded kubeconfig |
| `PROD_HOST` variable | Settings → Variables → Actions | `yourdomain.com` |
| Workflow permissions | Settings → Actions → General | Read and write |
| GHCR visibility | github.com/USER?tab=packages → myapp | Public |
| GHCR repo link | Package settings → Manage Actions access | Add repo with Write |

---

## Related Docs

| Topic | Document |
|-------|----------|
| Local development and K8s validation | [GUIDE.md](../GUIDE.md) — Steps 1-3 |
| DevOps and GitOps principles | [docs/devops-and-gitops.md](devops-and-gitops.md) |
| Deploying to other clouds | [docs/multi-cloud.md](multi-cloud.md) |
| Customer on-prem deployment | [docs/on-prem-customer-deployment.md](on-prem-customer-deployment.md) |
| Secrets management | [docs/secrets-management.md](secrets-management.md) |
| Business continuity | [docs/business-continuity.md](business-continuity.md) |
| Observability deep-dive | [GUIDE.md](../GUIDE.md) — Step 9 |
