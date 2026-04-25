# Multi-Cloud Portability and Cloud Deployment Guides

> **Context:** This document is a companion to the main [GUIDE.md](../GUIDE.md). The guide covers deploying to Hetzner as the primary path. This document explains why the project is portable across clouds, exactly what changes per cloud, and provides concrete Terraform configurations and setup steps for AWS, Google Cloud, Azure, and Civo.

---

## Why Portability Matters

This project runs on Hetzner today. Hetzner is cheap, fast, and European. But requirements change:

- A customer's compliance team mandates AWS
- A client's infrastructure is on Azure
- You want multi-cloud resilience
- Hetzner increases prices or discontinues a service
- A new team member only has GCP experience

If your application is tightly coupled to one cloud, moving is a rewrite. If your cloud-specific code is isolated in one directory, moving is a configuration change.

This project was designed for the second scenario.

---

## What's Portable vs What's Cloud-Specific

### Already Portable (No Changes Needed)

| Layer | Why it's portable |
|-------|------------------|
| Application code (`src/myapp/core.clj`) | Pure Clojure, runs on any JVM |
| Dockerfile | Standard OCI image, runs on any container runtime |
| Helm chart templates (`helm/myapp/templates/`) | Standard Kubernetes APIs (`apps/v1`, `networking.k8s.io/v1`, `policy/v1`) |
| CI workflow (`ci.yaml`) | Builds an image, pushes to GHCR — no cloud interaction |
| Monitoring stack (`monitoring/`) | Kubernetes-native Helm charts, uses PVCs (abstracted by K8s) |
| OpenTelemetry agent | OTLP is vendor-neutral — points at any collector endpoint |
| iapetos `/metrics` | Prometheus format — every monitoring system scrapes it |
| Most `bb.edn` tasks | `bb dev`, `bb build`, `bb docker-build`, `bb helm-local`, `bb k8s-*` don't reference any cloud |

This is the majority of the project. The application, the packaging, the deployment manifests, the monitoring, and the local development workflow are all cloud-agnostic.

### Cloud-Specific (Six Areas That Change)

The cloud-specific surface area is deliberately small and isolated. Here are the six areas, in order of impact:

**1. Terraform configuration**

This is the most cloud-specific component. Each cloud has its own Terraform provider, its own way of creating a Kubernetes cluster, and its own networking model.

| Cloud | Terraform provider | K8s service | Module |
|-------|-------------------|-------------|--------|
| Hetzner | `hetznercloud/hcloud` | k3s (self-managed) | `kube-hetzner/kube-hetzner/hcloud` |
| AWS | `hashicorp/aws` | EKS (managed) | `terraform-aws-modules/eks/aws` |
| Azure | `hashicorp/azurerm` | AKS (managed) | `Azure/aks/azurerm` |
| GCP | `hashicorp/google` | GKE (managed) | `terraform-google-modules/kubernetes-engine/google` |
| Civo | `civo/civo` | k3s (managed) | `civo_kubernetes_cluster` resource |

To move clouds, you write a new `main.tf` — you don't modify the existing one. The recommended structure:

```
terraform/
├── hetzner/
│   └── main.tf
├── aws/
│   └── main.tf
├── azure/
│   └── main.tf
├── gcp/
│   └── main.tf
└── civo/
    └── main.tf
```

Each directory has its own state file. The `bb.edn` tasks support this via the `CLOUD` env var: `CLOUD=aws bb tf-apply` runs Terraform in `terraform/aws/`.

**2. Ingress controller and class**

Different K8s distributions ship different ingress controllers (or none at all):

| Distribution | Ingress controller | Ingress class | You install it? |
|-------------|-------------------|---------------|-----------------|
| k3s (Hetzner) | Traefik | `traefik` | No — bundled |
| k3s (Civo) | Traefik | `traefik` | No — bundled |
| EKS (AWS) | None | — | Yes: `bb ingress-install` (nginx) |
| AKS (Azure) | None | — | Yes: `bb ingress-install` (nginx) |
| GKE (GCP) | GCE Ingress (limited) | `gce` | Yes: `bb ingress-install` (nginx, more portable) |

The Helm ingress template reads `{{ .Values.ingress.className }}` and `{{ .Values.ingress.annotations }}` from the values file. Cloud-specific annotations (e.g. AWS ALB settings) go in the values file, never in the template.

