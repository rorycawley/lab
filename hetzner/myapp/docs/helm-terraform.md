# Infrastructure, Kubernetes, and Application: The Three Layers

> **Context:** This document is a companion to the main [GUIDE.md](../GUIDE.md). It explains how the project's configuration is structured across three distinct layers — physical infrastructure, Kubernetes platform, and application deployment — and how the concept of environments (dev, test, UAT, prod) cuts across all three.

---

## The Mental Model

This project has three layers stacked on top of each other, plus one dimension that cuts across all of them:

```
                        ┌─────────────────────────────────┐
                        │  Layer 3: Application            │
                        │  Your code, deployed as pods     │
                        │  Tool: Helm charts               │
                        ├─────────────────────────────────┤
                        │  Layer 2: Kubernetes Infrastructure │
                        │  The K8s cluster + platform      │
                        │  services (ingress, cert-manager) │
                        │  Tool: Terraform                 │
                        ├─────────────────────────────────┤
                        │  Layer 1: Physical Infrastructure │
                        │  Compute, memory, storage,       │
                        │  networking, security rules       │
                        │  Tool: Terraform                 │
                        └─────────────────────────────────┘

  ◄──────────── Environments (dev, test, UAT, prod) ──────────────►
               Each environment has its own instance of all three layers
```

Layers 1 and 2 are both provisioned by Terraform. They're different concerns — raw compute vs a working Kubernetes platform — but the same tool manages both. In practice, a single `terraform apply` often creates both layers at once: the kube-hetzner module creates VMs (Layer 1) AND installs k3s, Traefik, and cert-manager (Layer 2) in one operation. They're conceptually separate because they change at different rates, can be provided by different parties (a customer might give you Layer 2 while managing Layer 1 themselves), and because understanding the boundary helps you reason about portability.

Layer 3 is where Helm takes over. Helm doesn't provision infrastructure — it deploys your application onto whatever Kubernetes infrastructure Terraform created.

Each layer has its own configuration, its own rate of change, and well-defined contracts connecting it to the layers above and below.

### Why This Separation Matters

You could, in theory, put everything in one tool. Terraform can deploy Helm charts. Helm charts could contain shell scripts that provision infrastructure. Some teams do this. It works until it doesn't.

The separation exists because infrastructure provisioning and application deployment are fundamentally different activities:

**They change at different speeds.** You provision infrastructure once and touch it every few months (resize a VM, add a node, upgrade Kubernetes). You deploy your application multiple times a day. If these are tangled together, every `git push` risks an infrastructure change, and every infrastructure tweak redeploys your application. Separating them means a deploy can't accidentally resize your servers, and a Terraform change can't accidentally roll out untested code.

**They're owned by different people.** In a team, the infrastructure engineer writes Terraform. The application developer writes code and Helm values. In a customer on-prem scenario, the customer owns Layers 1 and 2 entirely — they hand you a kubeconfig and you deploy Layer 3. If everything were in one tool, you'd need access to their infrastructure config just to deploy your app.

**They can be tested independently.** You test Layer 3 locally on Rancher Desktop with `bb helm-local` — no Terraform, no cloud account, no cost. If your Helm chart works locally, it'll work on any cluster that provides the same platform services. You don't need to provision a €30/mo Hetzner cluster just to check whether your deployment template has a YAML error.

**They fail independently.** A bad application deploy (crashed pods, broken health check) doesn't affect your infrastructure. Helm rolls back, the old pods return, the cluster is untouched. A Terraform misconfiguration (wrong firewall rule, deleted network) doesn't redeploy your application — the running pods keep serving until the infrastructure issue is resolved. If provisioning and deployment were coupled, a failure in either could cascade into the other.

**The kubeconfig is the interface between them.** In software design, a clean interface lets two systems evolve independently. The kubeconfig plays that role here. Terraform produces it. Helm consumes it. Neither side knows or cares about the other's implementation. You can completely rewrite your Terraform config (switch clouds, change VM sizes, change K8s distributions) and Helm still works — because the kubeconfig still points to a Kubernetes API. You can completely rewrite your Helm chart (add resources, change templates, restructure values) and Terraform is unaffected — because it never reads your Helm files.

Here's what a kubeconfig actually looks like:

```yaml
apiVersion: v1
kind: Config

clusters:
  - name: myapp-cluster
    cluster:
      server: https://65.21.xxx.xxx:6443          # WHERE: the API server's address
      certificate-authority-data: LS0tLS1CRUd...   # TRUST: CA cert to verify the server

users:
  - name: myapp-admin
    user:
      client-certificate-data: LS0tLS1CRUd...     # WHO: your identity (client cert)
      client-key-data: LS0tLS1CRUd...              # WHO: your private key

contexts:
  - name: myapp
    context:
      cluster: myapp-cluster                       # connect to this cluster...
      user: myapp-admin                            # ...as this user

current-context: myapp                             # use this context by default
```

Three pieces of information: where the API server is (a URL), who you are (credentials — here a client certificate, but it could be a token or cloud-specific auth), and how to trust the server (a CA certificate). It's the Kubernetes equivalent of a database connection string.

When you run `bb tf-kubeconfig`, Terraform extracts this file from the cluster it just created. When you run `bb helm-prod`, Helm reads this file and connects to the API server at that address. Whether that address points to a Hetzner VM, an AWS managed endpoint, or `localhost` on your laptop — Helm doesn't know and doesn't care. It sends Kubernetes resources and they work.

### The Natural Progression: You Start at Layer 3

The layers are presented bottom-up in this document (infrastructure → platform → application) because that's the dependency order. But in practice, you work through them top-down:

```
1. Write your app                    Layer 3 (code + Dockerfile)
   bb dev → REPL → edit → test
   No Kubernetes. No infrastructure. Just your code.

2. Package and deploy locally        Layer 3 (Helm chart)
   bb docker-build → bb helm-local
   Rancher Desktop provides Layers 1+2 for free on your laptop.
   You define templates, values, health probes, resource limits.

3. It works locally. Now you need    Layer 1 + Layer 2 (Terraform)
   real infrastructure.
   bb tf-apply → bb cluster-issuer → bb helm-prod
   Provision a cluster. Deploy the same chart you already tested.

4. You need more environments.       Environments dimension
   Create values-dev.yaml, values-test.yaml, values-uat.yaml.
   Request (or provision) clusters for each.
   Deploy the same chart with different values.
```

This progression matters because it means the application developer doesn't need to think about infrastructure at all until they need it. You can spend days writing code, building Docker images, designing Helm templates, and validating deployments — all on your laptop, with no cloud account, no Terraform, no cost. The Helm chart you build locally is the same chart that will deploy to production.

**What about services that live outside Kubernetes?** In production, your app might depend on a PostgreSQL database, HashiCorp Vault, Redis, or a message queue — services that run outside the K8s cluster (either as managed cloud services or on separate infrastructure). You still need these locally to develop against.

This is where Docker Compose complements Rancher Desktop. Rancher Desktop uses the dockerd backend and bundles Docker Compose, so you can run a `docker-compose.yml` alongside your local K8s cluster:

```yaml
# docker-compose.yml — local dependencies (not deployed to K8s)
services:
  postgres:
    image: postgres:16
    ports:
      - "5432:5432"
    environment:
      POSTGRES_DB: myapp
      POSTGRES_PASSWORD: localdev
  vault:
    image: hashicorp/vault:latest
    ports:
      - "8200:8200"
    environment:
      VAULT_DEV_ROOT_TOKEN_ID: localdev
```

```bash
docker compose up -d         # start Postgres + Vault
bb docker-build              # build your app image
bb helm-local                # deploy your app to local K8s
# Your app connects to postgres://localhost:5432 and http://localhost:8200
```

Your app runs in the local K8s cluster (Layer 3), while its dependencies run in Docker Compose outside K8s. In production, those dependencies would be managed services (RDS, Cloud SQL) or Vault on dedicated infrastructure — but your app doesn't know the difference. It connects to a database URL and a Vault address, wherever those happen to be.

This keeps the progression clean: you develop everything locally before thinking about cloud infrastructure.

When you're ready for real environments, you (or an infrastructure team, or a customer) provision Layers 1+2 and hand over a kubeconfig. You deploy your already-tested Layer 3. If you need dev, test, UAT, and prod, you create values files and request clusters — but the chart and templates don't change.

This is the separation at work: Layer 3 is self-contained and testable in isolation. Infrastructure is something you add underneath it when you need it, not something you build first and hope your app fits into.

---

## Layer 1: Physical Infrastructure

