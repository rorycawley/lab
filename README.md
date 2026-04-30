# lab

Hands-on learning projects. Each folder is a small, self-contained demo, mostly a Python app on Rancher Desktop Kubernetes talking to infra in Docker Compose.

| Folder | What it shows |
| --- | --- |
| [event-sourcing](event-sourcing) | Event sourcing + CQRS with two Postgres databases, Flyway, and a projector. |
| [grafana-lgtm](grafana-lgtm) | Grafana LGTM stack on Rancher Desktop: FastAPI services plus a browser SPA sending backend logs/traces/metrics, frontend events, Web Vitals, API latency, and UI errors into Loki, Mimir, Tempo, and Grafana dashboards. |
| [hetzner](hetzner) | Clojure app with Helm charts and monitoring for Hetzner deployment. |
| [keycloak-oidc](keycloak-oidc) | OIDC Backend-for-Frontend: Python BFF holds tokens server-side, browser gets only an HttpOnly session cookie. |
| [keycloak-pg](keycloak-pg) | App authenticates to Postgres using a Keycloak-issued JWT via a PG-wire auth proxy. |
| [openbao](openbao) | App reads static and dynamic Postgres credentials from OpenBao using AppRole. |
| [rabbitmq](rabbitmq) | Transactional outbox: publisher and subscriber exchange events through RabbitMQ. |
| [redis](redis) | Redis cache-aside in front of a slow origin, with TTL-based eviction. |
| [registry-flyway-no-pgbouncer-poc](registry-flyway-no-pgbouncer-poc) | CQRS topology with two Postgres clusters and Flyway Jobs, no PgBouncer. |
