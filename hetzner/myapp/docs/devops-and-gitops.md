# DevOps and GitOps in This Project

> **Context:** This document is a companion to the main [GUIDE.md](../GUIDE.md). The guide covers the practical steps to build and deploy the project. This document explains the DevOps and GitOps principles behind those steps — why the project is structured the way it is, what each practice gives you, and how to evolve toward more advanced patterns when the need arises.

---

## What DevOps Actually Is

DevOps is not a tool, a team name, or a job title. It's a set of practices that close the gap between writing code and running it in production.

Before DevOps, the typical flow looked like this: developers write code and hand it to a separate operations team. Operations manually provisions servers, installs dependencies, copies files, and restarts services. When something breaks, developers say "it works on my machine" and operations says "your code is broken." The feedback loop is slow, blame is easy, and reliability suffers.

DevOps replaces this with automation, shared responsibility, and fast feedback. You write code, push it, and a pipeline builds, tests, deploys, and monitors it — without manual steps. If something breaks, you see it in seconds, not days.

The principles below are not abstract ideals. Each one maps to a specific file, tool, or workflow in this project.

---

## DevOps Principles and Where They Live in This Project

### Infrastructure as Code

**Principle:** Infrastructure is defined in version-controlled files, not configured by hand.

**Where it lives:**

| What | File | Effect |
|------|------|--------|
| The Kubernetes cluster | `terraform/main.tf` | Describes every server, network, firewall rule, and load balancer |
| The application deployment | `helm/myapp/templates/` | Describes pods, services, ingress, and disruption budgets |
| The monitoring stack | `monitoring/values-*.yaml` | Describes every component of the LGTM stack |
| The CI/CD pipeline | `.github/workflows/ci.yaml`, `cd.yaml` | Describes every build and deploy step |

**What this gives you:** If someone asks "how is production configured?", the answer is in Git — not in someone's head, not in a wiki that's three months out of date. You can destroy the cluster and recreate an identical one in 15 minutes with `bb tf-apply`. You can diff any two versions of the infrastructure with `git diff`.

**The test:** delete everything. Can you rebuild from the repo alone? In this project, yes — `bb tf-apply` + `bb cluster-issuer` + `bb monitoring-install` + `bb helm-prod`. That's the IaC payoff.

### CI/CD (Continuous Integration / Continuous Delivery)

**Principle:** Every code change is automatically built, tested, and deployed without manual steps.

**Where it lives:**

- `ci.yaml` — triggered on every push and PR. Builds a Docker image for `linux/amd64`, pushes to GHCR with the commit SHA as the tag. Also runs on PRs (build-only, no push) to catch build failures before merging.
- `cd.yaml` — triggered after CI succeeds on `main`. Deploys via `helm upgrade`, waits for rollout, runs a smoke test against `/health`, and rolls back automatically if the smoke test fails.

**What this gives you:** Deploying is `git push`. There are no manual deployment steps, no "only one person knows how to deploy", no "deploy Fridays." Anyone on the team can push code and it goes live safely. The pipeline is the same every time — no human variation, no forgotten steps.

**The daily experience:**

```
bb dev → edit code → test in REPL → git push → walk away
```

CI/CD does the rest. You find out it worked from the green check on GitHub, or from the Slack notification if you've set up Grafana alerting.

### Immutable Infrastructure

**Principle:** You don't modify running infrastructure. You replace it.

**Where it lives:**

- The Dockerfile builds a new image for every change. You never SSH into a container to patch a file.
- Helm creates new pods with the new image and terminates old pods after the new ones are healthy (rolling update).
- If a server is misbehaving, you don't debug it — you destroy and recreate the cluster. The Terraform state and Helm chart reproduce the same result.

**What this gives you:** Reproducibility. If it worked once, it works again. There's no "server drift" where production slowly diverges from what you think it is because someone ran `apt-get install` three months ago and didn't tell anyone.

