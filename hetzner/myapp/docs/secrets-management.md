# Secrets Management

> **Context:** This document is a companion to the main [GUIDE.md](../GUIDE.md). The guide gets you deployed with pragmatic shortcuts suitable for a personal project. This document explains why those shortcuts become problems at scale, and how to evolve toward proper secrets management — from quick fixes to HashiCorp Vault to a fully vendor-agnostic approach using the Kubernetes Secrets Store CSI Driver.

> **Status:** Phase 1 of the evolution path is complete. Monitoring credentials (Grafana admin, MinIO root) have been migrated from inline values files to Sealed Secrets at `monitoring/secrets/`. The remaining items (Hetzner token, kubeconfig, CI auth) still follow the original pragmatic-shortcut model and are candidates for the later phases below.

---

## Where Secrets Live Today

This project has secrets scattered across several locations. Each was chosen for simplicity during initial setup, not for security.

| Secret | Where it lives | Who can access it | Risk |
|--------|---------------|-------------------|------|
| Hetzner API token | `.zshrc` env var, `terraform.tfstate` | Anyone with laptop access | Full cloud infrastructure control |
| Kubeconfig | `myapp_kubeconfig.yaml` (local file) | Anyone who copies the file | Full cluster admin — deploy, delete, read secrets |
| GHCR credentials | `gh` CLI token | Anyone with laptop access | Push arbitrary images to your registry |
| MinIO root password | `monitoring/secrets/minio-root-creds.sealedsecret.yaml` (Sealed Secret in Git) — also injected into Mimir via `global.extraEnvFrom` | Anyone with cluster admin (the controller decrypts to a `Secret` in `monitoring`) | Access to stored metrics |
| Grafana admin password | `monitoring/secrets/grafana-admin-creds.sealedsecret.yaml` (Sealed Secret in Git) | Same | Modify dashboards, read all monitoring data |
| GitHub Actions KUBE_CONFIG | GitHub encrypted secrets | GitHub Actions runners, repo admins | Full cluster access from CI/CD |
| GitHub Actions PROD_HOST | GitHub Actions variable (not secret) | Public — visible in workflow logs | Not sensitive, but included for completeness |

**For a personal learning project, this is fine.** You're the only user, the data isn't sensitive, and the cluster costs €30/month. The trade-off between security and simplicity is acceptable.

**For production with real users, the remaining gaps are:**

1. **Pre-migration passwords are in Git history.** `admin-change-me` and `minio-secret-key-change-me` were committed before the Sealed Secrets migration and are recoverable via `git log`. The seal helper now generates fresh random values, so the leaked defaults no longer match the running cluster — but treat them as burned and never reuse those strings.

2. **Cluster credentials in CI.** The kubeconfig stored as a GitHub Secret (`KUBE_CONFIG`) grants full cluster admin access. This is a pragmatic shortcut — it works and is simple. But it means that if your GitHub account or repository is compromised, the attacker has complete access to your production cluster. Managed Kubernetes services (EKS, AKS, GKE) support stronger patterns like workload identity federation (OIDC), where the CI system authenticates without static credentials. Those are worth adopting when you move to a managed cloud provider.

3. **Sealed Secrets controller key is cluster-scoped.** When the cluster is destroyed and recreated, the existing `*.sealedsecret.yaml` files become unreadable to the new controller. Either back up `kube-system/sealed-secrets-key*` Secrets before destroy, or rerun `bb monitoring-seal-secrets` after the rebuild to generate fresh credentials.

---

## Kubernetes Native Secrets: What They Are and Why They're Not Enough

Before looking at external secrets managers, it's worth understanding what Kubernetes provides natively.

A Kubernetes Secret is a resource that stores small amounts of sensitive data (passwords, tokens, certificates). You create one like this:

```bash
kubectl create secret generic myapp-db-creds \
  --from-literal=username=app \
  --from-literal=password=db-secret-password
```

Pods can consume it as environment variables or mounted files:

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: myapp-db-creds
        key: password
