# Troubleshooting

> **Context:** This document consolidates all troubleshooting information from across the project. When something breaks, come here. It's organized by symptom — what you see — rather than by component, because when you're debugging you know what's wrong, not necessarily which layer caused it.

---

## First Response: The Triage Sequence

When something isn't working, run these four commands in order. They answer increasingly specific questions:

```bash
bb k8s-status         # 1. What state are the pods in?
bb k8s-describe       # 2. What events led to this state? (look at the Events section)
bb k8s-logs           # 3. What is the application printing?
bb k8s-shell          # 4. What's happening inside the container?
```

The Events section at the bottom of `bb k8s-describe` output almost always identifies the problem — image pull errors, probe failures, resource limits, scheduling issues. Start there before going deeper.

For Grafana-based debugging (production, after monitoring is installed):

```bash
bb grafana            # Open Grafana → http://localhost:3000 (creds set by bb monitoring-seal-secrets)
```

Then: **Explore → Loki** for logs, **Explore → Mimir** for metrics, **Explore → Tempo** for traces.

---

## Pods Won't Start

### Pod is `Pending`

**Symptom:** `bb k8s-status` shows pod stuck in `Pending`.

**Cause 1: Not enough resources.**

```bash
kubectl describe pod <pod-name>
# Look for: "Insufficient cpu" or "Insufficient memory" in Events
```

Fix: Reduce resource requests in your values file, or add a worker node in `main.tf`.

**Cause 2: No nodes are ready.**

```bash
kubectl get nodes
# If nodes show NotReady, they're still initialising (wait 1-2 minutes after tf-apply)
```

**Cause 3: PersistentVolumeClaim can't be bound.**

```bash
kubectl get pvc
# If PVC shows Pending, the storage provisioner isn't working
kubectl describe pvc <name>
```

On Hetzner, this usually means the Hetzner CSI driver isn't running yet. Wait a minute after cluster creation.

### Pod is `CrashLoopBackOff`

**Symptom:** Pod starts, crashes, K8s restarts it, it crashes again. The restart count climbs.

**Cause 1: Application crashes on startup.** Check the logs:

```bash
bb k8s-logs
# Look for: NullPointerException, ClassNotFoundException, "Address already in use"
```

If you see a Java exception, fix the code. If you see "Address already in use", another process is using port 8080.

**Cause 2: Health probe kills the pod before it's ready.**

```bash
bb k8s-describe
# Look for: "Liveness probe failed: connection refused"
```

The JVM takes 15-30 seconds to start (longer with the OTel agent). If the liveness probe fires before the app is listening, K8s kills the pod. The `initialDelaySeconds` is set to 45 to account for this. If you've added heavy startup logic (loading large datasets, connecting to slow databases), increase it in your values file:

```yaml
health:
  initialDelaySeconds: 60    # was 45
```

**Cause 3: OTel agent can't connect to Alloy.**

```bash
bb k8s-logs
# Look for: "Failed to export spans" or "Connection refused: alloy.monitoring.svc:4318"
```

These errors appear when `otel.enabled` is `"true"` but the monitoring stack isn't installed yet. The errors are noisy but not always fatal — however they can slow startup enough to trigger probe failures. Fix: set `otel.enabled: "false"` in your values file, or install monitoring first (`bb monitoring-install`).

### Pod is `ImagePullBackOff`

**Symptom:** Pod can't pull the Docker image from the registry.

**Cause 1: GHCR package is private.**

```bash
bb k8s-describe
# Look for: "401 Unauthorized" or "403 Forbidden"
```

Fix: Make the package public. Go to `github.com/YOUR_USER?tab=packages` → `myapp` → **Package settings → Danger Zone → Change visibility → Public**.

For production with private images, configure an `imagePullSecret` instead.

**Cause 2: Image was built for the wrong architecture.**

```bash
bb k8s-describe
# Look for: "no match for platform in manifest"
```

Your Mac builds ARM images by default. Hetzner needs `linux/amd64`. Fix: Use `bb docker-push` which builds for amd64 automatically. `bb docker-build` is for local dev only.

**Cause 3: Image tag doesn't exist.**

```bash
bb k8s-describe
# Look for: "manifest unknown" or "tag not found"
```

The image tag in the Helm values doesn't match what's in GHCR. Check what tags exist:

```bash
# List tags in GHCR
gh api user/packages/container/myapp/versions --jq '.[].metadata.container.tags[]'
```