The `bb cluster-issuer` task reads the `INGRESS_CLASS` env var (defaults to `traefik`). For clouds using nginx: `INGRESS_CLASS=nginx bb cluster-issuer`.

**3. cert-manager**

kube-hetzner bundles cert-manager automatically. Managed K8s services do not. For AWS, Azure, GCP, and Civo, run `bb cert-manager-install` after cluster creation.

**4. CD workflow authentication**

Each cloud authenticates differently in CI/CD:

| Cloud | Auth method | GitHub Secrets needed |
|-------|------------|----------------------|
| Hetzner | Static kubeconfig | `KUBE_CONFIG` (base64-encoded kubeconfig) |
| Civo | Static kubeconfig | `KUBE_CONFIG` (same as Hetzner) |
| AWS | IAM credentials + `aws eks get-token` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Azure | Service principal + `az aks get-credentials` | `AZURE_CREDENTIALS` |
| GCP | Service account key + `gcloud get-credentials` | `GCP_SA_KEY` |

The Helm commands after authentication are identical across all clouds — only the auth preamble differs.

> **Note on kubeconfig as a GitHub Secret:** Storing a static kubeconfig is a pragmatic shortcut for personal projects. For production systems, prefer workload identity federation (OIDC) where the cloud supports it — this avoids long-lived credentials entirely. AWS, Azure, and GCP all support OIDC-based GitHub Actions authentication.

**5. Storage classes**

Each cloud names its default storage class differently. The monitoring stack's PVCs typically use the cluster's default, which works automatically. If not, set `storageClassName` in the monitoring values files.

| Cloud | Default storage class |
|-------|--------------------- |
| Hetzner | `hcloud-volumes` |
| AWS | `gp2` or `gp3` |
| Azure | `managed-premium` |
| GCP | `standard` |
| Civo | `civo-volume` |

**6. DNS**

DNS records are cloud-independent — you point A records (or CNAMEs) at whatever load balancer IP or hostname your cloud provides. cert-manager and Let's Encrypt work identically on every cloud. The only difference: EKS provides a hostname (CNAME record), while others provide an IP (A record).

---

## Portability Checklist

Six principles that keep the cloud-specific surface area small:

1. **No cloud SDKs in application code.** Your Clojure app should not import AWS, Azure, or Hetzner SDKs. For object storage, use S3-compatible APIs (MinIO in dev, any cloud's S3-compatible endpoint in prod). For queues, use Kubernetes-native solutions (NATS, RabbitMQ) rather than SQS or Azure Service Bus.

2. **Environment variables for all external endpoints.** Database connection strings, API URLs, storage endpoints — all come from Helm values via environment variables. Moving clouds means changing the values file, not the code.

3. **Terraform isolated in its own directory.** Terraform outputs one thing the rest of the system needs: a kubeconfig. Everything else (Helm, CI/CD, monitoring) consumes the kubeconfig and doesn't know which cloud produced it.

4. **Helm templates never hardcode cloud-specific values.** Ingress annotations, storage classes, load balancer types — all in values files. Templates use `{{ .Values.xyz }}`.

5. **Standard Kubernetes APIs only.** Stick to `apps/v1`, `networking.k8s.io/v1`, `policy/v1`. Avoid cloud-specific custom resources (AWS TargetGroupBinding, Azure IngressRoute) unless genuinely necessary.

6. **Cloud-neutral container registry.** GHCR works from any cloud. If you used AWS ECR, images would only be efficiently pullable from AWS. GHCR, Docker Hub, or Harbor are cloud-neutral.

---

## What a Cloud Migration Actually Looks Like

Moving from Hetzner to AWS (the most complex migration) takes 1-2 days:

```
1. Write terraform/aws/main.tf (EKS + VPC + node groups)    ~4 hours
2. terraform apply, get kubeconfig                            ~15 minutes
3. bb ingress-install                                         ~10 minutes
4. bb cert-manager-install                                    ~5 minutes
5. Create values-prod-aws.yaml (className: nginx, annotations) ~30 minutes
6. INGRESS_CLASS=nginx bb cluster-issuer                      ~5 minutes
7. Update GitHub Secrets (AWS credentials)                    ~10 minutes
8. Update cd.yaml with AWS auth step                          ~20 minutes
9. Update DNS records to new load balancer                    ~5 minutes
10. bb monitoring-install                                     ~5 minutes
11. git push (deploys via CI/CD)                              ~5 minutes
12. curl https://myappk8s.net/health                          ~1 minute
```

What doesn't change: Clojure code, Dockerfile, Helm templates, CI workflow, monitoring values. The bulk of the work is writing the Terraform config and adjusting authentication.

---

## Cloud Deployment Guides

Each guide below provides: Terraform configuration, setup steps, cost estimate, and CI/CD workflow changes. In every case, your application code, Dockerfile, and Helm chart templates are unchanged.

---

### AWS (EKS)

**What's different:** EKS is a fully managed K8s service — AWS runs the control plane. More complex to set up than Hetzner because EKS requires a VPC, subnets, IAM roles, and security groups. Does not ship with an ingress controller or cert-manager.

**Prerequisites:**

```bash
brew install awscli
aws configure    # AWS Access Key ID + Secret Access Key
```

**Terraform (`terraform/aws/main.tf`):**

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
  region = "eu-west-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "myapp-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

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
      instance_types = ["t3.medium"]   # 2 vCPU, 4GB
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

**Setup:**

```bash
CLOUD=aws bb tf-apply                           # ~10 minutes
aws eks --region eu-west-1 update-kubeconfig --name myapp
bb ingress-install
bb cert-manager-install
INGRESS_CLASS=nginx bb cluster-issuer
bb docker-push && bb helm-prod
kubectl get svc -n ingress-nginx                 # get ELB hostname
# Create CNAME DNS record → ELB hostname
bb monitoring-install
```

**Cost:** ~$211/mo (EKS control plane $73, 3× t3.medium $90, NAT Gateway $32, LB $16). About 7× Hetzner.

**CD workflow change:**

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: eu-west-1

- name: Update kubeconfig
  run: aws eks update-kubeconfig --name myapp --region eu-west-1
```

---

### Google Cloud (GKE)

**What's different:** Google runs the control plane. One free zonal cluster per billing account (no management fee). Supports Autopilot mode (Google manages nodes) and Standard mode (you manage node pools). Does not ship with nginx-ingress or cert-manager; has its own GCE Ingress, but nginx is more portable.

**Prerequisites:**

```bash
brew install google-cloud-sdk
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud services enable container.googleapis.com
gcloud services enable compute.googleapis.com
```

**Terraform (`terraform/gcp/main.tf`):**

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
      machine_type = "e2-medium"     # 2 vCPU, 4GB
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

**Setup:**

```bash
CLOUD=gcp bb tf-apply                           # ~5 minutes
gcloud container clusters get-credentials myapp --region europe-west1
bb ingress-install
bb cert-manager-install
INGRESS_CLASS=nginx bb cluster-issuer
bb docker-push && bb helm-prod
kubectl get svc -n ingress-nginx                 # get LB IP
# Create A record in DNS
bb monitoring-install
```

**Cost:** ~$90/mo (control plane free, 3× e2-medium $72, LB $18). Cheapest of the big three clouds.

**CD workflow change:**

```yaml
- name: Authenticate to Google Cloud
  uses: google-github-actions/auth@v2
  with:
    credentials_json: ${{ secrets.GCP_SA_KEY }}

- name: Set up Cloud SDK
  uses: google-github-actions/setup-gcloud@v2

- name: Get GKE credentials
  run: gcloud container clusters get-credentials myapp --region europe-west1
```

---

### Azure (AKS)

**What's different:** Azure runs the control plane for free. Tightly integrated with Azure Active Directory for RBAC and Azure Monitor for logging. Does not ship with cert-manager; has its own Application Gateway Ingress Controller, but nginx is more portable.

**Prerequisites:**

```bash
brew install azure-cli
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
az provider register --namespace Microsoft.ContainerService
```

**Terraform (`terraform/azure/main.tf`):**

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
  location = "West Europe"
}

module "aks" {
  source  = "Azure/aks/azurerm"
  version = "~> 11.0"

  resource_group_name = azurerm_resource_group.myapp.name
  prefix              = "myapp"

  agents_size  = "Standard_D2s_v3"   # 2 vCPU, 8GB
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

**Setup:**

```bash
CLOUD=azure bb tf-apply                          # ~5 minutes
az aks get-credentials --resource-group myapp-rg --name myapp-aks
bb ingress-install
bb cert-manager-install
INGRESS_CLASS=nginx bb cluster-issuer
bb docker-push && bb helm-prod
kubectl get svc -n ingress-nginx                 # get LB IP
# Create A record in DNS
bb monitoring-install
```

**Cost:** ~$228/mo (control plane free, 3× Standard_D2s_v3 $210, LB $18). Most expensive of the big three. Azure Enterprise Agreements may lower the effective cost.

**CD workflow change:**

```yaml
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

---

### Civo

**What's different:** Most similar to Hetzner. Developer-focused, simple pricing, 90-second cluster creation. Uses k3s with Traefik pre-installed — the same architecture as the Hetzner setup. The control plane is free.

Civo is the easiest migration because the ingress class (Traefik) and K8s distribution (k3s) are identical. You don't need `bb ingress-install` or any ingress class changes. The only addition: `bb cert-manager-install` (Civo doesn't bundle cert-manager).