The phrase "cattle, not pets" captures it: you don't name your servers, nurse them back to health, or feel bad when they die. They're interchangeable units that can be replaced at any time.

### Environment Parity

**Principle:** Development, testing, and production should be as similar as possible.

**Where it lives:**

- The same Helm chart (`helm/myapp/templates/`) deploys to your local Rancher Desktop cluster and to Hetzner production. The only difference is the values file — `values-local.yaml` vs `values-prod.yaml`.
- The same Dockerfile builds the image for local testing and production. The only difference: local builds for your Mac's ARM architecture, production builds for `linux/amd64`.

**What this gives you:** "It works on my machine" is meaningful, because your machine runs the same Kubernetes manifests, the same health probes, the same ingress routing, and the same container image as production. If `bb helm-local` works, `bb helm-prod` will work (architecture aside).

### Monitoring and Observability

**Principle:** You don't wait for users to report problems. The system tells you.

**Where it lives:**

- iapetos exposes `/metrics` (request counts, latency histograms, JVM stats) in Prometheus format
- Alloy scrapes metrics → Mimir, collects logs → Loki, receives traces → Tempo
- Grafana dashboards and alert rules surface problems before users notice

**What this gives you:** When something goes wrong at 3am, you open Grafana and see: latency spiked, the JVM heap was full, GC was thrashing. You fix the actual problem instead of guessing. Alerting means you don't have to stare at dashboards — Slack or PagerDuty wakes you up when a threshold is crossed.

### Automated Recovery

**Principle:** The system heals itself without human intervention for common failures.

**Where it lives:**

| Failure | Automated response | Component |
|---------|-------------------|-----------|
| Pod crashes | K8s restarts it | kubelet |
| Pod is unresponsive | K8s kills and replaces it | Liveness probe |
| Bad deploy | Helm rolls back to previous version | `cd.yaml` smoke test |
| TLS certificate expiring | cert-manager renews it 30 days early | cert-manager |
| Node failure | K8s reschedules pods to healthy nodes | Scheduler + PDB |

**What this gives you:** You're not the system's life support. Common failures resolve themselves. You investigate the root cause later, from Grafana, rather than scrambling to restart services at 3am.

---

## What GitOps Is

GitOps takes Infrastructure as Code to its logical conclusion: **Git is the single source of truth for everything** — not just your application code, but your infrastructure, deployment configuration, monitoring setup, and pipeline definitions.

The core idea: the state of production should always match what's in Git. If you want to change something in production, change it in Git. The system detects the change and applies it.

### What's in Git (and What Isn't)

**In Git (the source of truth):**

| What | Where |
|------|-------|
| Application code | `src/myapp/core.clj` |
| Build definition | `Dockerfile`, `build.clj`, `deps.edn` |
| Deployment manifests | `helm/myapp/` |
| Infrastructure definition | `terraform/main.tf` |
| Monitoring configuration | `monitoring/values-*.yaml` |
| CI/CD pipeline | `.github/workflows/` |

**Not in Git (deliberately):**

| What | Why | Where instead |
|------|-----|---------------|
| Terraform state | Contains cloud API tokens | Local file or remote backend (S3) |
| Kubeconfig | Cluster admin credentials | Local file, GitHub Secret |
| MinIO/Grafana passwords | Sensitive values | GitHub Secrets, or Vault (see `docs/secrets-management.md`) |
| TLS certificates | Generated at runtime | Kubernetes Secrets (managed by cert-manager) |
| Metrics, logs, traces | Runtime data | Mimir, Loki, Tempo storage |

### The Audit Trail

Every production change has a Git commit. This is one of the most underrated benefits.

If something breaks after a deployment:

```bash
git log --oneline -5
# a1b2c3d ci: update image tag to sha-def456
# e4f5g6h feat: add /orders endpoint
# h7i8j9k fix: correct status code on /health
```

You can see exactly what changed, who changed it, and when. You can `git revert` and push — the pipeline rolls back production. You don't need to ask "who deployed last?" or check Slack history. The Git log is the authoritative record.

