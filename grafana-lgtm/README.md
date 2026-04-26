# Grafana LGTM on Rancher Desktop Kubernetes

A small learning project that deploys Grafana LGTM into local Rancher Desktop
Kubernetes, then sends OpenTelemetry logs, traces, and metrics from a single-file
Python web app.

## What It Shows

- Grafana LGTM `0.24.1` running in Kubernetes as an all-in-one local
  observability stack.
- A FastAPI app instrumented with OpenTelemetry.
- OTLP over HTTP from the app to the collector endpoint at `grafana-lgtm:4318`.
- Structured application logs correlated with trace and span IDs.
- Kubernetes metadata enrichment on OTel resources, including namespace, pod,
  node, pod IP, deployment, and container.
- A provisioned Grafana dashboard for app logs, traces, request rate, error
  rate, and average request latency.
- Provisioned Grafana alert rules for demo error rate and average latency.
- Scripts and Make targets for repeatable setup, traffic generation, inspection,
  and full cleanup.
- Automated backend checks that query Loki, Tempo, Mimir, and Grafana Alerting.

## Architecture

```text
HTTP client
  |
  v
FastAPI app in Kubernetes
  |
  | OTLP HTTP traces, logs, metrics
  v
grafana/otel-lgtm in Kubernetes
  |
  +-- Grafana :3000
  +-- Loki    logs
  +-- Tempo   traces
  +-- Mimir   metrics
```

Both workloads run in the `grafana-lgtm-demo` namespace.

## Requirements

- Rancher Desktop with Kubernetes enabled
- Docker-compatible CLI
- `kubectl`
- `make`
- `curl`
- `jq`

## Quick Start

Run the full demo and clean everything afterward:

```sh
make full-check
```

This runs:

```text
make up
make test-all
make status
make clean
```

`make clean` runs even if a check fails.

## Manual Flow

Deploy Grafana LGTM and the app:

```sh
make up
```

Generate test traffic, a longer burst of dashboard data, backend telemetry
verification, and alert-rule verification with temporary port-forwards:

```sh
make test-all
```

Open Grafana. This command blocks and should stay running in its own terminal:

```sh
make port-forward-grafana
```

Then browse directly to the provisioned dashboard:

```text
http://localhost:3000/d/python-app-otel/python-app-otel-logs-and-traces
```

Grafana credentials are:

```text
admin / admin
```

If Grafana does not redirect straight to it, open the dashboard named
`Python App OTel Logs and Traces` from the `Demo` folder.

The dashboard contains:

- application logs from Loki
- recent traces from Tempo
- request rate from the Prometheus-compatible metrics datasource
- error rate from `demo_errors_total`
- average request latency from `demo_request_duration_ms`

Provisioned alert rules are visible in Grafana under:

```text
Alerting -> Alert rules -> Demo
```

The demo provisions:

- `OTel demo error rate` - fires when demo errors are observed.
- `OTel demo average latency` - fires when average synthetic latency exceeds
  100 ms.

## Useful Targets

- `make up` - deploy the namespace, LGTM stack, app image, and app
- `make test` - call the app endpoints and emit logs/traces; needs app port-forward
- `make test-with-port-forward` - run the smoke test with temporary local forwards
- `make traffic-with-port-forward` - generate repeated traffic with temporary local forwards
- `make telemetry-with-port-forward` - query Loki, Tempo, and Mimir with temporary local forwards
- `make alerts-with-port-forward` - verify provisioned Grafana alert rules with temporary local forwards
- `make test-all` - run the smoke test, traffic generator, backend telemetry verification, and alert verification with temporary local forwards
- `make generate-traffic` - repeatedly call app endpoints; needs app port-forward
- `make verify-telemetry` - query Loki, Tempo, and Mimir through Grafana; needs Grafana port-forward
- `make verify-alerts` - query Grafana Alerting provisioning APIs; needs Grafana port-forward
- `make port-forward-grafana` - expose Grafana at `http://localhost:3000`
- `make port-forward-app` - expose the app at `http://localhost:8080`
- `make status` - show Kubernetes, image, log, and port state
- `make full-check` - run everything and always clean up
- `make clean` - remove all demo runtime state

## App Endpoints

- `GET /healthz` - Kubernetes probe endpoint
- `GET /` - small app index
- `GET /work` - emits a successful traced request with nested spans
- `GET /checkout?item=coffee&quantity=2` - emits business-style logs and spans
- `GET /error` - emits an error log and span exception, then returns HTTP 500

Each response includes `trace_id` and `span_id` fields so you can search for the
same request in Grafana.

## Telemetry Verification

`make test-all` writes:

- `logs/test-results.json` - trace IDs returned by the app
- `logs/app.log` - Kubernetes app logs with trace/span IDs
- `logs/telemetry-verification.json` - proof that Grafana can query the emitted
  logs, traces, and metrics from Loki, Tempo, and Mimir
- `logs/alert-verification.json` - proof that Grafana loaded the provisioned
  alert rules and the evaluator can list them

## Cleanup Guarantee

`make clean` removes and verifies removal of:

- Kubernetes namespace `grafana-lgtm-demo`
- local image `otel-demo-app:demo`
- `logs/`
- `/tmp/grafana-lgtm-app-port-forward.log`
- `/tmp/grafana-lgtm-grafana-port-forward.log`

After `make clean`, a new run starts from an empty Kubernetes runtime state.