**Prerequisites:**

```bash
brew install civo
civo apikey save mykey YOUR_API_KEY
civo region current LON1
```

**Terraform (`terraform/civo/main.tf`):**

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
  region = "LON1"
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
    size       = "g4s.kube.medium"   # 2 vCPU, 4GB
    node_count = 3
  }
}

output "kubeconfig" {
  value     = civo_kubernetes_cluster.myapp.kubeconfig
  sensitive = true
}
```

**Setup:**

```bash
CLOUD=civo bb tf-apply                           # ~90 seconds!
CLOUD=civo bb tf-kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
bb cert-manager-install
bb cluster-issuer                                 # same as Hetzner (traefik)
bb docker-push && bb helm-prod
kubectl get svc -A | grep traefik                 # get LB IP
# Create A record in DNS
bb monitoring-install
```

**Cost:** ~$46/mo (control plane free, 3× g4s.kube.medium $36, LB $10). No egress fees.

**CD workflow change:** None. Civo uses static kubeconfig, same as Hetzner. The existing `cd.yaml` works unchanged.

---

## Cloud Comparison

| Feature | Hetzner | Civo | AWS | Azure | GCP |
|---------|---------|------|-----|-------|-----|
| K8s distribution | k3s | k3s | EKS | AKS | GKE |
| Ingress controller | Traefik (bundled) | Traefik (bundled) | Install yourself | Install yourself | Install yourself |
| cert-manager | Bundled | Install yourself | Install yourself | Install yourself | Install yourself |
| Ingress class | `traefik` | `traefik` | `nginx` | `nginx` | `nginx` |
| CD auth method | Static kubeconfig | Static kubeconfig | AWS IAM | Azure AD | GCP SA |
| ClusterIssuer change | — | — | `INGRESS_CLASS=nginx` | `INGRESS_CLASS=nginx` | `INGRESS_CLASS=nginx` |
| Cluster creation time | ~5 min | ~90 sec | ~10 min | ~5 min | ~5 min |
| Monthly cost (3 nodes) | ~$30 | ~$46 | ~$211 | ~$228 | ~$90 |
| Control plane cost | Included | Free | $73/mo | Free | Free (1 zonal) |

---

## The Cost of Full Abstraction

There's a spectrum:

**Fully cloud-specific** — Lambda, DynamoDB, SQS, CloudFront, S3, IAM. Zero portability. But deep integration, managed services, less ops.

**Fully cloud-agnostic** — standard K8s APIs only, self-hosted databases, S3-compatible storage, no cloud-specific managed services. Full portability. But more infrastructure to manage.

**This project sits in the middle.** The application and deployment pipeline are fully portable. The infrastructure layer is cloud-specific but isolated in one directory. You could later add cloud-managed databases (RDS, Cloud SQL) — connect via environment variables, and document that a migration would need equivalent databases on the target cloud.

The key principle: keep the cloud-specific surface area as small and as isolated as possible. Right now it's one Terraform file and a few Helm values. That's a strong position.

---

## Related Docs

| Topic | Document | Connection |
|-------|----------|-----------|
| On-prem deployment (Harbor, ArgoCD, Rancher) | [`docs/on-prem-customer-deployment.md`](on-prem-customer-deployment.md) | The ultimate portability test — deploying into a customer's own infrastructure |
| DevOps and GitOps | [`docs/devops-and-gitops.md`](devops-and-gitops.md) | IaC via Terraform is what makes migration a config change, not a rewrite |
| Business continuity | [`docs/business-continuity.md`](business-continuity.md) | Multi-cloud or multi-region is one approach to DR |
| Secrets management | [`docs/secrets-management.md`](secrets-management.md) | Vault + CSI Driver is the portable secrets approach across clouds |
| Monitoring backend switching | Main guide, Step 9 | OTel + Prometheus format means monitoring backends are also swappable |
