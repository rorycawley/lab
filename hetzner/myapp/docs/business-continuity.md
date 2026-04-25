# Business Continuity

> **Context:** This document is a companion to the main [GUIDE.md](../GUIDE.md). The guide covers how to build and deploy the project. This document covers how to keep it running when things go wrong — from a crashed pod to a data centre fire — and how to get it back when they do.

---

## RTO and RPO: The Two Numbers That Drive Everything

Business continuity planning starts with two questions that only the business can answer:

**RTO (Recovery Time Objective):** How long can the service be down before it matters?

**RPO (Recovery Point Objective):** How much data can you lose before it matters?

| Scenario | Typical RTO | Typical RPO |
|----------|-------------|-------------|
| Internal team tool | Hours | Hours |
| Company website / blog | 1 hour | 1 day |
| SaaS product | 15 minutes | 1 hour |
| E-commerce / payments | 5 minutes | Zero |
| Financial trading / healthcare | Seconds | Zero |

These are business decisions, not technical ones. Every step down the table costs significantly more — shorter RTO requires standby infrastructure, shorter RPO requires real-time replication. You match the investment to the business risk.

This project is currently a stateless web service. There's no database, no user uploads, no transactions. That makes the BC picture simple: the application RPO is effectively zero (nothing to lose — code is in Git, images in GHCR), and the RTO is about 15 minutes (time to rebuild the cluster from Terraform).

The picture changes the moment you add a database. At that point, your RPO and RTO depend on your database backup and replication strategy, not your Kubernetes setup.

---

## What Needs Protecting

| Component | What it contains | If lost | How to recover |
|-----------|-----------------|---------|----------------|
| Application code | Source, Dockerfile, Helm charts, CI/CD | Nothing — it's all in Git | `git clone` + `bb helm-prod` |
| Docker images | Built container images | Rebuild from code | CI rebuilds automatically from Git |
| Terraform state | Mapping between config and real cloud resources | Terraform can't manage the cluster | Remote state backend prevents this (see below) |
| Cluster state | Deployments, Services, Ingress, ConfigMaps, Secrets | Service is down | `bb tf-apply` + `bb helm-prod` (~15 min), or Velero restore (~5 min) |
| TLS certificates | HTTPS encryption | Browser warnings until re-issued | cert-manager re-issues automatically on redeploy |
| Monitoring data | Metrics history, logs, traces | Lose historical visibility | Accept the loss, or back up MinIO/Mimir/Loki volumes |
| Database (if added) | User data, transactions, business state | **Data loss — the critical concern** | Database-specific backup + replication |

The first column worth protecting beyond Git is the Terraform state file. Everything else can be rebuilt from Git alone — slowly but completely.

---

## Five Levels of Business Continuity

| Level | Protects against | RTO | RPO | Cost | This project |
|-------|-----------------|-----|-----|------|--------------|
| **1. Reproducible infrastructure** | Cluster failure, accidental deletion | ~15 min | Zero (stateless) | Free | ✓ Today |
| **2. Automated backups** | Data corruption, accidental K8s resource deletion | Minutes | Hours (backup interval) | Low | Not yet |
| **3. Multi-zone HA** | Single node/zone failure | Seconds | Zero | Moderate | Partial |
| **4. Multi-region standby** | Region/data centre outage | Minutes–hours | Hours (backup interval) | High | No |
| **5. Active-active multi-region** | Any single-region failure | Near-zero | Near-zero | Very high | No |

Most projects should start at Level 1 and add levels only when the business requires them. Building Level 5 for a project that needs Level 2 is wasted money and wasted complexity.

---

## Level 1: Reproducible Infrastructure

**You already have this.** Everything is Infrastructure as Code.

### The Rebuild Test

If the cluster disappears entirely — hardware failure, accidental `terraform destroy`, cloud provider outage — you can rebuild from scratch:

```bash
bb tf-apply                    # recreate cluster              ~5 min
bb tf-kubeconfig               # get new kubeconfig
export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
bb cluster-issuer              # recreate ClusterIssuer
bb monitoring-install          # reinstall LGTM stack          ~3 min
bb helm-prod                   # deploy app                    ~2 min
# TLS certificate auto-issues                                  ~1 min
# Total                                                       ~15 min
```