**Cause 4: Registry is unreachable.** Check that `ghcr.io` is accessible from the cluster. On air-gapped or heavily firewalled networks, you may need a private registry like Harbor.

### Pod is `Terminating` (Stuck)

**Symptom:** Pod stays in `Terminating` state for a long time.

```bash
# Force delete (use with caution)
kubectl delete pod <pod-name> --grace-period=0 --force
```

This usually happens when the node hosting the pod has become unreachable. The pod will eventually be cleaned up, but force-deleting speeds it up.

---

## Application Issues

### App Returns Wrong Status Code / Wrong Response

This is a code issue, not an infrastructure issue. Debug in the REPL:

```bash
bb dev
# → (start)
# → curl http://localhost:8080/your-endpoint
# → fix code → eval → test again
```

The REPL gives you instant feedback. Don't debug application logic through Kubernetes.

### App Works Locally but Not in Kubernetes

This means the problem is in the boundary between your code and the container/cluster. Common causes:

**Missing environment variable.** Your code reads an env var that exists on your Mac but isn't set in the Helm chart. Check what env vars the pod sees:

```bash
bb k8s-shell
# Inside the pod:
env | sort
```

Compare with what your Helm deployment template sets. Add missing vars to `values.yaml`.

**Different Java version.** The Dockerfile uses a specific JRE. If your code depends on a newer Java feature:

```bash
bb k8s-shell
java -version
```

**File path differences.** Paths that exist on your Mac (`/Users/you/...`) don't exist in the container. Hardcoded paths will fail.

### App is Slow

Use Grafana to diagnose:

```bash
bb grafana
```

**Check latency:** Explore → Mimir → `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))`. This shows p99 latency. If it's spiking, look at what changed.

**Check JVM:** Dashboard → JVM Metrics. Look at heap usage and GC frequency. If the JVM is spending more than 10% of time in GC, you need more memory (increase `resources.limits.memory` in values).

**Check traces:** Explore → Tempo → search by service name. Find a slow request and look at the waterfall — it shows exactly where time was spent (HTTP handler, database query, external API call).

---

## Docker and Registry Issues

### `docker build` Fails

**`error: failed to solve: failed to read dockerfile`** — you're running the command from the wrong directory. Run from the project root (where the Dockerfile is).

**Dependencies fail to download** — check your internet connection. If behind a corporate proxy, configure Docker's proxy settings.

**Build succeeds but image is huge** — check that `.dockerignore` exists and excludes `terraform/`, `monitoring/`, `helm/`, `.git/`, `target/`.

### Can't Push to GHCR

**`denied: permission_denied`** — your `gh` token doesn't have `write:packages` scope:

```bash
gh auth refresh --scopes write:packages
```

Then re-authenticate Docker:

```bash
echo $(gh auth token) | docker login ghcr.io -u $(gh api user -q .login) --password-stdin
```

**`unauthorized: unauthenticated`** — Docker isn't logged in to GHCR at all. Run the login command above.

### Image Pushed but CI/CD Can't Use It

**Package not linked to repo.** GHCR packages created before the repo need manual linking:

Go to `github.com/YOUR_USER?tab=packages` → `myapp` → **Package settings → Manage Actions access → Add Repository → myapp → Write**.

**Workflow permissions.** The `GITHUB_TOKEN` needs write access to packages:

Go to repo → **Settings → Actions → General → Workflow permissions → Read and write permissions**.

---

## Hetzner and Terraform Issues

### Packer Fails

**`SSH key "k3s" already exists`** — a stale key from a previous run. Delete it: Hetzner Console → Security → SSH Keys → delete `k3s`.

**Snapshot creation times out** — retry. Hetzner's API can be slow during peak hours.

### Terraform Apply Fails

**`server type unavailable in location`** — not all types exist in all locations. Change the location in `main.tf`. The config uses `nbg1` (Nuremberg). Try `hel1` (Helsinki) or `fsn1` (Falkenstein).

**`resource already exists`** — Terraform state is out of sync with reality. This happens when you manually create or delete resources in the Hetzner Console. Options:

```bash
# Import the existing resource into state
terraform import <resource_type>.<name> <id>

# Or start fresh: delete everything from Hetzner Console, remove state
rm terraform/terraform.tfstate
bb tf-apply
```

### Terraform State Lost

`terraform.tfstate` maps your config to real Hetzner resources. Without it, Terraform tries to create duplicates.

**Recovery steps:**
1. Log in to Hetzner Console
2. Manually delete: all servers, the load balancer, the network, the firewall, any SSH keys created by Terraform, all volumes
3. Remove the stale state: `rm terraform/terraform.tfstate*`
4. Recreate: `bb tf-apply`

