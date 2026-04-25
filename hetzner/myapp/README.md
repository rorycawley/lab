# myapp

A minimal Clojure web service built with Ring and Reitit.

It exposes:

- `/health` — basic health check
- `/hello` — sample JSON endpoint
- `/metrics` — Prometheus metrics

## Stack

- Clojure
- Ring + Jetty
- Reitit
- Iapetos / Prometheus metrics
- Docker
- Helm
- Terraform (Hetzner)

## Run locally

Start a REPL:

```bash
bb repl
```

Build the app:

```bash
bb build
```

Run tests:

```bash
bb test
```

Build and run with Docker:

```bash
bb docker-build
bb docker-run
```

Then open:

- http://localhost:8080/health
- http://localhost:8080/hello
- http://localhost:8080/metrics

## Run on local Kubernetes

```bash
bb helm-local
```

This deploys the app with the local Helm values and runs a smoke test.

## Deploy to Hetzner

Provision infrastructure:

```bash
bb tf-apply
```

Deploy the app:

```bash
export PROD_HOST=your-domain.com
bb helm-prod
```

## Notes

- OpenTelemetry Java agent loading is controlled by `OTEL_JAVAAGENT_ENABLED`
- Production values live under `helm/myapp/`
- Terraform files live under `terraform/`