**RTO:** ~15 minutes.
**RPO:** Zero for the application (no data to lose). You lose monitoring history (Grafana dashboards revert to defaults, metric and log history gone).

### The Weak Point: Terraform State

The one thing that breaks Level 1 is losing `terraform.tfstate`. This file maps your Terraform config to real cloud resources. Without it, Terraform doesn't know what exists — it tries to create duplicates and fails.

Today, the state file lives on your laptop. If your laptop dies or the file is accidentally deleted, you have to manually clean up cloud resources and start fresh.

**Fix: remote state backend.** Store the state in S3-compatible object storage instead of on your laptop:

```hcl
# Add to terraform/main.tf
terraform {
  backend "s3" {
    bucket         = "myapp-terraform-state"
    key            = "hetzner/terraform.tfstate"
    region         = "eu-central-1"
    # For Hetzner, use MinIO or Backblaze B2 with S3-compatible endpoint
    # For AWS, use a real S3 bucket
    # For any cloud, the state is backed up by the storage provider
  }
}
```

With remote state, multiple team members can access the state, it's backed up by the storage provider, and losing your laptop doesn't lose your infrastructure mapping.

---

## Level 2: Automated Backups with Velero

Level 1 can rebuild from scratch, but it's slow (~15 min) and you lose everything that isn't in Git (monitoring data, Kubernetes Secrets created manually, custom ConfigMaps). Level 2 takes periodic snapshots of the cluster state and persistent volume data, so you can restore to a known-good point in minutes.

### What Velero Is

Velero is the standard open-source backup tool for Kubernetes. It captures two things:

1. **Cluster resources** (via the Kubernetes API) — Deployments, Services, Ingress, ConfigMaps, Secrets, Custom Resources
2. **Persistent volume data** (via volume snapshots or file-level copy) — MinIO data, Grafana settings, database volumes

Velero stores backups in object storage (S3, Azure Blob, GCS, or any S3-compatible storage like MinIO). Backups can be restored to the same cluster or a different one — making Velero useful for both disaster recovery and cluster migration.

### Installing Velero

```bash
# Install the CLI
brew install velero
```

The cluster-side installation depends on your storage backend:

**Hetzner (using the existing MinIO or an external S3-compatible store):**

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backups \
  --secret-file ./credentials-minio \
  --use-volume-snapshots=false \
  --backup-location-config \
    region=minio,s3ForcePathStyle="true",s3Url=http://minio.monitoring.svc:9000
```

**AWS (using S3 + EBS snapshots):**

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket myapp-velero-backups \
  --backup-location-config region=eu-west-1 \
  --snapshot-location-config region=eu-west-1 \
  --secret-file ./credentials-velero
```

**Azure (using Azure Blob Storage):**

```bash
velero install \
  --provider azure \
  --plugins velero/velero-plugin-for-microsoft-azure:v1.9.0 \
  --bucket myapp-velero-backups \
  --secret-file ./credentials-velero \
  --backup-location-config resourceGroup=myapp-rg,storageAccount=myappvelero
```

**GCP (using Cloud Storage):**

```bash
velero install \
  --provider gcp \
  --plugins velero/velero-plugin-for-gcp:v1.9.0 \
  --bucket myapp-velero-backups \
  --secret-file ./credentials-velero
```

The commands differ only in the provider and storage config. Velero's CLI and backup/restore commands are identical across all backends.

### Scheduling Backups

```bash
# Daily full backup at 2am UTC, retained for 30 days
velero schedule create daily-full \
  --schedule="0 2 * * *" \
  --ttl=720h

# Hourly backup of the app namespace, retained for 7 days
velero schedule create hourly-app \
  --schedule="0 * * * *" \
  --include-namespaces=default \
  --ttl=168h
```

### Restoring After a Disaster

```bash
# List available backups
velero backup get

# Restore everything from the latest daily backup
velero restore create --from-backup daily-full-20260405020000

# Restore just the app namespace from the latest hourly backup
velero restore create --from-backup hourly-app-20260405100000 \
  --include-namespaces default

# Monitor the restore
velero restore describe <restore-name>
kubectl get pods -w
```

**RTO with Velero:** Minutes (restore from backup instead of rebuilding from scratch).
**RPO with Velero:** The time since the last backup — 1 hour with hourly schedules, 24 hours with daily-only.

### Important: Off-Site Backups