**What it is:** The actual physical (or virtualised) resources that everything runs on. Regardless of whether it's your laptop, a cloud provider, or a rack in a data centre, Layer 1 always consists of the same five fundamental resources:

| Resource | What it is | Example in this project |
|----------|-----------|------------------------|
| **Compute** | CPUs that execute your code | Hetzner CX33: 4 vCPUs per worker node |
| **Memory** | RAM for running processes | Hetzner CX33: 8GB per worker node |
| **Storage** | Disks for persistent data | Hetzner Cloud Volumes for monitoring data (Mimir, Loki, Grafana) |
| **Networking** | Connections between machines and to the internet | Private network between nodes, load balancer for external traffic |
| **Security rules** | Firewalls and access controls governing who can reach what | Allow HTTPS (443) and the K8s API (6443) from the internet, block everything else |

Every cloud vendor provides these five things. They call them different names (EC2 vs Azure VM vs Hetzner Server, EBS vs Azure Disk vs Hetzner Volume, Security Group vs NSG vs Hetzner Firewall), but they're the same fundamental resources. Your application needs compute to run, memory to hold state, storage to persist data, networking to communicate, and security rules to control access.

**Where these resources come from depends on the scenario:**

| Scenario | What provides Layer 1 |
|----------|------------------------|
| Your laptop | Your Mac's CPU, RAM, and SSD — Rancher Desktop runs K8s using your machine's resources |
| Hetzner | CX23/CX33 VMs in Nuremberg, connected by a private network, behind a load balancer, protected by Hetzner Firewall rules |
| AWS | EC2 instances in eu-west-1, inside a VPC with subnets, behind an NLB, protected by Security Groups |
| Azure | Standard_D2s_v3 VMs in West Europe, in a resource group, with NSG rules |
| Customer on-prem | Bare-metal servers or VMware VMs in their data centre, with their own network and firewall appliances |

**What you configure at this layer:**

- **Compute and memory:** how many servers, what size (vCPUs, RAM), which location/region
- **Storage:** what type of disks, how large, which storage tier (SSD vs HDD)
- **Networking:** VPCs, subnets, load balancers, DNS entries for the load balancer
- **Security rules:** which ports are open, which IP ranges can access the K8s API, whether nodes have public IPs
- **Access credentials:** SSH keys, API tokens for the cloud provider, the OS on each server

**Tool:** Terraform (except for your laptop, where Rancher Desktop provides this layer).

**Rate of change:** Very slow. You set this up once and rarely touch it. You might resize VMs or add a node every few months.

**What this layer knows about your application:** Nothing. Terraform creates servers and networks. It has no idea what you'll run on them.

### Terraform's Role at Layer 1 (and Layer 2)

Terraform talks to the cloud provider's API (Hetzner API, AWS API, Azure API) and provisions resources for both layers. Each cloud has completely different resources — Hetzner has `hcloud_server`, AWS has `aws_instance`, Azure has `azurerm_virtual_machine`. They share no syntax, no naming, no module structure.

A single `main.tf` typically creates both layers at once:

```
terraform apply
  │
  ├── Layer 1: Creates VMs, network, firewall, load balancer
  │
  └── Layer 2: Installs K8s distribution + platform services on those VMs
       │
       └── Output: a kubeconfig (the contract with Layer 3)
```

The output is always the same: **a Kubernetes cluster with a kubeconfig.** That's the contract Terraform provides to Helm. Helm never knows or cares what cloud, what VMs, or what K8s distribution produced that kubeconfig.

---

## Layer 2: Kubernetes Infrastructure

**What it is:** The Kubernetes cluster running on top of Layer 1, plus all the cluster-wide platform services installed into it. This is the "platform" that your application deploys onto.

**Tool:** Terraform — the same tool as Layer 1. In practice, a single `main.tf` often provisions both layers. The kube-hetzner module creates the VMs (Layer 1) and then installs k3s, Traefik, and cert-manager (Layer 2) on those VMs. The AWS EKS module creates a VPC (Layer 1) and then creates the managed Kubernetes control plane and node groups (Layer 2). You run `terraform apply` once and get both layers.

**Rate of change:** Slow, but faster than Layer 1. You might upgrade the Kubernetes version every few months, or install a new platform service. You rarely change the underlying servers.