**Prevention:** Use a remote state backend (S3, MinIO) instead of a local file. See `docs/hetzner-deployment.md` for the configuration.

### Orphaned Hetzner Volumes

After `bb tf-destroy`, volumes sometimes remain because PVCs weren't deleted before the cluster was destroyed. Check Hetzner Console → Volumes.

```bash
# List orphaned volumes
hcloud volume list

# Delete them
hcloud volume list -o noheader -o columns=id | xargs -I {} hcloud volume delete {}
```

`bb tf-destroy` attempts this cleanup automatically, but it can miss volumes if the cluster was partially destroyed.

### Billing Continues After Destroy

Verify in Hetzner Console that no resources remain: Servers, Load Balancers, Volumes, Floating IPs, Networks. If any persist, delete them manually. Billing is hourly — once the resource is deleted, charges stop for the next hour.

---

## DNS and TLS Issues

### DNS Not Resolving

```bash
dig yourdomain.com +short
# Should return your load balancer IP
```

**Returns nothing:** DNS records haven't propagated yet. Wait 5-30 minutes. Namecheap is typically 5-15 minutes.

**Returns wrong IP:** A stale DNS record from a previous cluster. Update the A records at your registrar.

**Works with `dig @8.8.8.8` but not `dig`:** Your local DNS cache is stale. Flush it:

```bash
# macOS
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

### TLS Certificate Won't Issue

```bash
kubectl get certificate
# READY should be True
```

If `READY: False` persists for more than 2 minutes:

```bash
kubectl describe certificate myapp-tls     # certificate status
kubectl describe order -A                  # ACME order status
kubectl describe challenge -A             # HTTP-01 challenge details
```

**Challenge status `Pending` + `Waiting for HTTP-01 challenge propagation`:**

Let's Encrypt can't reach your server. Causes:
- DNS not propagated yet (most common — wait longer)
- Wrong IP in DNS records
- Hetzner load balancer hasn't assigned an IP yet (`kubectl get svc -A | grep traefik` — check EXTERNAL-IP isn't `<pending>`)

**Challenge status `Invalid`:**

Let's Encrypt tried and failed. Causes:
- ClusterIssuer misconfigured (wrong ingress class, typo in email)
- Firewall blocking port 80 (HTTP-01 needs port 80 open)

**Rate limited:**

Let's Encrypt allows 50 certificates per domain per week. If you've been destroying and recreating the cluster repeatedly, you may have hit this limit. Wait a week, or use Let's Encrypt staging endpoint for testing:

```bash
# In ClusterIssuer, change server to:
# https://acme-staging-v02.api.letsencrypt.org/directory
# Staging certs aren't trusted by browsers but don't have rate limits
```

### Certificate Stops Renewing

cert-manager renews at day 60 of 90. If renewal fails silently, you won't know until the certificate expires.

```bash
bb cert-status
# Shows READY status, expiry date, and next renewal time
```

**Let's Encrypt no longer sends expiry warning emails** (discontinued June 2025). Set up a Grafana alert:

```promql
certmanager_certificate_expiration_timestamp_seconds - time() < 14 * 24 * 3600
```

This fires if any certificate is less than 14 days from expiry — meaning renewal has been failing for at least 16 days.

**Common renewal failure causes:**
- cert-manager pod crashed or was evicted — check `kubectl get pods -n cert-manager`
- DNS records changed (A record no longer points to the cluster)
- Load balancer IP changed after a cluster rebuild (update DNS)

### ClusterIssuer Missing After Cluster Rebuild

The ClusterIssuer is a Kubernetes resource — it doesn't survive `bb tf-destroy`. Recreate it:

```bash
bb cluster-issuer
```

The certificate itself is also lost, but cert-manager re-issues it automatically when you redeploy the Ingress.

---

## CI/CD Issues

### CI Build Fails

**`docker build` fails in GitHub Actions** — the same Dockerfile works locally:
- Different platform: CI builds `linux/amd64`, your Mac builds ARM. Platform-specific issues appear here.
- Network: GitHub runners sometimes can't reach certain registries or Maven mirrors. Retry usually works.
- Disk space: if your image is very large, the runner may run out of space.

Check the CI run logs: repo → **Actions** tab → click the failed run → click the failed step.

### CD Deploy Fails

**`KUBE_CONFIG` secret is invalid or expired:**

```
error: no configuration has been provided
```

The kubeconfig was either not set, incorrectly base64-encoded, or the cluster was destroyed and recreated (new kubeconfig). Re-encode and update the secret:

```bash
base64 < myapp_kubeconfig.yaml | pbcopy
```

Go to repo → **Settings → Secrets → KUBE_CONFIG** → update.

**Smoke test fails, Helm rolls back:**

The pipeline deploys successfully but the `curl https://yourdomain.com/health` smoke test fails, triggering an automatic rollback. Causes:
- DNS not pointing to the cluster (if you just rebuilt it)
- TLS certificate not ready yet (the smoke test uses HTTPS)
- App crashes on startup (check `bb k8s-logs` for the exception)
- Health endpoint returns non-200 (code bug)

