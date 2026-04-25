# Observability: Monitoring, Logging, Tracing, and Alerting

> **Context:** This document is a companion to the main [GUIDE.md](../GUIDE.md). The core deployment path works without observability — your app runs, serves traffic, and TLS renews itself. This document covers the optional but strongly recommended next layer: seeing what your app is doing in production, detecting problems before users notice, and getting notified when something needs attention.
>
> **When to set this up:** After your app is running in production (Steps 1-7 in the main guide or [docs/hetzner-deployment.md](hetzner-deployment.md)). Observability is not a prerequisite — it's a force multiplier.

---

## Why Observability Matters

Without monitoring, debugging looks like this: a user reports something is slow. You SSH into the server, tail logs, guess what's wrong, deploy a fix, and hope. Three days later, a different user reports the same problem.

With monitoring, you open Grafana and see: request latency spiked at 3:47am, the JVM heap was at 95%, garbage collection was running every 2 seconds, and it correlates with a spike in database query time. You fix the actual problem. You also set up an alert so the next time it happens, Slack tells you before any user notices.

The difference is the gap between reacting and preventing.

---

## The Three Pillars

Each pillar answers a different question. You need all three for a complete picture.

| Pillar | Answers | Example | Format in this project |
|--------|---------|---------|----------------------|
| **Metrics** | How much? How fast? | Request rate, error rate, p99 latency, heap usage | Prometheus (via iapetos) |
| **Logs** | What happened? | Stack traces, request details, error messages | Stdout → Loki (via Alloy) |
| **Traces** | Where did the time go? | Per-request waterfall: 80ms in handler, 1.5s in DB | OTLP (via OTel Java agent) |

**Metrics** are cheap to store (just numbers), great for dashboards and alerts, and perfect for trends. "Is latency getting worse over time?"

**Logs** give you the details when you already know something went wrong. "What was the stack trace? What request caused it?"

**Traces** show a single request's journey. Even with one service, a trace reveals: "this request spent 200ms in Jetty, 50ms in the handler, 1.5s waiting for a database query, and 100ms serializing." With multiple services, traces follow the request across all of them.

---

## OpenTelemetry: Instrument Once, Export Anywhere

### The Problem OTel Solves

Before OpenTelemetry, every monitoring vendor had its own instrumentation SDK. Using Datadog meant adding the Datadog library. Switching to New Relic meant ripping out Datadog and adding New Relic. Your application code was coupled to your monitoring vendor.

OpenTelemetry (OTel) is a CNCF project that provides a single, vendor-neutral standard for generating telemetry. Every major vendor supports it. You instrument once, and you can send data to any backend — Grafana/Tempo, Datadog, New Relic, Jaeger, Honeycomb — by changing one environment variable.

### What OTel Defines

1. **An API** — interfaces for creating spans, recording metrics, emitting logs
2. **An SDK** — the implementation that processes and exports telemetry
3. **OTLP** — the wire protocol for sending telemetry between systems

### How We Use It

This project uses the **OTel Java agent** — a JAR that attaches to the JVM at startup and automatically instruments common libraries via bytecode manipulation. You write zero tracing code.

**In the Dockerfile:**

```dockerfile
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.11.0/opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar

ENTRYPOINT ["java", "-javaagent:/app/opentelemetry-javaagent.jar", "-jar", "/app/myapp.jar"]
```

**In the Helm deployment template** (environment variables control everything):

```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: myapp                                    # identifies this service
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://alloy.monitoring.svc:4318         # Alloy's OTLP/HTTP port
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: http/protobuf                            # OTLP over HTTP
  - name: OTEL_METRICS_EXPORTER
    value: none                                     # iapetos handles metrics
  - name: OTEL_LOGS_EXPORTER
    value: none                                     # stdout handles logs
  - name: OTEL_JAVAAGENT_ENABLED
    value: "false"                                  # disabled by default
```

### Why Only Traces Use OTel

OTel can export all three pillars, but we only use it for traces:

| Pillar | OTel? | What we use instead | Why |
|--------|-------|-------------------|-----|
| Metrics | No | iapetos (Prometheus client) | Integrates naturally with Clojure, scraped via pull model |
| Logs | No | `println` to stdout | K8s captures stdout automatically, Alloy ships to Loki |
| Traces | Yes | OTel Java agent | No code needed, automatic instrumentation of Jetty/JDBC/HTTP |

Using OTel for all three would work, but would mean replacing iapetos and configuring OTel log bridging — more complexity with no practical benefit.