For compliance (SOC 2, ISO 27001), this audit trail is often a requirement, not a nice-to-have.

---

## Push-Based vs Pull-Based GitOps

### Push-Based (What This Project Uses)

An external system (GitHub Actions) pushes changes to the cluster when Git changes:

```
Developer pushes to main
  ↓
GitHub Actions
  ├── ci.yaml: build image → push to GHCR
  └── cd.yaml: helm upgrade → smoke test → rollback if failed
  ↓
Cluster updated
```

**Strengths:**
- Simple to set up and understand
- No extra infrastructure inside the cluster
- Familiar CI/CD model — most developers already know GitHub Actions
- Full control over the deployment sequence (build → deploy → test → rollback)

**Weaknesses:**
- No drift detection. If someone runs `kubectl edit deployment myapp` directly, Git doesn't know. The manual change persists until the next `git push` overwrites it.
- The CI/CD pipeline needs cluster credentials (the kubeconfig stored as a GitHub Secret). If those credentials leak, an attacker can deploy to your cluster.
- Deployment is coupled to the CI system. If GitHub Actions is down, you can't deploy (though you can still deploy manually with `bb helm-prod`).

### Pull-Based (ArgoCD, Flux)

An agent inside the cluster continuously watches Git and pulls changes:

```
Developer pushes to main
  ↓
CI builds image → pushes to registry → updates image tag in Git
  ↓
ArgoCD (inside the cluster)
  ├── Polls Git every 3 minutes
  ├── Detects: Git says image tag sha-abc123, cluster has sha-def456
  ├── Renders Helm chart with new values
  ├── Applies to cluster
  └── If someone manually edits the cluster → reverts to match Git (self-heal)
  ↓
Cluster always matches Git
```

**Strengths:**
- Drift detection and self-healing. The cluster always converges to match Git.
- No cluster credentials in CI. ArgoCD runs inside the cluster — it already has access.
- Multi-cluster support. One ArgoCD instance can manage dozens of clusters.
- Progressive delivery. ArgoCD supports canary releases, blue-green deployments, and rollback policies.
- UI for deployment visibility. ArgoCD has a web dashboard showing sync status, resource health, and deployment history.

**Weaknesses:**
- More infrastructure to manage. ArgoCD is itself a complex system with its own RBAC, OIDC integration, and storage.
- The image tag update problem. CI builds an image, but ArgoCD watches Git, not the registry. You need a mechanism to update the image tag in Git after CI pushes the image. Options: CI commits the tag, ArgoCD Image Updater watches the registry, or Kustomize overlays.
- Learning curve. ArgoCD concepts (Applications, AppProjects, sync policies, sync waves) take time to learn.

### When to Use Which

| Situation | Recommendation |
|-----------|---------------|
| Solo developer, personal project | Push-based (simpler, less overhead) |
| Small team (2-5), single cluster | Push-based (unless you need drift detection) |
| Multiple environments (dev/test/UAT/prod) | Either — pull-based starts to pay off |
| Multiple clusters | Pull-based (ArgoCD manages them centrally) |
| Compliance requirements (SOC 2, regulated industry) | Pull-based (drift detection provides evidence of control) |
| Customer on-prem deployment | Pull-based (customer likely already runs ArgoCD) |

This project starts push-based. That's the right choice for a solo developer learning the pipeline. The evolution to pull-based is documented below.

---

## Evolving to Pull-Based GitOps with ArgoCD

If you need drift detection, multi-cluster management, or a customer requires ArgoCD, here's the migration path. Your application code, Dockerfile, and Helm chart templates don't change.

### Step 1: Install ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  -n argocd --create-namespace \
  --set server.ingress.enabled=false    # access via port-forward initially
```

### Step 2: Create an ArgoCD Application

This tells ArgoCD where your Helm chart is and where to deploy it:

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
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true          # remove resources deleted from Git
      selfHeal: true        # revert manual changes to match Git
    syncOptions:
      - CreateNamespace=true
```