If your backups are stored on the same cluster that fails, they fail too. Always store backups externally:

- **Hetzner:** Use Backblaze B2, Wasabi, or a MinIO instance in a different Hetzner location
- **AWS:** Use S3 with cross-region replication enabled
- **Azure:** Use geo-redundant storage (GRS) for the Azure Blob container
- **GCP:** Use multi-region Cloud Storage buckets
- **On-prem:** Replicate to a cloud bucket, or to S3-compatible storage in a second data centre

---

## Level 3: High Availability Within a Region

Levels 1 and 2 are about recovery — getting back after something fails. Level 3 is about surviving failures without going down at all.

### What This Project Already Has

| Feature | How it helps | Where it's configured |
|---------|-------------|----------------------|
| 3 worker nodes | Pods reschedule if a node dies | `terraform/main.tf` |
| 2 app replicas | One pod serves traffic while the other is down | `values-prod.yaml` |
| PodDisruptionBudget | K8s won't drain both pods at once during node upgrades | `helm/myapp/templates/pdb.yaml` |
| Rolling updates (`maxUnavailable: 0`) | New pod must be healthy before old pod is terminated | `helm/myapp/templates/deployment.yaml` |
| `preStop` hook (sleep 5s) | Gives Traefik time to stop routing to a terminating pod | `helm/myapp/templates/deployment.yaml` |
| Readiness probes | Unhealthy pods are removed from the load balancer | `helm/myapp/templates/deployment.yaml` |

### What to Add: Pod Anti-Affinity

If both replicas land on the same node and that node dies, you have downtime even with 2 replicas. Anti-affinity rules tell K8s to schedule each replica on a different node:

```yaml
# Add to deployment template
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

With `preferredDuringScheduling`, K8s tries to spread pods across nodes but doesn't fail the deployment if it can't (e.g. during a node outage when fewer nodes are available).

### What to Add: Availability Zone Spreading

On clouds that support it (AWS, Azure, GCP — not Hetzner), spread worker nodes across 2-3 availability zones within a region. If an entire zone fails (power outage, network issue), the other zones continue:

| Cloud | How to configure | Zones available |
|-------|-----------------|-----------------|
| AWS EKS | Set subnets across AZs in Terraform | Typically 3 per region |
| Azure AKS | `availability_zones = ["1", "2", "3"]` in node pool config | 3 per region |
| GCP GKE | Use regional cluster (automatic 3-zone spread) | 3 per region |
| Hetzner | Not available — single data centre per location | N/A |

For Hetzner, zone spreading isn't possible. To survive a full Hetzner location failure, you need Level 4 (multi-region standby).

---

## Level 4 and 5: Multi-Region (When You Need It)

### Level 4: Cold or Warm Standby

Maintain a second cluster in a different region, ready to receive traffic if the primary fails:

```
Primary region (active)         Secondary region (standby)
  ├── Full cluster running        ├── Cluster provisioned but no app
  ├── Receives all traffic        ├── Velero restores available
  └── Velero backs up hourly      └── DNS failover switches here
```

**How failover works:**

1. Primary region fails (detected by health checks)
2. Velero restores the latest backup to the secondary cluster
3. DNS is updated to point to the secondary cluster's load balancer
4. Traffic starts flowing to the secondary region

**RTO:** 10-30 minutes (restore time + DNS propagation).
**RPO:** The time since the last backup.

### Level 5: Active-Active

Both regions run the application simultaneously. A global load balancer routes traffic to the nearest or healthiest region:

```
Global load balancer (Route 53 / Azure Front Door / GCP Global LB)
  ├── Region A (active)  ←→  Database replication  ←→  Region B (active)
  └── Health checks route traffic away from unhealthy regions