```

This is better than hardcoding passwords in your Helm values — the secret value isn't in Git, and Kubernetes controls who can read it via RBAC. But Kubernetes Secrets have significant limitations:

**Base64, not encrypted at rest (by default).** Secret values are base64-encoded, not encrypted. Anyone with `kubectl get secret -o yaml` access can decode them. Encryption at rest requires enabling an encryption provider on the API server — not all clusters configure this.

**No audit trail.** Kubernetes logs API requests, but doesn't provide granular "who read this secret at what time" auditing designed for compliance.

**No rotation.** If a password changes, you must manually update the Secret and restart pods that use it. There's no built-in mechanism to push a new value to running applications.

**Cluster-scoped.** Secrets exist only within one cluster. If you have multiple clusters (dev, staging, production) or services outside Kubernetes, each needs its own copy, managed separately.

**No dynamic secrets.** Every secret is static — you set the value, and it stays until you change it. There's no concept of generating short-lived credentials on demand.

Kubernetes Secrets are the right starting point for simple cases. For anything beyond that, you need a dedicated secrets manager.

---

## Quick Wins: Getting Passwords Out of Git

Before investing in Vault, fix the most obvious problem: passwords committed to the repository.

> **Already done in this repo** — the monitoring stack uses Option 2 (Sealed Secrets). The two options below are documented for understanding and for cases where Sealed Secrets isn't available.

### Option 1: kubectl create secret (manual)

Move the MinIO and Grafana passwords out of the values files and into Kubernetes Secrets:

```bash
# Create secrets manually
kubectl create secret generic minio-creds \
  --namespace monitoring \
  --from-literal=rootPassword=your-actual-password

kubectl create secret generic grafana-creds \
  --namespace monitoring \
  --from-literal=adminPassword=your-actual-password
```

Then reference them from the Helm values files using `existingSecret` fields (most Helm charts support this):

```yaml
# monitoring/values-minio.yaml
existingSecret: minio-creds

# monitoring/values-grafana.yaml
admin:
  existingSecret: grafana-creds
  userKey: adminUser
  passwordKey: adminPassword