`selfHeal: true` is the key setting. If someone runs `kubectl edit` and manually changes a resource, ArgoCD detects the drift within 3 minutes and reverts it to match Git.

### Step 3: Update CI to Commit Image Tags

CI still builds and pushes images. But instead of deploying directly, it updates the image tag in Git so ArgoCD can detect the change:

```yaml
# In ci.yaml, add after the image push step:
- name: Update image tag in Git
  run: |
    sed -i "s/tag: .*/tag: ${{ github.sha }}/" helm/myapp/values-prod.yaml
    git config user.name "CI Bot"
    git config user.email "ci@example.com"
    git add helm/myapp/values-prod.yaml
    git commit -m "ci: update image tag to ${{ github.sha }}"
    git push
```

### Step 4: Remove cd.yaml

ArgoCD replaces the CD workflow entirely. Delete `.github/workflows/cd.yaml`. CI and CD are now fully decoupled — CI produces artifacts (images + Git commits), ArgoCD deploys them.

### Step 5: Access the ArgoCD UI

```bash
# Port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get the initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Open `https://localhost:8080`. You'll see your application's sync status, resource tree, and deployment history.

### What Changes, What Stays

| Component | Changes? | Details |
|-----------|----------|---------|
| `src/myapp/core.clj` | No | Application code is deployment-agnostic |
| `Dockerfile` | No | Same image, same build |
| `helm/myapp/templates/` | No | Standard K8s — ArgoCD renders them like `helm template` |
| `helm/myapp/values-prod.yaml` | Yes | Image tag is now updated by CI commits, not `--set` flags |
| `.github/workflows/ci.yaml` | Yes | Add step to commit updated image tag |
| `.github/workflows/cd.yaml` | Deleted | ArgoCD replaces it |
| `bb helm-prod` | Still works | Useful for manual deploys or emergencies, bypasses ArgoCD |

---

## How DevOps and GitOps Connect to Other Deep-Dive Docs

| Topic | Relevant doc | How it connects |
|-------|-------------|-----------------|
| Multi-cloud portability | [`docs/multi-cloud.md`](multi-cloud.md) | IaC via Terraform is what makes cloud migration a config change, not a rewrite |
| Customer on-prem deployments | [`docs/on-prem-customer-deployment.md`](on-prem-customer-deployment.md) | ArgoCD is typically the customer's deployment tool — this is where pull-based GitOps becomes required, not optional |
| Secrets management | [`docs/secrets-management.md`](secrets-management.md) | Secrets are the main thing deliberately kept out of Git — Vault fills the gap |
| Business continuity | [`docs/business-continuity.md`](business-continuity.md) | IaC is Level 1 of business continuity — the ability to rebuild from Git alone |
| Observability | Main guide, Step 9 | Monitoring is a core DevOps principle — you can't operate what you can't see |

---

## Summary

| Practice | What it replaces | This project's implementation |
|----------|-----------------|------------------------------|
| Infrastructure as Code | Hand-configured servers, wikis | `terraform/main.tf`, `helm/myapp/` |
| CI/CD | Manual builds and deploys | `ci.yaml` + `cd.yaml` |
| Immutable infrastructure | SSH + patching | Docker images, rolling updates |
| Environment parity | "works on my machine" | Same Helm chart, different values files |
| Monitoring | User complaints, log tailing | LGTM stack, Grafana alerts |
| Automated recovery | Manual restarts, pager duty | K8s probes, cert-manager, rollback |
| GitOps (push) | Deploy scripts, runbooks | GitHub Actions deploys on push to `main` |
| GitOps (pull, future) | Push-based CI/CD | ArgoCD watches Git, self-heals drift |

The project starts with push-based GitOps because it's simpler and sufficient for a solo developer. The evolution to pull-based GitOps is a natural next step when the team grows, compliance requirements increase, or customers require it — and the migration is well-defined because the Helm chart and Dockerfile don't change.
