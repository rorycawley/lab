# Phase 13: Container Hardening


Phase 13 hardens every container in the demo to the Pod Security Admission
"restricted" profile, so a workload that lands in a pod has no Linux
capabilities, no privilege escalation, no writable root filesystem, a
RuntimeDefault seccomp profile, an explicit non-root UID, and explicit
resource requests and limits.

Goal:

```text
Make non-conforming Pods fail at admission, and prove that the conforming Pods
still satisfy every previous phase: dynamic credentials, CRUD, denied DB ops,
TLS, and NetworkPolicy denials.
```

This phase changes:

```text
app/Dockerfile                         non-root UID 1000 with chowned /app
k8s/00-namespaces.yaml                 PSA enforce/audit/warn = restricted on demo and vault
k8s/07-vault-deployment.yaml           securityContext, resources, read-only root with tmpfs volumes
k8s/09-vault-injector-smoke-pod.yaml   securityContext and resources for the smoke Pod
k8s/10-python-app-deployment.yaml      pod and container securityContext, /tmp emptyDir, resources
k8s/14-vault-tls-proxy-configmap.yaml  nginx config writes pid, logs, temp paths to /tmp
scripts/15-install-vault-agent-injector.sh   Helm values for restricted-compatible injector + agent
docker-compose.yml                     no-new-privileges, drop ALL capabilities, add only minimum
```

Per-container hardening shape:

```text
pod-level:
  runAsNonRoot: true
  runAsUser:   1000 (app) | 100 (vault, smoke) | injector chart default
  fsGroup:     1000
  seccompProfile.type: RuntimeDefault

container-level:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem:   true
  capabilities.drop:        [ALL]
  seccompProfile.type:      RuntimeDefault
  resources.requests / resources.limits: cpu and memory both set
```

Vault Agent sidecar:

```text
vault.hashicorp.com/agent-set-security-context: "true"
vault.hashicorp.com/agent-run-as-same-user:     "true"
```

The agent therefore runs as the same UID as the app container, which keeps the
rendered file (`/vault/secrets/db-creds`, mode 0400) readable by the app.

Acceptance criteria:

- namespaces `demo` and `vault` enforce `pod-security.kubernetes.io/enforce: restricted`
- a Pod with `securityContext.privileged: true` is rejected at admission in `demo`
- every Pod in `demo` and `vault` runs as a non-root user
- every container in `demo` and `vault` sets `allowPrivilegeEscalation: false`
- every container drops all Linux capabilities
- every container sets `seccompProfile.type: RuntimeDefault`
- every container has CPU and memory requests and limits
- the Python app container runs with `readOnlyRootFilesystem: true`
- writing to `/` from the app container fails at runtime
- the app's runtime UID is non-zero
- the Vault Agent sidecar still renders `/vault/secrets/db-creds`
- the app still connects with a Vault-generated `v-...` runtime user
- the app still proves `DROP TABLE` and `CREATE ROLE` are denied
- the Phase 12 NetworkPolicy denials still hold

Documented limitations of this phase:

```text
The Vault Agent Injector mutates Pods after admission, so the injected sidecar's
securityContext is set by Helm values on the injector chart, not by the
application Deployment. A change to chart values is required for the sidecar
to satisfy "restricted".

PostgreSQL runs in Docker Compose, not in Kubernetes. We harden it with
no-new-privileges and a minimal capability set, but we do not run it under
read-only root because the official postgres entrypoint requires write access
to several non-volume paths during initialization.

The PSA "restricted" profile is enforced by the Kubernetes API server using a
built-in admission plugin. It does not require an external policy engine such
as Kyverno or OPA Gatekeeper. Production hardening typically adds one of
those engines for image-signature, registry, and supply-chain controls that
PSA does not cover.
```

Run Phase 13 against a fresh cluster:

```sh
make up
```

Re-apply Phase 13 to an already-running cluster from earlier phases:

```sh
make harden
```

Verify only container hardening:

```sh
make verify-harden
```

The verify script requires `jq`.