**CD succeeds but site shows old version:**

The Helm deploy completed but the new pods aren't serving traffic. Check:

```bash
bb k8s-status        # Are new pods Running?
bb k8s-describe      # Is the rollout stuck?
kubectl rollout status deployment/myapp
```

### GitHub Actions Can't Push to GHCR

**`denied: permission_denied`** in CI:

1. Workflow permissions must be Read and Write: repo → **Settings → Actions → General → Workflow permissions**
2. GHCR package must be linked to repo: `github.com/YOUR_USER?tab=packages` → `myapp` → **Package settings → Manage Actions access → Add Repository**

---

## Monitoring Stack Issues

### `bb monitoring-install` Fails

**`ServiceAccount "minio-sa" already exists`:**

Install order matters. Loki must install first (it claims `minio-sa`). The standalone MinIO for Mimir uses `mimir-minio-sa`. If this error appears, the install order was wrong:

```bash
bb monitoring-uninstall
bb monitoring-install     # reinstalls in the correct order
```

**Pods in monitoring namespace stuck in `Pending`:**

Not enough cluster resources. The full LGTM stack (Mimir, Loki, Tempo, Alloy, Grafana, MinIO) needs ~4GB of memory. If your workers are small, some pods won't schedule. Either reduce monitoring resource requests in the values files, or use larger worker nodes.

### Grafana Can't Connect

**`bb grafana` shows nothing:**

```bash
bb monitoring-status       # Are all monitoring pods Running?
```

If pods are still starting, wait. The monitoring stack takes 3-5 minutes to fully initialise.

**Grafana loads but dashboards show "No data":**

1. Check that your app is deployed and has the right annotations:
   ```bash
   kubectl get pods -o yaml | grep "prometheus.io/scrape"
   # Should show: prometheus.io/scrape: "true"
   ```

2. Check that Alloy is scraping:
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=20
   ```

3. Check that Mimir has data: Explore → Mimir → type `up` → Run query. If empty, Alloy isn't sending data to Mimir.

### Loki Shows No Logs

Alloy collects logs from node filesystem. Check:

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy
# Must show one pod per node (it's a DaemonSet)
```

If Alloy pods aren't running, they may have been evicted due to resource pressure. Check `kubectl describe pod -n monitoring <alloy-pod>`.

---

## Local Development Issues

### REPL Won't Start

**`bb dev` hangs or fails:**
- Port 7888 already in use: another REPL instance is running. Kill it: `lsof -ti:7888 | xargs kill`
- Dependencies can't download: check internet connection, check `deps.edn` for typos

### Local K8s Deploy Fails

**`bb helm-local` fails with image errors:**

```bash
bb k8s-describe
# Look for: "ErrImageNeverPull" or "image not found"
```

`imagePullPolicy: Never` is set for local, which means K8s uses the locally built image. If you haven't run `bb docker-build` recently, the image doesn't exist:

```bash
bb docker-build       # build the image first
bb helm-local         # then deploy
```

**Rancher Desktop not running:** `bb helm-local` needs a running K8s cluster. Start Rancher Desktop and wait for the K8s indicator to show green.

**`docker build` doesn't work:**

Check that Rancher Desktop uses the **dockerd** backend, not containerd: Rancher Desktop → Preferences → Container Engine → dockerd.

### `myapp.localhost` Doesn't Resolve

This requires Traefik to be running in Rancher Desktop. Check:

```bash
kubectl get svc -A | grep traefik
```

If Traefik isn't running, fall back to port-forwarding:

```bash
bb k8s-port-forward
curl http://localhost:8080/health
```

---

## Useful Diagnostic Commands

### Cluster State