```

This is significantly more complex — you need database replication, conflict resolution for writes, and global load balancing. It's also significantly more expensive (double the infrastructure). For most projects, Level 3 or Level 4 is sufficient.

---

## Business Continuity by Environment

### Hetzner

**Strengths:** Cheap to run, fast to rebuild (IaC via Terraform), k3s upgrades are straightforward.

**Limitations:** No availability zones, no managed backup service, no native cross-region replication.

**BC strategy:**
- Level 1: `bb tf-apply` rebuilds in ~15 min (you have this)
- Level 2: Velero with off-site storage (Backblaze B2 or Wasabi — both S3-compatible, ~$5/month for modest data)
- Level 4: Cold standby cluster definition in a second Hetzner location. Keep `terraform/hetzner-fsn1/main.tf` ready. If Nuremberg fails, `CLOUD=hetzner-fsn1 bb tf-apply` + Velero restore

### AWS

**Strengths:** Multi-AZ out of the box, native backup services, most DR options of any cloud.

**BC strategy:**
- Level 2: Velero + S3 with cross-region replication
- Level 3: EKS across 3 AZs (configure subnets in Terraform), RDS Multi-AZ for databases
- Level 4: Velero restore to a second region, Route 53 DNS failover
- Level 5: EKS in two regions, Aurora Global Database, Global Accelerator

**AWS-specific tools:** S3 cross-region replication, EBS snapshot copying, Route 53 health checks, RDS Multi-AZ, Aurora Global, AWS Backup

### Azure

**Strengths:** AKS supports availability zones, geo-redundant storage is built in, integrated backup service.

**BC strategy:**
- Level 2: Velero + Azure Blob Storage (enable GRS for automatic geo-replication)
- Level 3: AKS across 3 availability zones
- Level 4: AKS in a second region, Azure Front Door for failover
- Level 5: Active-active with Azure Front Door, Cosmos DB multi-region writes

**Azure-specific tools:** Azure Backup for AKS, Azure Site Recovery, Azure Front Door, geo-redundant storage (GRS), Cosmos DB

### Google Cloud

**Strengths:** Regional GKE clusters spread control plane and nodes across 3 zones automatically — the strongest single-region HA of the major clouds.

**BC strategy:**
- Level 2: Velero + Cloud Storage (multi-region buckets replicate automatically), or Backup for GKE (managed service built on Velero)
- Level 3: Regional GKE cluster (automatic, no extra config)
- Level 4: GKE in a second region, Multi-Cluster Ingress
- Level 5: Multi-Cluster Ingress with Cloud SQL cross-region replicas

**GCP-specific tools:** Backup for GKE, Cloud Storage multi-region buckets, Cloud SQL cross-region replicas, Multi-Cluster Ingress

### On-Prem (Rancher-Managed)

**Depends on the customer's infrastructure.** Key questions to ask:

- Do they have multiple data centres?
- Is there shared storage (Ceph, NetApp) with built-in replication?
- Do they run Rancher in HA (3 control plane nodes)?
- Do they have an S3-compatible object store (MinIO) for Velero?

**BC strategy:**
- Level 2: Velero + customer's MinIO or replicate to a cloud bucket
- Level 3: Rancher-managed cluster across multiple racks (if hardware supports it)
- Level 4: Rancher managing clusters in two data centres, Velero restores across sites

---

## The Portable Tool: Velero Across All Environments

Velero is the common denominator. The CLI commands are the same everywhere — only the storage backend plugin changes:

| Storage backend | Velero plugin | Where |
|----------------|---------------|-------|
| AWS S3 | `velero-plugin-for-aws` | AWS, Hetzner (via MinIO), on-prem (via MinIO) |
| Azure Blob | `velero-plugin-for-microsoft-azure` | Azure |
| GCP Cloud Storage | `velero-plugin-for-gcp` | GCP |
| Any S3-compatible | `velero-plugin-for-aws` | MinIO, Backblaze B2, Wasabi, Ceph |

This means your backup and restore runbook is portable. `velero backup get`, `velero restore create` — the same commands work in every environment. Standardise on Velero and your DR procedures travel with you.

---

## Testing Your BC Plan

A backup you've never restored is hope, not a plan.

### Monthly DR Drill

```bash
# 1. Restore the latest backup to a test namespace
velero restore create dr-test-$(date +%Y%m) \
  --from-backup daily-full-latest \
  --namespace-mappings default:dr-test

# 2. Wait for pods
kubectl get pods -n dr-test -w

# 3. Verify the restored app works
kubectl port-forward -n dr-test svc/myapp 9090:8080
curl http://localhost:9090/health
# Should return: {"status":"ok"}

# 4. Record the results
echo "DR drill $(date): restore took X minutes, app healthy: yes/no" >> dr-drill-log.md

