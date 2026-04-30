# Grafana LGTM Demo on Rancher Desktop

This project is a local learning lab for running the Grafana LGTM stack on Kubernetes and sending telemetry from both a backend and a browser UI.

It deploys:

- `otel-demo-app`: a FastAPI service that also serves a basic JavaScript SPA
- `payment-service`: a downstream FastAPI service called by `/checkout`
- Grafana for dashboards, Explore, and alerts
- Loki for logs
- Mimir for Prometheus-compatible metrics
- Tempo for traces
- Alloy for collection and forwarding
- `alarik`: a MinIO-backed S3-compatible store for Loki, Mimir, and Tempo data
- MailHog for local alert email delivery

The main point of the demo is to see telemetry flow end to end:

```text
Browser SPA -> otel-demo-app -> payment-service
     |              |                |
     |              |                +-> OTLP traces/logs -> Alloy
     |              +-> OTLP traces/logs -> Alloy
     +-> /frontend-telemetry -> app logs, metrics, traces

Alloy -> Loki  -> Grafana
Alloy -> Mimir -> Grafana
Alloy -> Tempo -> Grafana
```

## What This Covers

- Deploying a local LGTM stack with Helm.
- Sending backend logs and traces with OpenTelemetry.
- Scraping Prometheus metrics from app pods and kubelet cAdvisor.
- Capturing browser telemetry from a basic JavaScript SPA.
- Sending Web Vitals, browser API latency, UI errors, and page-load events.
- Propagating W3C `traceparent` headers from browser `fetch` calls.
- Viewing frontend logs, metrics, and traces in Grafana.
- Correlating app logs and traces through trace IDs.
- Persisting Loki, Mimir, and Tempo data in S3-compatible object storage.

## Prerequisites

- Rancher Desktop with Kubernetes enabled
- `kubectl`
- `helm`
- `docker`
- `make`

Before running the stack, make sure Helm can reach the chart repositories:

```sh
helm repo update grafana minio
```

If that fails with `lookup ... no such host`, fix local DNS, VPN, or network access first. `make up` cannot install the stack until Helm can fetch chart indexes.

## Quick Start

```sh
make up
```

This runs:

```text
make k8s-base
make lgtm
make build
make deploy
make verify
```

The first run can take several minutes. Rancher Desktop may be slow while Mimir, Loki, Tempo, Grafana, and MinIO all start on one local node.

## Access

Open the app:

```text
http://app.grafana-lgtm.localhost/
```

Open Grafana:

```text
http://grafana.grafana-lgtm.localhost/
```

Grafana credentials:

```text
admin / admin
```

Open MailHog:

```text
http://mailhog.grafana-lgtm.localhost/
```

If the `*.localhost` hostnames do not work, check the ingress address:

```sh
kubectl get ingress -n grafana-lgtm-demo
```

## Generate UI Telemetry

Open:

```text
http://app.grafana-lgtm.localhost/
```

Click:

- `Run Work`
- `Checkout`
- `Trigger Error`
- `JS Error`

The browser sends telemetry to:

```text
POST /frontend-telemetry
```

The UI emits:

- `FRONTEND_EVENT` logs
- page-load events
- Web Vitals: `FCP`, `LCP`, `CLS`, `INP`, `TTFB`
- browser-observed API latency
- JavaScript errors
- frontend telemetry spans
- `traceparent` headers on API calls

## Dashboards

In Grafana, open:

```text
Dashboards -> Demo -> Frontend Observability
```

This dashboard shows:

- frontend logs from Loki
- frontend event rate from Mimir
- browser API latency from Mimir
- Web Vitals from Mimir
- frontend telemetry traces from Tempo

The original backend dashboard is also provisioned:

```text
Dashboards -> Demo -> Python App Observability
```

## Explore Traces

In Grafana:

```text
Explore -> Tempo
```

Useful searches:

```text
service.name=otel-demo-app
service.name=payment-service
```

For `/checkout`, the expected trace path is:

```text
browser fetch
  -> GET /checkout on otel-demo-app
  -> demo.checkout
  -> HTTP POST /authorize
  -> payment.authorize
  -> payment.fraud_check
  -> payment.charge_card
```

From Loki logs, `trace_id=...` should link back into Tempo.

## Verify

Run:

```sh
make verify
```

The verification script:

- sends smoke traffic to `/work`, `/checkout`, and `/error`
- posts browser-style telemetry to `/frontend-telemetry`
- queries Loki for backend `WORK_*` logs
- queries Loki for frontend `FRONTEND_EVENT` logs
- queries Tempo for app, payment-service, and frontend traces
- checks that Loki objects exist in the `alarik` S3-compatible bucket
- queries Mimir for backend metrics, frontend metrics, and pod CPU/memory metrics

The payment service intentionally has a small random decline rate. The verifier retries checkout calls so a normal `402 Payment Required` decline does not fail the whole run.

## Common Commands

```sh
make up
```

Deploy everything and run verification.

```sh
make build
make deploy
```

Rebuild and redeploy the app images after local code changes.

```sh
make verify
```

Generate telemetry and check Loki, Tempo, Mimir, and object storage.

```sh
make status
```

Show namespace resource status.

```sh
make clean
```

Delete the namespace and local demo runtime state.

## Troubleshooting

### Helm repo update fails

Symptom:

```text
failed to update the following repositories
lookup grafana.github.io: no such host
lookup charts.min.io: no such host
```

Fix:

```sh
helm repo update grafana minio
```

If that fails, the issue is local DNS/network/VPN. The deployment cannot continue until Helm can reach the chart repositories.

### `make deploy` times out but pods look healthy

Rancher Desktop can drop Kubernetes watch connections under load. If a rollout command times out, check the actual deployment state:

```sh
kubectl get deployment -n grafana-lgtm-demo
kubectl get pods -n grafana-lgtm-demo
```

If `otel-demo-app`, `payment-service`, and Grafana show `1/1`, the rollout likely completed and only the local watch failed.

### `make verify` fails with a checkout `502`

The payment service can intentionally decline a payment with `402 Payment Required`. The app turns that into a `502` for `/checkout`.

The verifier retries checkout calls, but if the cluster is under pressure, rerun:

```sh
make verify
```

### Pods restart during verification

The full LGTM stack is heavy for a single Rancher Desktop node. If probes or helper pods time out:

```sh
kubectl get pods -n grafana-lgtm-demo
kubectl describe pod -n grafana-lgtm-demo <pod-name>
```

Increasing Rancher Desktop CPU and memory usually helps. The app and payment-service probes use longer timeouts than the Kubernetes default to reduce false restarts during local load.

### Frontend logs appear but graphs say `No data`

Metrics are scraped on an interval, so logs can appear before Mimir panels update. Click the UI buttons again, wait 30-60 seconds, and refresh the dashboard.

Also make sure the dashboard time range includes the latest telemetry, for example `Last 15 minutes`.

## Lessons Learned

- Frontend observability does not require a large framework. A basic JS SPA can emit useful telemetry with `fetch`, `PerformanceObserver`, and a small backend receiver.
- Logs, metrics, and traces become much more useful when the browser sends `traceparent` headers and the backend preserves that trace context.
- Loki can show frontend events almost immediately, while Tempo search and Mimir panels may lag because traces and metrics are indexed or scraped asynchronously.
- Verification should avoid relying on random success paths. The payment service intentionally declines some requests, so smoke tests need retries.
- `kubectl run --rm -i` helper pods are convenient for in-cluster checks, but they need generous startup timeouts on a loaded local cluster.
- Rancher Desktop is good for learning, but a full Loki, Mimir, Tempo, Grafana, Alloy, and MinIO stack can stress a single local node.
- Helm repo updates can fail because of unrelated repos in your local Helm config. This deployment only needs the `grafana` and `minio` repos.
- A passing dashboard is not enough: the verifier checks Loki, Tempo, Mimir, S3-compatible persistence, and pod resource metrics to prove the whole telemetry path works.

## Project Layout

```text
app/
  FastAPI entry-point service and static browser SPA

payment-service/
  FastAPI downstream service used by checkout traces

k8s/
  Namespace, app, payment-service, and MailHog manifests

monitoring/
  Helm values for Grafana, Loki, Mimir, Tempo, Alloy, and alarik

scripts/
  Deployment, verification, status, and cleanup scripts

Makefile
  Main entry points for running the demo
```

## Cleanup

```sh
make clean
```

This removes the `grafana-lgtm-demo` namespace, local demo images, local logs, and temporary port-forward logs.

If Kubernetes reports that the namespace is still terminating, wait and re-check:

```sh
kubectl get namespace grafana-lgtm-demo
```