**Why it's a separate layer from Layer 1:** The Kubernetes cluster is built on top of the physical infrastructure, but it's a different concern. You can change the K8s version without changing the VMs. You can add an ingress controller without adding servers. In some scenarios (customer on-prem, Rancher-managed), someone else provides Layer 1 entirely and you only interact with Layer 2. The separation matters because it tells you what you control, what you configure, and who to talk to when something breaks.

Layer 2 has two sub-parts:

### 2a: The Kubernetes Distribution

The K8s distribution is the cluster itself — the API server, etcd, scheduler, kubelet on each node. This is what turns a set of servers (Layer 1) into a Kubernetes cluster.

| Scenario | K8s distribution | Who installs it |
|----------|-----------------|-----------------|
| Your laptop | k3s (inside Rancher Desktop) | You install Rancher Desktop |
| Hetzner | k3s (via kube-hetzner) | Terraform's kube-hetzner module |
| AWS | EKS (managed by AWS) | Terraform's EKS module |
| Azure | AKS (managed by Azure) | Terraform's AKS module |
| GCP | GKE (managed by Google) | Terraform's GKE module |
| Customer on-prem | RKE2 or k3s (managed by Rancher) | Customer's platform team |

The distribution is what provides the standard Kubernetes API. Regardless of whether it's k3s, EKS, or GKE, the API is the same — `kind: Deployment` works identically on all of them. This is the contract Layer 2 provides to Layer 3: a standard Kubernetes API accessible via a kubeconfig.

### 2b: Platform Services

On top of the bare Kubernetes cluster, certain services must be installed before your application can work. These are cluster-wide services that your app depends on but doesn't manage:

| Service | What it does | Who needs it |
|---------|-------------|-------------|
| **Ingress controller** (Traefik or nginx) | Routes external HTTP/HTTPS traffic to the right Service | Any app exposed to the internet |
| **cert-manager** | Automates TLS certificate issuance and renewal | Any app using HTTPS |
| **CSI driver** | Provisions persistent storage (cloud volumes) | Monitoring stack (Mimir, Loki, Grafana) |
| **ClusterIssuer** | Tells cert-manager how to talk to Let's Encrypt | Any app using cert-manager |

Here's the critical point: **different clusters come with different platform services pre-installed.** Some providers (like kube-hetzner) install everything. Others (like EKS, or Rancher provisioning a cluster on-prem on VMs) give you a bare cluster and you install the rest.

| Cluster provider | Ingress controller | cert-manager | CSI driver | Storage available | Monitoring / Observability |
|---------------|-------------------|--------------|------------|-------------------|---------------------------|
| Rancher Desktop | Traefik ✓ | ✗ not included | local-path ✓ | Local disk only (no persistent volumes across restarts) | ✗ not included |
| Hetzner (kube-hetzner) | Traefik ✓ | ✓ included | Hetzner CSI ✓ | Block storage (Hetzner Volumes, SSD, 10GB-10TB) | ✗ not included (we install LGTM stack via `bb monitoring-install`) |
| Civo | Traefik ✓ | ✗ not included | Civo CSI ✓ | Block storage (Civo Volumes, SSD) | ✗ not included |
| AWS (EKS) | ✗ not included | ✗ not included | EBS CSI ✓ | Block storage (EBS gp3/io2), file storage (EFS via separate CSI) | CloudWatch Container Insights (opt-in), X-Ray for traces |
| Azure (AKS) | ✗ not included | ✗ not included | Azure Disk CSI ✓ | Block storage (Managed Disks), file storage (Azure Files via separate CSI) | Azure Monitor Container Insights (opt-in) |
| GCP (GKE) | ✗ not included | ✗ not included | PD CSI ✓ | Block storage (Persistent Disks SSD/HDD), file storage (Filestore via separate CSI) | Cloud Monitoring + Cloud Logging (auto-enabled), Cloud Trace |
| On-prem (Rancher) | ✗ not included | ✗ not included | Varies | Customer's choice (Ceph, NFS, local-path, NetApp, etc.) | Rancher Monitoring (optional, Prometheus + Grafana based) or customer's existing stack |

When a service isn't bundled, you install it yourself:

```bash
bb ingress-install          # installs nginx-ingress (for clouds without Traefik)
bb cert-manager-install     # installs cert-manager (for clouds without it)
bb cluster-issuer           # creates ClusterIssuer (after cert-manager exists)
```