```

Remove the plain-text passwords from the values files and commit the change. The passwords are now in the cluster's etcd, not in Git.

**Limitation:** someone has to run `kubectl create secret` manually. If the cluster is destroyed and recreated, the secrets are lost — you need to recreate them.

### Option 2: Sealed Secrets (encrypted secrets in Git) — **in use**

Sealed Secrets solves the "manual recreation" problem. It lets you encrypt secrets with a cluster-specific public key and commit the encrypted version to Git. Only the Sealed Secrets controller running in the cluster can decrypt them.

This repo already wires it up:

- `monitoring/seal-secrets.sh` (run via `bb monitoring-seal-secrets`) installs the controller into `kube-system`, generates fresh random passwords, and seals them into `monitoring/secrets/{grafana-admin,minio-root}-creds.sealedsecret.yaml`.
- `monitoring/install.sh` (run via `bb monitoring-install`) verifies the controller is present, applies the sealed YAMLs, waits for them to materialize as `Secret`s, then installs the LGTM stack pointing at those Secrets via `existingSecret`. Mimir reads the same MinIO Secret as env vars (`global.extraEnvFrom`) and substitutes them into its config via `-config.expand-env=true`, so MinIO and Mimir credentials always stay in sync.
- The `*.sealedsecret.yaml` files are committed to Git. They're safe — only the controller in the cluster they were sealed for can decrypt them.

**What this gives you:** secrets in Git (for reproducibility) without plain-text values in Git (for security). If the cluster is destroyed and recreated, you install the Sealed Secrets controller, apply the sealed secrets from Git, and everything works.

**Limitation:** the encryption key is cluster-specific. If you lose the cluster's private key (stored as a Secret in the `kube-system` namespace), you can't decrypt the sealed secrets. Back up the key (`kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > backup.yaml`), or accept that you'll need to re-seal secrets after a full cluster rebuild — `bb monitoring-seal-secrets` is idempotent and will regenerate the YAMLs against the new controller's key.

---

## HashiCorp Vault: Full Secrets Management

When you need centralised access control, audit logging, secret rotation, or dynamic credentials, Vault is the standard tool.

### What Vault Provides

Vault is a dedicated secrets management service. It runs as a server (inside or outside your cluster) and provides:

| Capability | What it means |
|-----------|--------------|
| Centralised storage | All secrets in one place, organised by path |
| Fine-grained access control | Policies define who can read which secrets |
| Audit logging | Every read, write, and list is logged with timestamp and identity |
| Automatic rotation | Vault can rotate secrets on a schedule, pushing new values to consumers |
| Dynamic secrets | Generate short-lived database credentials on demand — each pod gets unique credentials that expire |
| Encryption as a service | Encrypt/decrypt data without exposing the key (transit backend) |
| PKI certificate issuance | Generate TLS certificates for internal service-to-service communication |

### How Vault Stores Secrets

Vault organises secrets in a hierarchical path structure. Policies control access at the path level:

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

A policy for the myapp service account might allow reading `secret/data/myapp/*` but deny access to `secret/data/infrastructure/*`. The CI pipeline might have a separate policy allowing only Harbor credentials.

### How Vault Authenticates Pods

Vault doesn't use passwords to authenticate pods — it uses Kubernetes service account tokens. When a pod starts:

1. The pod presents its Kubernetes service account token to Vault
2. Vault verifies the token with the Kubernetes API server ("is this really pod X in namespace Y with service account Z?")
3. Vault checks which Vault role is bound to that service account
4. Vault returns a short-lived Vault token scoped to the role's policies
5. The pod uses the Vault token to read secrets

No passwords are baked into the pod spec, the Helm values, or the Docker image. Authentication is based on the pod's identity, not a static credential.

---

## Three Ways to Get Vault Secrets into Pods

Each approach trades off simplicity, features, and coupling. All three are production-viable.

### Option 1: Vault Sidecar Injector (recommended starting point)

A sidecar container runs alongside your app in the same pod. It authenticates to Vault, fetches secrets, and writes them to a shared in-memory volume (`tmpfs`). Your app reads secrets from files — it doesn't import any Vault libraries or know Vault exists.

**How to use it:** Add annotations to your pod spec:

```yaml
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

**What happens at runtime:** The secret appears as a file at `/vault/secrets/db-password`. Your Clojure app reads it:

```clojure
(defn read-secret [name]
  (-> (str "/vault/secrets/" name)
      slurp
      clojure.string/trim))

(def db-password (read-secret "db-password"))
```

**Strengths:** Automatic token renewal. Automatic secret re-fetching on rotation. In-memory storage (secrets never touch disk). Your app is completely Vault-unaware — it just reads files.

**Weaknesses:** Adds a sidecar container to every pod (small memory overhead). Secrets are only available as files, not environment variables (though you can use agent templating to write an env file).

### Option 2: Vault CSI Driver

The Secrets Store CSI Driver mounts secrets as ephemeral volumes via the standard Kubernetes Container Storage Interface. You define a `SecretProviderClass` resource:

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

Your pod mounts it as a volume:

```yaml
volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: myapp-secrets
```

**Strengths:** Can sync secrets to Kubernetes Secrets (making them available as environment variables). Standard CSI interface — the same volume mount works with any CSI-compatible provider. No sidecar overhead.

**Weaknesses:** No automatic secret rotation (secrets are fetched at pod startup, not refreshed). Uses `hostPath` volumes, which some platforms (OpenShift) disable by default. Only supports Kubernetes auth method.

### Option 3: Vault Secrets Operator (VSO)

The newest approach. A Kubernetes operator watches custom resources and syncs their values into standard Kubernetes Secrets:

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
    name: myapp-db-secret
    create: true
```

The operator creates a Kubernetes Secret called `myapp-db-secret`. Your pod consumes it like any K8s Secret — via `envFrom` or volume mounts. The pod doesn't know Vault is involved.

**Strengths:** Your app consumes standard Kubernetes Secrets — zero Vault awareness. The operator handles authentication, renewal, and rotation. When a secret changes in Vault, the operator updates the K8s Secret automatically.

**Weaknesses:** Secrets pass through etcd (as Kubernetes Secrets), so you depend on etcd encryption at rest. Newer approach with a smaller community compared to the sidecar injector.

### Choosing Between Them

| Factor | Sidecar Injector | CSI Driver | Secrets Operator |
|--------|-----------------|------------|-----------------|
| Vault awareness in app | None (reads files) | None (reads files) | None (reads env vars / files) |
| Secret rotation | Automatic | On pod restart only | Automatic |
| Secrets in etcd | No (in-memory only) | Optional sync | Yes (as K8s Secrets) |
| Sidecar overhead | Yes (per pod) | No | No |
| Provider portability | Vault only | Any CSI provider | Vault only |

For most teams starting with Vault, the **sidecar injector** is the recommended starting point — it's the most battle-tested, supports rotation, and keeps secrets out of etcd.

---

## Migrating This Project to Vault

### Step 1: Install Vault

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  -n vault --create-namespace \
  --set "server.dev.enabled=true"
```

Dev mode is fine for learning. For production, use auto-unseal (via a cloud KMS), high availability (3 replicas), and persistent storage. The Vault Helm chart supports all of this via values.

### Step 2: Store Secrets

```bash
kubectl port-forward -n vault svc/vault 8200:8200
export VAULT_ADDR=http://localhost:8200

vault kv put secret/myapp/database username=app password=db-secret-password
vault kv put secret/myapp/grafana admin-password=grafana-secret
vault kv put secret/myapp/minio root-password=minio-secret
```

### Step 3: Create Policy and Role

```bash
# Policy: myapp can only read its own secrets
vault policy write myapp - <<EOF
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
EOF

# Enable Kubernetes auth
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# Bind policy to the myapp service account
vault write auth/kubernetes/role/myapp \
  bound_service_account_names=default \
  bound_service_account_namespaces=default \
  policies=myapp \
  ttl=1h
```

### Step 4: Update Helm Chart

Add Vault annotations to `helm/myapp/templates/deployment.yaml`, behind a toggle:

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

### Step 5: Update Values

```yaml
# values-prod.yaml
vault:
  enabled: true
  role: myapp
  secrets:
    db-password:
      path: "secret/data/myapp/database"
```

### Step 6: Remove Passwords from Git

Delete plain-text passwords from `monitoring/values-minio.yaml` and `monitoring/values-grafana.yaml`. Replace with `existingSecret` references. Commit the removal — the old values remain in Git history, so rotate those passwords in Vault to invalidate the leaked values.

---

## Staying Vendor-Agnostic: The CSI Driver Approach

Vault is open source and runs anywhere, which makes it a good default. But if you want to be truly infrastructure-agnostic — able to use Vault on Hetzner, AWS Secrets Manager on EKS, and Azure Key Vault on AKS without changing your deployment templates — use the Secrets Store CSI Driver.

The CSI Driver is a standard Kubernetes interface. Multiple providers plug into the same interface:

| Provider | Plugin | When to use |
|----------|--------|-------------|
| HashiCorp Vault | `vault` | Self-hosted, any cloud, on-prem |
| AWS Secrets Manager | `aws` | AWS-native, IAM-integrated |
| Azure Key Vault | `azure` | Azure-native, Azure AD-integrated |
| GCP Secret Manager | `gcp` | GCP-native, IAM-integrated |

Your deployment template always uses the same volume mount:

```yaml
volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: myapp-secrets
```

Only the `SecretProviderClass` changes between providers. On Hetzner with Vault:

```yaml
spec:
  provider: vault
  parameters:
    roleName: "myapp"
    objects: |
      - objectName: "db-password"
        secretPath: "secret/data/myapp/database"
        secretKey: "password"
```

On AWS with Secrets Manager:

```yaml
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "arn:aws:secretsmanager:eu-west-1:123456789:secret:myapp/database"
        objectType: "secretsmanager"
        jmesPath:
          - path: password
            objectAlias: db-password
```

Same deployment template. Same volume mount path. Same file-reading code in your Clojure app. The infrastructure team decides which provider to use — the application developer doesn't need to know.

This is the same abstraction pattern used elsewhere in the project: ingress class (Traefik vs nginx), storage class (Hetzner volumes vs EBS vs Azure Disks), and monitoring backend (LGTM vs Datadog vs CloudWatch). The application speaks to a standard interface, and the infrastructure provides the implementation.

---

## Cloud-Native Alternatives

If you're on a single cloud and don't need portability, cloud-native secrets managers are simpler than operating Vault yourself:

| Service | Cloud | Key strengths | How to integrate |
|---------|-------|---------------|-----------------|
| AWS Secrets Manager | AWS | IAM integration, automatic RDS credential rotation | AWS CSI provider, or External Secrets Operator |
| Azure Key Vault | Azure | Azure AD integration, stores certificates and encryption keys | Azure CSI provider, or AKS-native integration |
| GCP Secret Manager | GCP | IAM integration, automatic cross-region replication | GCP CSI provider, or Workload Identity |

**When to use Vault instead:** when you're multi-cloud, on-prem, or need capabilities the cloud-native services don't offer — dynamic secrets (short-lived database credentials generated per pod), encryption as a service (encrypt/decrypt data without exposing keys), or PKI certificate issuance for mTLS between services.

---

## A Pragmatic Evolution Path

You don't need Vault on day one. Evolve as the need arises:

| Phase | What you do | What it fixes | Status |
|-------|------------|---------------|--------|
| **1. Passwords out of Git** | `kubectl create secret` or Sealed Secrets | Plain-text passwords visible in Git history | ✅ Done — Sealed Secrets, see `monitoring/secrets/` |
| **2. Learn Vault** | Install Vault in dev mode, move MinIO/Grafana passwords | Scattered secrets, no access control | Worth doing when you add a database or a second team member |
| **3. Production Vault** | Auto-unseal, HA, audit logging, migrate all secrets | No audit trail, no rotation, no access control | For production systems with compliance requirements |
| **4. Dynamic secrets** | Configure Vault database backend for short-lived credentials | Static long-lived database passwords | After Phase 3 |
| **5. Multi-provider** | Switch to CSI Driver interface | Locked to Vault specifically | For multi-cloud deployments |

---

## Security Patterns Worth Adopting Early

Even without Vault, these practices significantly improve your security posture:

**Rotate the leaked passwords.** The pre-migration MinIO and Grafana defaults (`minio-secret-key-change-me`, `admin-change-me`) are in Git history forever and recoverable via `git log`. The Sealed Secrets migration replaces them with random values, so the leaked strings no longer match the running cluster — but never reuse those defaults. To rotate again later, run `bb monitoring-seal-secrets` (it overwrites the YAMLs with fresh random values) and restart the affected pods.

**Use imagePullSecrets instead of public images.** Making GHCR packages public (as recommended in the main guide for simplicity) means anyone can pull your container image. For production, keep packages private and configure an `imagePullSecret` in your Helm chart — or use a private registry like Harbor.

**Replace static kubeconfig with OIDC/workload identity.** The `KUBE_CONFIG` GitHub Secret contains a static kubeconfig with full cluster admin access. On managed Kubernetes services (EKS, AKS, GKE), use the cloud provider's GitHub Actions auth action with workload identity federation — the CI system authenticates via OIDC without any static credentials.

**Scope service accounts.** The default Kubernetes service account has broad permissions. Create a dedicated service account for your app with only the permissions it needs (e.g., read ConfigMaps in its own namespace, nothing else).

---

## How This Connects to Other Docs

| Topic | Doc | Connection |
|-------|-----|-----------|
| DevOps principles | [`docs/devops-and-gitops.md`](devops-and-gitops.md) | GitOps means Git is the source of truth — but secrets are the exception. Vault fills the gap. |
| Multi-cloud portability | [`docs/multi-cloud.md`](multi-cloud.md) | The CSI Driver approach keeps secrets portable across clouds, just like the ingress class abstraction. |
| On-prem customer deployment | [`docs/on-prem-customer-deployment.md`](on-prem-customer-deployment.md) | Customers may provide their own Vault instance or secrets manager. The CSI Driver interface adapts. |
| Business continuity | [`docs/business-continuity.md`](business-continuity.md) | Vault's audit log and access control are often compliance requirements for BC plans. |