### Why It's Disabled by Default

The OTel agent adds 10-15 seconds to JVM startup (classpath scanning + bytecode instrumentation) and immediately tries to connect to Alloy. If Alloy isn't running yet, the agent logs connection errors every few seconds. Not fatal, but noisy. Enable after installing the monitoring stack.

### What the Agent Instruments Automatically

Without writing any code, the agent creates trace spans for:

- Every incoming HTTP request (Jetty)
- Every outgoing HTTP request (HttpURLConnection, Apache HttpClient, OkHttp)
- Every JDBC database query (with query text, duration, database name)
- Every Redis, gRPC, Kafka, or RabbitMQ operation (if added later)

Each span includes start time, duration, status code, HTTP method and path, and a trace ID linking all spans in one request. Grafana links Loki and Tempo through these trace IDs — click a trace ID in a log line to jump to the corresponding trace.

### What a Trace Looks Like

In Grafana (Explore → Tempo), traces appear as waterfall diagrams:

```
myapp: GET /hello                          [==========] 250ms
  └── HTTP GET /api/users (external call)  [====]       80ms
  └── JDBC SELECT * FROM users             [==]         45ms
  └── HTTP response serialization          [=]          12ms
```

This tells you exactly where 250ms was spent. Without tracing, you'd just see "the request took 250ms" and guess.

---

## The LGTM Stack

LGTM stands for Loki, Grafana, Tempo, Mimir — the four core components of Grafana's open-source observability stack. We also run Alloy (the collection agent) and MinIO (object storage).

### Components