```bash
kubectl get nodes                              # node health
kubectl get pods -A                            # all pods, all namespaces
kubectl get events --sort-by=.lastTimestamp     # recent cluster events
kubectl top nodes                              # CPU/memory per node
kubectl top pods                               # CPU/memory per pod
```

### Application

```bash
bb k8s-status                                  # pod status (shortcut)
bb k8s-logs                                    # tail logs (shortcut)
bb k8s-describe                                # detailed pod info (shortcut)
bb k8s-shell                                   # shell into container
kubectl logs -l app.kubernetes.io/name=myapp --previous   # logs from the last crashed pod
kubectl rollout history deployment/myapp       # deployment history
kubectl rollout undo deployment/myapp          # manual rollback
```

### Networking

```bash
kubectl get svc -A                             # all services + external IPs
kubectl get ingress                            # ingress routing rules
kubectl describe ingress myapp                 # ingress details + events
curl -v https://yourdomain.com/health          # verbose HTTPS request (shows TLS negotiation)
dig yourdomain.com +short                      # DNS resolution
dig @8.8.8.8 yourdomain.com +short             # DNS via Google (bypass local cache)
```

### TLS

```bash
bb cert-status                                 # certificate status + expiry
kubectl get certificate                        # all certificates
kubectl describe certificate myapp-tls         # certificate details
kubectl describe order -A                      # ACME order status
kubectl describe challenge -A                  # HTTP-01 challenge status
kubectl get clusterissuer                      # ClusterIssuer exists?
```

### Monitoring

```bash
bb monitoring-status                           # monitoring pod status
bb grafana                                     # open Grafana (port-forward)
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=20    # Alloy logs
kubectl logs -n monitoring -l app.kubernetes.io/name=mimir --tail=20    # Mimir logs
```

### Helm

```bash
helm list                                      # installed releases (default namespace)
helm list -A                                   # all namespaces
helm history myapp                             # release history + revisions
helm rollback myapp <revision>                 # rollback to specific revision
helm get values myapp                          # currently applied values
helm template ./helm/myapp -f values-prod.yaml # render templates without deploying (dry run)
```

### Terraform

```bash
bb tf-plan                                     # preview changes
terraform state list                           # resources in state (run from terraform/)
hcloud server list                             # Hetzner servers
hcloud volume list                             # Hetzner volumes (check for orphans)
hcloud load-balancer list                      # Hetzner load balancers
```

---

## Symptom Quick-Reference

| You see | Likely cause | First command |
|---------|-------------|---------------|
| Pod `Pending` | Not enough resources or no ready nodes | `kubectl describe pod <n>` |
| Pod `CrashLoopBackOff` | App crash or probe too aggressive | `bb k8s-logs` |
| Pod `ImagePullBackOff` | Private image, wrong arch, or tag not found | `bb k8s-describe` (Events) |
| Pod `Terminating` forever | Node unreachable | `kubectl delete pod <n> --force --grace-period=0` |
| `curl` returns `connection refused` | App not running or wrong port | `bb k8s-status` |
| `curl` returns `502 Bad Gateway` | Traefik can reach the Service but the pod isn't responding | `bb k8s-logs` |
| `curl` returns `404` | Ingress routing wrong | `kubectl describe ingress myapp` |
| Browser shows "Not Secure" | TLS certificate not ready | `bb cert-status` |
| `SSL certificate problem` | Certificate hasn't been issued yet | `kubectl describe challenge -A` |
| CI/CD deploy fails | Kubeconfig invalid or cluster doesn't exist | Check Actions logs, update `KUBE_CONFIG` secret |
| Grafana shows "No data" | Alloy not scraping, or app missing annotations | `kubectl get pods -o yaml \| grep prometheus.io/scrape` |
| `ServiceAccount already exists` | Monitoring install order wrong | `bb monitoring-uninstall && bb monitoring-install` |
| Hetzner volumes remain after destroy | PVCs not deleted before cluster destroy | `hcloud volume list && hcloud volume delete <id>` |
| `terraform.tfstate` lost | Can't manage cluster | Delete all from Hetzner Console, `rm terraform.tfstate`, `bb tf-apply` |

---

## Related Docs

| Topic | Document |
|-------|----------|
| Hetzner production deployment | [docs/hetzner-deployment.md](hetzner-deployment.md) |
| Local development setup | [GUIDE.md](../GUIDE.md) — Steps 1-3 |
| Monitoring deep-dive | [GUIDE.md](../GUIDE.md) — Step 9 |
| Multi-cloud deployment | [docs/multi-cloud.md](multi-cloud.md) |