# 5. Clean up
kubectl delete namespace dr-test
```

### What to Record

| Metric | Why it matters |
|--------|---------------|
| Time from `velero restore create` to all pods healthy | Your actual RTO — does it meet the target? |
| Whether the app served traffic correctly | Did the restore produce a working system? |
| Any manual steps needed (DNS changes, secret recreation) | These increase real-world RTO |
| Data integrity (if applicable) | Did all records, uploads, and state survive? |

Keep `dr-drill-log.md` in the repo. It's evidence for compliance audits and your confidence that the plan actually works when you need it.

### Quarterly Full Failover Test (Level 4+)

If you have a standby cluster:

1. Provision the standby cluster (`bb tf-apply` in the standby location)
2. Restore Velero backup to the standby
3. Update DNS to point to the standby
4. Verify the app works via the public URL
5. Switch DNS back to primary
6. Destroy the standby cluster

This validates the entire failover chain, including DNS propagation time.

---

## Expected Downtime by Scenario

This table covers the scenarios you'll actually encounter, from routine deploys to worst-case disasters:

| Scenario | What happens | Downtime | Requires |
|----------|-------------|----------|----------|
| Code deploy (`git push`) | Rolling update, one pod at a time | **Zero** | 2+ replicas, readiness probes, `maxUnavailable: 0` |
| Hotfix | Same rolling update | **Zero** | Same as any deploy |
| k3s version upgrade | Nodes upgraded one at a time, pods rescheduled | **Zero for your app** (brief kubectl API blip) | PDB prevents both pods draining simultaneously |
| Single pod crash | K8s restarts the pod, other replica serves traffic | **Zero** | 2+ replicas |
| Single node failure | K8s reschedules pods to healthy nodes | **~30-60s** | 3+ nodes, pod anti-affinity |
| Bad deploy (app crashes on start) | Smoke test fails, Helm rolls back to previous version | **Zero to seconds** | Smoke test in `cd.yaml` or ArgoCD |
| Accidental `kubectl delete` of deployment | Service is down until redeployed | **Minutes** (manual `bb helm-prod`) or **seconds** (Velero/ArgoCD self-heal) | Velero or ArgoCD |
| Cluster destroyed accidentally | Full rebuild from IaC | **~15 min** | Terraform state intact |
| Terraform state lost | Manual cleanup + full rebuild | **~30-60 min** | Remote state backend prevents this |
| Data centre / region outage | Failover to standby cluster | **10-30 min** (Level 4) or **seconds** (Level 5) | Standby cluster + Velero + DNS failover |
| Ransomware / total compromise | Rebuild from Git + restore from off-site backup | **Hours** | Off-site Velero backups, Git repo intact |

---

## A Pragmatic Path Forward

You don't need to implement all five levels today. Evolve as the business requires:

**Now (you have this):**
Level 1 — reproducible infrastructure. If everything dies, `bb tf-apply` + `bb helm-prod` gets you back in 15 minutes.

**Next step (low effort, high value):**
Move Terraform state to a remote backend. This closes the biggest gap in Level 1.

**When you add a database:**
Install Velero with off-site backup storage. Schedule daily cluster backups and hourly app namespace backups. Set up database-specific backups (pg_dump, mysqldump, or managed service snapshots). Test a restore.

**When you have an SLA:**
Add pod anti-affinity rules. Move to a cloud with availability zones if you're not already on one. Set up Grafana alerts for backup job failures. Start monthly DR drills.

**When you need multi-region:**
Evaluate whether you need warm standby (Level 4) or active-active (Level 5). The answer depends on your RTO target and your budget. Most services are fine with Level 4.

---

## How This Connects to Other Docs

| Topic | Doc | Connection |
|-------|-----|-----------|
| Infrastructure as Code | [`docs/devops-and-gitops.md`](devops-and-gitops.md) | IaC is what makes Level 1 possible — rebuilding from Git |
| Multi-cloud portability | [`docs/multi-cloud.md`](multi-cloud.md) | Velero and Terraform work across clouds — your BC strategy is portable |
| Secrets management | [`docs/secrets-management.md`](secrets-management.md) | Vault secrets must be included in BC planning — back up Vault too |
| Customer deployments | [`docs/on-prem-customer-deployment.md`](on-prem-customer-deployment.md) | On-prem BC depends on the customer's infrastructure capabilities |
| Zero-downtime deployments | Main guide, "Downtime" section | Rolling updates and PDBs are Level 3 HA — they prevent downtime during normal operations |