| Component | Role | What it replaces | Storage |
|-----------|------|-----------------|---------|
| **Grafana** | Dashboards, queries, alerts | — (it's the UI) | PVC (dashboard state) |
| **Mimir** | Metrics storage | Prometheus (but scalable) | MinIO (standalone) |
| **Loki** | Log storage | Elasticsearch/ELK (but cheaper) | MinIO (built-in) |
| **Tempo** | Trace storage | Jaeger, Zipkin | Local filesystem |
| **Alloy** | Collection agent | Prometheus + Promtail + OTel Collector | None (stateless DaemonSet) |
| **MinIO** | S3-compatible object storage | AWS S3, GCS | PVCs |

**Grafana** doesn't store telemetry — it queries Mimir (PromQL), Loki (LogQL), and Tempo (TraceQL) on demand.

**Mimir** is API-compatible with Prometheus. Any Prometheus dashboard, alert rule, or query works with Mimir. The difference: Mimir stores metrics in object storage and scales horizontally.

**Loki** only indexes metadata (labels like namespace, pod name), not the full text of every log line. This makes it much cheaper than Elasticsearch. You search by label first, then grep the results.

**Tempo** stores trace spans. It's optimised for write-heavy, read-light workloads — tracing generates a lot of data but you only look at individual traces when debugging.

**Alloy** is a single binary that replaces three separate tools. It runs as a DaemonSet (one pod per node) and does all collection:
- Scrapes `/metrics` from pods with `prometheus.io/scrape: "true"` annotations → Mimir
- Reads stdout/stderr log files from every container on its node → Loki
- Receives OTLP trace data from the OTel agent on port 4318 → Tempo

### How Data Flows

```
myapp pod
  ├── /metrics (iapetos)   ──→ Alloy scrapes every 15s  ──→ Mimir  ──→ ┐
  ├── stdout/stderr         ──→ Alloy reads log files    ──→ Loki   ──→ ├─→ Grafana
  └── OTel agent (traces)  ──→ Alloy receives OTLP/HTTP ──→ Tempo  ──→ ┘
```

Metrics are *pulled* — Alloy finds your pods via annotations and scrapes them. Your app doesn't need to know where Mimir is.

Logs are *collected* — K8s writes stdout to files on the node. Alloy tails these files and ships to Loki with labels.

Traces are *pushed* — the OTel agent sends spans via OTLP/HTTP (port 4318) to Alloy, which forwards to Tempo.

---

## Installing the Stack

### Prerequisites

The cluster must be running. The LGTM stack installs into the `monitoring` namespace, separate from your app in `default`.

### Install

```bash
bb monitoring-install
# Takes ~5 minutes, installs 6 Helm releases
```

**What success looks like:**

```bash
bb monitoring-status
# All pods in monitoring namespace should be Running
```

**Verify Grafana:**

```bash
bb grafana
# Port-forwards to http://localhost:3000
# Login: admin / admin-change-me
```

### Install Order (and Why It Matters)

Both Loki's built-in MinIO and the standalone MinIO for Mimir use the same Helm chart, which creates a ServiceAccount called `minio-sa`. Two Helm releases can't own the same ServiceAccount. The install script handles this by installing Loki first (its MinIO gets `minio-sa`), then standalone MinIO with a custom name (`mimir-minio-sa`).

**If you see `ServiceAccount "minio-sa" already exists`:**

```bash
bb monitoring-uninstall
bb monitoring-install
```

### Chart Version Pinning

Loki is pinned to chart v6.33.0 and Tempo to v1.10.3. Newer versions have breaking configuration changes. The install script pins these automatically.

### Enable Tracing

After the stack is running, enable the OTel agent:

```bash
# Edit helm/myapp/values-prod.yaml → otel.enabled: "true"
bb helm-prod
```

**Verify traces are flowing:**

Open Grafana → Explore → Tempo → search by service name `myapp`. You should see traces appearing within a minute of sending requests to the app.

### Change Default Passwords

Before using this in a real production environment:

- `monitoring/values-minio.yaml` → `rootPassword`
- `monitoring/values-grafana.yaml` → `adminPassword`
- `monitoring/values-mimir.yaml` → must match the MinIO password

---

## How Your App Gets Instrumented

### Metrics — iapetos

Your app creates a Prometheus registry with iapetos (a Clojure wrapper around the Prometheus Java client). The `wrap-metrics` middleware records every HTTP request: count, endpoint, status code, duration. JVM collectors expose heap usage, GC stats, thread counts, and class loading.

The `/metrics` endpoint serves Prometheus text format:

```bash
curl http://localhost:8080/metrics
# http_requests_total{method="GET",path="/health",status="200"} 42
# jvm_memory_bytes_used{area="heap"} 67108864
```

The deployment template's `prometheus.io/scrape: "true"` annotation tells Alloy to scrape this endpoint every 15 seconds. No registration or configuration needed — Alloy discovers it automatically.

### Logs — stdout

Your app writes to stdout with `println`. That's it. Kubernetes captures stdout/stderr from every container. Alloy reads these log files and ships each line to Loki with labels (namespace, pod name, app name).

Structured logging (JSON) lets Loki parse and filter on individual fields:

```clojure
(println (json/write-str {:level "info" :msg "request" :path "/health" :status 200}))
```

But even plain `println` works — Loki stores every line and you can grep with `|=` filters.

### Traces — OTel Java Agent

Covered in detail in the OpenTelemetry section above. The short version: the agent creates trace spans automatically for every HTTP request, DB query, and outgoing call. You write zero code. Enable with `otel.enabled: "true"` in the values file after installing the monitoring stack.

---

## Using Grafana

### Quick Tour

After `bb grafana`, open `http://localhost:3000` (login: `admin` / `admin-change-me`).

**Explore → Loki** — log search:
```
{namespace="default"}                              # all logs from your namespace
{namespace="default", app="myapp"} |= "error"     # lines containing "error"
{app="myapp"} | json | level="error"               # JSON-parsed, level field = error
```
The query language is LogQL.

**Explore → Mimir** — metrics:
```promql
http_requests_total                                # raw request counts
rate(http_requests_total[5m])                      # requests per second (5m average)
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))  # p99 latency
```
The query language is PromQL.

**Explore → Tempo** — traces:
Search by service name (`myapp`), duration (`> 500ms`), or status code. Click a trace to see the waterfall view.

**Dashboards** — pre-installed community dashboards for JVM metrics (heap, GC, threads) and Kubernetes cluster overview (CPU, memory, pod counts per node).

---

## Alerting: From Dashboards to Notifications

Dashboards are for investigating. Alerting is for detecting. You can't stare at dashboards all day — alerting wakes you up when something needs attention.

### Grafana's Alerting Architecture

Grafana's alerting system has four components:

**Alert rules** — a query + threshold + evaluation interval. Example: "fire if error rate exceeds 5% for 5 consecutive minutes." Rules are evaluated automatically (every 1 minute by default).

**Contact points** — where notifications go. Supported channels include: email (SMTP), Slack (webhook), PagerDuty (integration key), Microsoft Teams (webhook), Discord, Opsgenie, Telegram, and generic webhooks.

**Notification policies** — routing logic. Connect rules to contact points by label. Critical alerts go to PagerDuty (pages the on-call). Warnings go to Slack (team checks when free). Policies also control grouping (batch related alerts) and repeat intervals (don't page every minute for the same problem).

**Silences** — suppress notifications during planned maintenance. Upgrading the database and expect a brief outage? Silence the relevant alerts.

### Setting Up Your First Alert

1. **Create a contact point:** Alerting → Contact points → New → choose Slack → paste webhook URL → Test
2. **Create an alert rule:** Alerting → Alert rules → New alert rule
3. **Write the query:** `rate(http_requests_total{status=~"5.."}[5m]) > 0.05`
4. **Set the condition:** "is above 0.05" (5% error rate)
5. **Set evaluation:** every 1 minute, for 5 minutes (avoids false positives from brief spikes)
6. **Select contact point:** choose the Slack contact point
7. **Save**

When the error rate exceeds 5% for 5 consecutive minutes, Grafana posts to your Slack channel with the alert name, current value, and a dashboard link. When it resolves, Grafana sends a "resolved" notification.

### Recommended Alerts

| Alert | PromQL query | Threshold | Channel |
|-------|-------------|-----------|---------|
| High error rate | `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])` | > 5% for 5m | Slack / PagerDuty |
| High latency (p99) | `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))` | > 2s for 5m | Slack |
| Pod restarts | `increase(kube_pod_container_status_restarts_total{namespace="default"}[1h])` | > 3 in 1h | Slack |
| TLS cert near expiry | `certmanager_certificate_expiration_timestamp_seconds - time()` | < 14 days | Email / PagerDuty |
| Node disk filling | `kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes` | < 10% for 10m | Slack |
| JVM heap pressure | `jvm_memory_bytes_used{area="heap"} / jvm_memory_bytes_max{area="heap"}` | > 90% for 5m | Slack |

### TLS Certificate Monitoring

Let's Encrypt discontinued expiry warning emails in June 2025. cert-manager renews automatically at day 60 of 90, but if renewal fails silently, the certificate expires and your site shows browser warnings.

cert-manager exports `certmanager_certificate_expiration_timestamp_seconds`. Alloy scrapes it automatically. The alert above (< 14 days to expiry) means renewal has been failing for at least 16 days — you still have 14 days to fix it.

Quick manual check:

```bash
bb cert-status
# Shows certificate name, READY status, expiry date, and scheduled renewal date
```

---

## Switching Monitoring Backends

Because this project uses OpenTelemetry (OTLP) for traces and Prometheus format for metrics — both open standards — switching backends is a configuration change, not a code rewrite.

### What Never Changes

| Component | Why it's portable |
|-----------|------------------|
| `src/myapp/core.clj` | Application code is backend-agnostic |
| `Dockerfile` | OTel agent JAR is the same everywhere |
| iapetos `/metrics` | Prometheus format is the universal standard |
| OTel Java agent | OTLP is the universal trace format |
| Helm chart templates | Only values files change |

### Switching to Datadog

Datadog accepts OTLP directly via the Datadog Agent.

**What to do:**
1. Install the Datadog Agent: `helm install datadog datadog/datadog --set datadog.apiKey=YOUR_KEY`
2. Change `otel.endpoint` in your values file to `http://datadog-agent.datadog.svc:4318`
3. Datadog Agent scrapes Prometheus `/metrics` automatically — iapetos metrics flow without changes
4. Datadog collects stdout logs via its K8s log collection
5. Run `bb monitoring-uninstall` — Datadog replaces everything

**What you get:** Managed dashboards, APM, log management, anomaly detection. No Mimir/Loki/Tempo/MinIO to maintain.

**What it costs:** $30-100+/host/month depending on features. Per-host + per-million-events pricing.

### Switching to Azure Monitor

For AKS deployments. Azure Monitor integrates natively.

**What to do:**
1. Enable Container Insights on the AKS cluster (Terraform flag: `oms_agent { enabled = true }`)
2. Azure Monitor collects logs and K8s metrics automatically
3. For traces, configure the OTel agent to send to Azure Monitor's OTLP endpoint or Application Insights
4. AKS supports Azure Monitor managed Prometheus for `/metrics` scraping
5. Run `bb monitoring-uninstall`

**What you get:** Log Analytics (KQL queries), Application Insights traces, Azure Alerts, Azure AD integration.

**What it costs:** Pay-per-GB for logs, pay-per-million for metrics. Costs vary by volume.

### Switching to AWS CloudWatch + X-Ray

For EKS deployments. Multiple AWS services replace the LGTM stack.

**What to do:**
1. Install AWS Distro for OpenTelemetry (ADOT) collector
2. ADOT receives OTLP traces → sends to X-Ray
3. ADOT scrapes Prometheus `/metrics` → sends to Amazon Managed Prometheus or CloudWatch Metrics
4. Install Fluent Bit for logs → ships stdout to CloudWatch Logs
5. Use Amazon Managed Grafana (same Grafana UI, managed by AWS) or CloudWatch dashboards
6. Run `bb monitoring-uninstall`

**What you get:** Fully managed, deep AWS integration (IAM, CloudWatch Alarms, SNS), X-Ray service map.

**What it costs:** CloudWatch Logs ~$0.50/GB ingested, X-Ray ~$5/million traces, Managed Prometheus ~$0.90/10K samples.

---

## Troubleshooting

### Monitoring Stack Won't Install

**`ServiceAccount "minio-sa" already exists`** — run `bb monitoring-uninstall` then `bb monitoring-install`. Install order matters (Loki first, then standalone MinIO).

**Pods stuck in `Pending`** — not enough cluster resources. The monitoring stack needs ~2GB RAM across all components. Check `kubectl describe pod -n monitoring <pod>` for scheduling failures.

### No Metrics in Grafana

**Check Alloy is running:** `kubectl get pods -n monitoring | grep alloy`

**Check scraping works:** `kubectl port-forward svc/myapp 8080:8080` then `curl localhost:8080/metrics`. If `/metrics` returns data, the app side is fine — check Alloy logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=alloy`

**Check Mimir is receiving:** In Grafana, Explore → Mimir, type `up`. You should see entries. If empty, Alloy can't reach Mimir.

### No Logs in Grafana

**Check Loki is running:** `kubectl get pods -n monitoring | grep loki`

**Try a broad query:** `{namespace="default"}` — if this returns nothing, Alloy isn't shipping logs to Loki.

### No Traces in Grafana

**Is OTel enabled?** Check `otel.enabled` in your values file. It's `"false"` by default.

**Is Alloy receiving?** The OTel agent sends to `alloy.monitoring.svc:4318`. If Alloy isn't in the `monitoring` namespace, the endpoint won't resolve.

**Check agent logs:** `bb k8s-logs` and look for OTel agent output. Connection errors to Alloy mean the endpoint is wrong or Alloy isn't running.

### OTel Agent Slows Startup

The agent adds 10-15 seconds to JVM startup. If health probes fire before the app is ready, K8s kills the pod (CrashLoopBackOff). `initialDelaySeconds` is set to 45 to handle this. If you've added heavy startup logic, increase it.

---

## Quick Reference

### Commands

| Task | Command |
|------|---------|
| Install monitoring stack | `bb monitoring-install` |
| Check monitoring pods | `bb monitoring-status` |
| Open Grafana | `bb grafana` (→ localhost:3000, admin/admin-change-me) |
| Uninstall monitoring | `bb monitoring-uninstall` |
| Check TLS cert status | `bb cert-status` |
| Enable tracing | Edit `values-prod.yaml` → `otel.enabled: "true"`, then `bb helm-prod` |

### Useful PromQL Queries

```promql
# Request rate (requests/second)
rate(http_requests_total[5m])

# Error rate (% of 5xx responses)
rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])

# p99 latency
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))

# JVM heap usage (%)
jvm_memory_bytes_used{area="heap"} / jvm_memory_bytes_max{area="heap"}

# TLS cert time remaining
certmanager_certificate_expiration_timestamp_seconds - time()
```

### Useful LogQL Queries

```
# All app logs
{namespace="default", app="myapp"}

# Error lines only
{app="myapp"} |= "error"

# JSON-parsed, filter by level
{app="myapp"} | json | level="error"

# Rate of log lines per second
rate({app="myapp"}[5m])
```

---

## Related Docs

| Topic | Document |
|-------|----------|
| Production deployment (where to install monitoring) | [docs/hetzner-deployment.md](hetzner-deployment.md) |
| DevOps principles (why monitoring matters) | [docs/devops-and-gitops.md](devops-and-gitops.md) |
| Switching cloud providers (monitoring portability) | [docs/multi-cloud.md](multi-cloud.md) |
| Customer on-prem (using their monitoring) | [docs/on-prem-customer-deployment.md](on-prem-customer-deployment.md) |
| Local development (REPL, no monitoring needed) | [GUIDE.md](../GUIDE.md) — Steps 1-3 |