**This is why Layer 2 matters as a distinct concept from Layer 1.** Two clusters on the same cloud can have different platform services (one has Traefik, another has nginx). Two clusters on different clouds might have the same ones. The physical infrastructure (Layer 1) doesn't determine the platform services (Layer 2) — you configure Layer 2 based on what your application needs, not what the cloud vendor defaults to.

### What Layer 2 Provides to Layer 3

Layer 2's contract to the application is:

1. **A Kubernetes API** (via kubeconfig) — your app can create Deployments, Services, Ingresses
2. **An ingress class** (e.g. `traefik` or `nginx`) — your app needs to know which class to reference
3. **cert-manager + ClusterIssuer** — your Ingress can request TLS certificates
4. **A storage class** (e.g. `hcloud-volumes`, `gp3`) — your monitoring stack can request persistent volumes

These four things are what Layer 3 (Helm values) must reference correctly. If Layer 2 has Traefik, your values say `className: traefik`. If Layer 2 has nginx, your values say `className: nginx`. The Helm templates don't care — they use `{{ .Values.ingress.className }}`.

---

## Layer 3: Application Deployment

**What it is:** Your application code, packaged as a Docker image, deployed onto the Kubernetes platform via Helm.

**Tool:** Helm.

**Rate of change:** Fast. Every `git push` to `main` produces a new Docker image and triggers a Helm deployment.

**What this layer knows about your infrastructure:** Almost nothing. The application code doesn't know it's running on Kubernetes, let alone which cloud. The Dockerfile doesn't reference Hetzner or AWS. The Helm templates don't mention a specific cloud or distribution. The only place infrastructure details appear is in the values file — and even there, it's just a few keys like `ingress.className` and `ingress.annotations`. Everything else (replicas, resources, domain, probes) is about the application, not the platform.

### What's in Layer 3

| Component | Files | What it defines |
|-----------|-------|-----------------|
| Application code | `src/myapp/core.clj`, `deps.edn` | What the app does |
| Container image | `Dockerfile` | How the app is packaged |
| Kubernetes resources | `helm/myapp/templates/` | What K8s objects to create (Deployment, Service, Ingress, PDB) |
| Configuration | `helm/myapp/values-*.yaml` | How to configure each deployment (replicas, domain, resources, image) |

### Templates vs Values: The Key Split

The templates define the **structure** of the Kubernetes resources. They're the same everywhere:

```yaml
# deployment.yaml template — identical on every cloud, every environment
spec:
  replicas: {{ .Values.replicaCount }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    spec:
      containers:
        - image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
```

The values provide the **specifics** for a particular deployment. Compare these two files — same template, completely different result:

**Local development** (`values-local.yaml`):
```yaml
replicaCount: 1
image:
  repository: myapp
  tag: dev
  pullPolicy: Never           # use the image you just built locally
ingress:
  className: traefik
  host: myapp.localhost
  tls: false
```

**Hetzner production** (`values-prod.yaml`):
```yaml
replicaCount: 2
image:
  repository: # set via --set flag (ghcr.io/rorycawley/myapp)
  tag: # set via --set flag (commit SHA)
  pullPolicy: Always          # always pull from the registry
ingress:
  className: traefik
  host: # set via --set flag (myappk8s.net)
  tls: true
```

The template doesn't know which file it's reading. It just fills in the placeholders.

Templates are cloud-agnostic and environment-agnostic. Values encode two things: **which environment** (replicas, log level, domain) and **which platform** (ingress class, annotations). This is where Layer 2's details surface into Layer 3 — but only into values files, never into templates.

### How Helm Talks to the Cluster

Helm connects to the Kubernetes API via the kubeconfig that Terraform produced. As described above, the API is standardised and the kubeconfig is just an address and credentials — Helm doesn't know or care which cloud is behind it.

**But some values must match the platform.** The API accepts an Ingress resource identically on every cluster. But an Ingress by itself is a declaration — for traffic to actually route, an ingress controller must be installed and watching for Ingress resources. Which controller is installed is a Layer 2 decision. If your values say `className: traefik` but nginx is installed, the Ingress gets created (the API accepts it) but no controller picks it up — your app is unreachable.

| Layer 2 provides | Layer 3 values must say | What breaks if they don't match |
|-----------------|------------------------|--------------------------------|
| Traefik ingress controller | `ingress.className: traefik` | Ingress created but no traffic routed |
| nginx ingress controller | `ingress.className: nginx` | Same — wrong controller, no routing |
| cert-manager + ClusterIssuer | `ingress.clusterIssuer: letsencrypt` | No TLS certificate issued |
| `hcloud-volumes` storage class | *(monitoring charts use default)* | PVCs stuck in Pending if wrong class |
| CX33 nodes (4 vCPU, 8GB) | `resources.requests.memory: 512Mi` | Pods Pending if requests exceed capacity |

The templates handle this with placeholders: `{{ .Values.ingress.className }}`. The template doesn't mention Traefik or nginx. The cloud-specific knowledge lives entirely in the values file. **Templates are portable. Values encode the platform.**

---

## The Environment Dimension

Environments cut across all three layers. Each environment (dev, test, UAT, prod) can have its own instance of each layer — or share some layers with other environments.

### How Environments Map to Each Layer

| | Layer 1 (Infrastructure) | Layer 2 (K8s Platform) | Layer 3 (Application) |
|---|---|---|---|
| **Local** | Your laptop (Rancher Desktop) | k3s + Traefik (bundled) | `values-local.yaml`, namespace: `default` |
| **Dev** | Shared cluster *or* dedicated small cluster | Same ingress + cert-manager | `values-dev.yaml`, namespace: `dev` |
| **Test** | Same as Dev (shared) | Same | `values-test.yaml`, namespace: `test` |
| **UAT** | Dedicated medium cluster | Same ingress + cert-manager | `values-uat.yaml`, namespace: `uat` |
| **Prod** | Dedicated full-spec cluster | Same ingress + cert-manager | `values-prod.yaml`, namespace: `prod` |

### The Isolation Decision: Shared vs Separate Infrastructure

The first question for multiple environments is: **do they share Layers 1 and 2, or does each get its own?**

**Option A: Shared infrastructure, separated by namespace**

One cluster (one Layer 1, one Layer 2). Environments are separated at Layer 3 — different Helm deployments in different namespaces:

```
terraform/main.tf → one cluster (Layer 1 + Layer 2)
  │
  Helm deploys to:
  ├── namespace: dev   → values-dev.yaml   (Layer 3)
  ├── namespace: test  → values-test.yaml  (Layer 3)
  ├── namespace: uat   → values-uat.yaml   (Layer 3)
  └── namespace: prod  → values-prod.yaml  (Layer 3)
```

Cost: ~€30/mo total. The Terraform config doesn't change at all — environment separation is entirely a Helm concern. The risk: environments share CPU, memory, and network. A runaway process in dev can starve prod. They also share Layer 2 — you can't test a Traefik upgrade without affecting all environments.

**Option B: Separate infrastructure per environment**

Each environment gets its own cluster (its own Layer 1 + Layer 2), with its own Terraform directory:

```
terraform/
├── modules/
│   └── k3s-cluster/
│       ├── main.tf           ← shared cluster definition
│       └── variables.tf      ← parameterised: workers, VM size, location
├── dev/
│   └── main.tf               ← workers = 1, size = "cx23" (Layer 1 + 2)
├── test/
│   └── main.tf               ← workers = 1, size = "cx23" (Layer 1 + 2)
├── uat/
│   └── main.tf               ← workers = 2, size = "cx33" (Layer 1 + 2)
└── prod/
    └── main.tf               ← workers = 3, size = "cx33" (Layer 1 + 2)
```

Each has its own state file — destroying dev doesn't affect prod. Each has its own Layer 2 — you can upgrade Traefik in dev first, verify it works, then upgrade prod. This is the same principle as testing application changes in dev before prod — but applied to the platform itself.

Cost: ~€15-30/mo per environment. Full isolation.

**Option C: Hybrid** — dev+test share a cluster (namespaces), UAT and prod each get their own. Balances cost with isolation where it matters most.

| Team size | Recommended |
|-----------|-------------|
| Solo developer | Option A — one cluster, namespaces (cheapest) |
| Small team (2-5) | Option A with resource quotas, or Option C |
| Team of 5+ | Option B — separate clusters |
| Regulated industry | Option B — audit trail per environment |

### Layer 3 Per Environment

Regardless of which isolation approach you choose, Layer 3 always varies per environment. Each gets its own values file:

```
helm/myapp/
├── values.yaml             ← defaults
├── values-local.yaml       ← local development
├── values-dev.yaml         ← shared dev
├── values-test.yaml        ← QA testing
├── values-uat.yaml         ← stakeholder acceptance
└── values-prod.yaml        ← production
```

| Setting | Local | Dev | Test | UAT | Prod |
|---------|-------|-----|------|-----|------|
| Replicas | 1 | 1 | 1 | 2 | 2+ |
| Ingress host | `myapp.localhost` | `dev.myappk8s.net` | `test.myappk8s.net` | `uat.myappk8s.net` | `myappk8s.net` |
| TLS | No | Yes | Yes | Yes | Yes |
| Image source | Local (`Never`) | GHCR (`Always`) | GHCR | GHCR | GHCR |
| Log level | DEBUG | DEBUG | INFO | INFO | WARN |
| OTel tracing | Off | On | On | On | On |
| Resource limits | Minimal | Low | Low | Medium | High |
| Who deploys | You (`bb helm-local`) | CI/CD auto | CI/CD auto | Manual approval | Manual approval |

Adding an environment is: create a values file, pick a namespace (or provision a cluster), deploy. No template changes. No Dockerfile changes. No code changes.

---

## Changing Cloud Vendor

Moving from one cloud to another is a Layer 1 + Layer 2 change. Layer 3 templates don't change. Layer 3 values may need a small update (ingress class).

### What Changes at Each Layer

| Layer | What changes | What stays |
|-------|-------------|------------|
| **Layer 1** | Entirely new `main.tf` — different provider, resources, and modules | Nothing — the two clouds share no Terraform config |
| **Layer 2** | May need to install ingress + cert-manager (if not bundled) | The K8s API itself is the same |
| **Layer 3 templates** | Nothing | Standard K8s resources work everywhere |
| **Layer 3 values** | Ingress class, possibly annotations | Everything else (replicas, resources, domain, OTel, etc.) |

### The Transition Step by Step

```
1. Write new Terraform config        terraform/aws/main.tf
2. Provision the new cluster          CLOUD=aws bb tf-apply
3. Get kubeconfig                     aws eks update-kubeconfig --name myapp
4. Install missing platform services  bb ingress-install && bb cert-manager-install
5. Create ClusterIssuer               INGRESS_CLASS=nginx bb cluster-issuer
6. Create/update values file          values-prod-aws.yaml (className: nginx)
7. Deploy                             helm upgrade --install myapp ./helm/myapp -f values-prod-aws.yaml ...
8. Update DNS                         Point A records to new load balancer
9. Verify                             curl https://myappk8s.net/health
10. Destroy old cluster               bb tf-destroy
```

Steps 1-5 are Layer 1 + Layer 2. Step 6 is Layer 3 values. Steps 7-9 are Layer 3 deployment. Your application code, Dockerfile, Helm templates, and CI pipeline don't change.

### Running Two Clouds in Parallel

During a transition, both clusters run the same app:

```
Old: terraform/main.tf     → Hetzner cluster → serving production traffic
New: terraform/aws/main.tf → AWS cluster     → testing

Both run the same Docker image, same Helm chart, same application.
DNS determines which one users reach.
```

Switch DNS when confident. Monitor. Destroy the old cluster. The app doesn't know the switch happened.

---

## Worked Example: All Three Layers for Two Deployments

The layer model is abstract until you see it applied. Here are the actual files and commands for two real deployments — Hetzner production and AWS production — showing what changes at each layer and what stays the same.

**Hetzner production:**

| Layer | What | File / Command |
|-------|------|----------------|
| 1 | 4 VMs (CX23 + 3×CX33), private network, LB11, Hetzner Firewall | `terraform/main.tf` → `bb tf-apply` |
| 2a | k3s (installed by kube-hetzner) | Bundled in `bb tf-apply` |
| 2b | Traefik ✓, cert-manager ✓, Hetzner CSI ✓ | Bundled in `bb tf-apply` |
| 2b | ClusterIssuer (class: traefik) | `bb cluster-issuer` |
| 3 | 2 replicas, `myappk8s.net`, TLS, GHCR image | `values-prod.yaml` → `bb helm-prod` |

**AWS production (same app, different infrastructure):**

| Layer | What | File / Command |
|-------|------|----------------|
| 1 | VPC, 2 subnets, 3×t3.medium EC2, NLB, Security Groups | `terraform/aws/main.tf` → `CLOUD=aws bb tf-apply` |
| 2a | EKS (managed by AWS) | Created by `CLOUD=aws bb tf-apply` |
| 2b | nginx (you install), cert-manager (you install), EBS CSI ✓ | `bb ingress-install` + `bb cert-manager-install` |
| 2b | ClusterIssuer (class: nginx) | `INGRESS_CLASS=nginx bb cluster-issuer` |
| 3 | 2 replicas, `myappk8s.net`, TLS, GHCR image | `values-prod-aws.yaml` → `bb helm-prod` |

**What's identical in both:**

- `src/myapp/core.clj` — same application code
- `Dockerfile` — same container image
- `helm/myapp/templates/` — same Deployment, Service, Ingress, PDB templates
- `.github/workflows/ci.yaml` — same CI pipeline building the same Docker image

**What differs:**

- `terraform/main.tf` vs `terraform/aws/main.tf` — completely different (Layer 1 + 2a)
- Whether you run `bb ingress-install` and `bb cert-manager-install` (Layer 2b)
- `values-prod.yaml` vs `values-prod-aws.yaml` — one line different: `className: traefik` vs `className: nginx` (Layer 3)

That's the three-layer model in practice. The application and its templates are portable. The infrastructure and platform are cloud-specific. The values file is the thin bridge between them.

---

## Helm Releases and Rollback

Every `helm upgrade --install` creates a numbered release — a Layer 3 snapshot:

```bash
helm history myapp
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         deployed    Upgrade complete
```

Roll back: `helm rollback myapp 2`. Helm re-renders templates with revision 2's values and applies them.

This works at Layer 3 only. Helm can roll back your application. It can't roll back Terraform (Layer 1) or platform service changes (Layer 2). Layer 1 rollback is `terraform apply` with the previous config. Layer 2 rollback is re-installing the previous version of the ingress controller or cert-manager.

---

## Why Not Kustomize?

Kustomize is the main alternative to Helm for Layer 3:

| | Helm | Kustomize |
|---|------|-----------|
| How it works | Templates + values → rendered YAML | Base YAML + patches → merged YAML |
| Environment separation | Values files | Overlay directories |
| Release history + rollback | Yes | No (re-apply from Git) |
| Third-party charts | Huge ecosystem | Write raw YAML yourself |

Helm is the right choice here because the monitoring stack uses 6 Helm charts, release history makes rollback trivial, and the values-file pattern maps cleanly to the three-layer + environment model.

---

## Summary: What Lives Where

| Concern | Layer | Tool | Files | Rate of change |
|---------|-------|------|-------|----------------|
| Servers, network, load balancer | 1: Infrastructure | Terraform | `terraform/main.tf` | Rarely |
| K8s distribution | 2a: Cluster | Terraform | `terraform/main.tf` | Rarely |
| Ingress, cert-manager, CSI | 2b: Platform services | Terraform or `bb` tasks | `bb ingress-install` etc. | Rarely |
| ClusterIssuer | 2b: Platform services | `bb cluster-issuer` | Generated at runtime | Once per cluster |
| Pod spec, Service, Ingress, PDB | 3: App structure | Helm templates | `helm/myapp/templates/` | When resource structure changes |
| Replicas, domain, resources, image | 3: App config | Helm values | `helm/myapp/values-*.yaml` | Per environment / per cloud |
| Application logic | 3: App code | Code + Docker | `src/`, `Dockerfile` | Every feature / fix |
| Environment choice | Cross-cutting | Values file + namespace | `values-{env}.yaml` + `-n {env}` | When adding environments |
| Cloud choice | Layers 1 + 2 | Terraform + values | `terraform/{cloud}/` + `values-*-{cloud}.yaml` | When changing vendors |

---

## Related Docs

| Topic | Document |
|-------|----------|
| Hetzner production deployment (all layers together) | [docs/hetzner-deployment.md](hetzner-deployment.md) |
| Multi-cloud deployment guides | [docs/multi-cloud.md](multi-cloud.md) |
| Customer on-prem deployment | [docs/on-prem-customer-deployment.md](on-prem-customer-deployment.md) |
| DevOps and GitOps principles | [docs/devops-and-gitops.md](devops-and-gitops.md) |
| Secrets in values files | [docs/secrets-management.md](secrets-management.md) |
| Observability stack (Layer 2b + Layer 3) | [docs/observability.md](observability.md) |
