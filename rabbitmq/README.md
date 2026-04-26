# RabbitMQ + Postgres Outbox Demo

A small learning project that shows two Python services in Rancher Desktop
Kubernetes - a **publisher** and a **subscriber** - exchanging integration
events through RabbitMQ using the **transactional outbox** pattern. The
publisher writes the domain event and the outbox row in **the same Postgres
transaction**; a relay drains the outbox to RabbitMQ with publisher
confirms; the subscriber consumes, deduplicates by `event_id`, and records
the event in its own table.

This is the messaging half of the DDD / event-sourced shape established in
`../event-sourcing`. The same `task-created` event lives here, but instead
of a CQRS projector polling the event store, an outbox relay publishes it
to a topic exchange so a different bounded context can react.

## What It Shows

- **Atomic outbox**: a single Postgres transaction inserts both the domain
  event and the command-idempotency row. There is no "wrote to DB but
  failed to publish" gap because publishing is a separate, retryable step.
- **Single-table outbox**: `domain_events.published_at IS NULL` *is* the
  outbox - no separate table, no dual-write.
- **Publisher confirms + mandatory flag**: the relay only stamps
  `published_at` after RabbitMQ has acked the publish. An unroutable
  message rolls the transaction back so the row stays pending and is
  retried on the next tick.
- **`SELECT ... FOR UPDATE SKIP LOCKED`**: safe under multiple relay
  replicas - each replica claims a disjoint batch.
- **Command-side idempotency**: a repeated `Idempotency-Key` returns the
  cached response and produces no new event.
- **Consumer-side idempotency**: the subscriber's `processed_events` table
  has `event_id` as primary key with `INSERT ... ON CONFLICT DO NOTHING`,
  so re-delivery (at-least-once is the contract here) is a no-op.
- **Topic routing**: the publisher emits `task.created`; the subscriber
  binds `task.*` so it would also pick up `task.completed`, `task.deleted`,
  etc. without a code change.

## Architecture

```text
HTTP client
  |
  v
Publisher pod  (FastAPI + outbox relay thread)
  |                                                  Subscriber pod
  | 1. POST /tasks                                   (FastAPI + pika consumer)
  |     INSERT domain_events                              ^
  |     INSERT command_idempotency  (same tx)             |
  |                                                       |
  | 2. relay tick:                                        |
  |     SELECT ... WHERE published_at IS NULL             |
  |       FOR UPDATE SKIP LOCKED                          |
  |     basic_publish (confirm + mandatory)  ----->  integration.events
  |     UPDATE published_at = now()                       |  (topic, durable)
  |                                                       |  routing key: task.created
  |                                                       v
  |                                                  task.subscriber  (durable queue, binds task.*)
  |                                                       |
  |                                                       | basic_consume, manual ack
  |                                                       v
  |                                                  INSERT processed_events
  |                                                    ON CONFLICT DO NOTHING
  v                                                       v
Postgres (Docker Compose)                            Postgres (same DB)
  domain_events                                        processed_events
  command_idempotency

RabbitMQ (Docker Compose)
  exchange: integration.events (topic, durable)
  queue:    task.subscriber    (durable, binds task.*)
```

Both pods reach Postgres and RabbitMQ via
`host.rancher-desktop.internal`, exposed inside the cluster as
ExternalName Services `external-postgres` and `external-rabbitmq`.

## Requirements

- Rancher Desktop with Kubernetes enabled
- Docker-compatible CLI
- `kubectl`
- `make`
- `curl`
- `jq`
- `uuidgen`

## Quick Start

Run the full demo and clean everything afterward:

```sh
make full-check
```

This runs:

```text
make up
make test-all
make clean
```

`make clean` runs even if a check fails.

## Manual Flow

Start the services, build the images, deploy:

```sh
make up
```

`up` runs, in order: start Docker Compose services (Postgres + RabbitMQ),
build the publisher and subscriber images, apply the Kubernetes namespace
and ExternalName Services, deploy the two apps, and verify they are
Ready.

Run the smoke test with a temporary port-forward:

```sh
make test-all
```

Inspect what is currently running:

```sh
make status
```

Remove all runtime state:

```sh
make clean
```

## Useful Targets

- `make up` - start services, build images, deploy publisher + subscriber
- `make test` - run the smoke test; needs port-forwards already running
- `make test-all` - run the smoke test with a temporary port-forward
- `make port-forward` - forward `8080 -> publisher`, `8081 -> subscriber`
- `make status` - show Kubernetes, Docker, image, log, and port state
- `make full-check` - run everything and always clean up
- `make clean` - remove all demo runtime state
- `make check-local` - syntax-check Python and dry-run k8s manifests

## Database Schema

Created by `postgres-init/01-schema.sql` on first container start:

- **`domain_events`** - append-only event store. `published_at` doubles
  as the outbox flag: `IS NULL` means the relay still has work to do.
- **`command_idempotency`** - `idempotency_key -> event_id, response`.
  Same key returns the cached response.
- **`processed_events`** - the subscriber's dedup table. `event_id` is
  the primary key.

## Publisher API

- `GET /` - lists endpoints and configured upstreams
- `GET /healthz` - process liveness
- `GET /readyz` - DB ping + RabbitMQ ping
- `POST /tasks` (header `Idempotency-Key`, body `{"title": "..."}`) -
  creates a task, writes the event + idempotency row in one tx
- `GET /events` - last N rows of `domain_events`
- `GET /outbox/pending` - rows where `published_at IS NULL`
- `POST /admin/republish/{event_id}` - re-emits an already-published
  event. Used by the smoke test to prove consumer-side dedup.

## Subscriber API

- `GET /healthz` - process liveness
- `GET /readyz` - DB ping + asserts the consumer has bound its queue
- `GET /processed?limit=N` - rows from `processed_events`
- `GET /processed/{event_id}/count` - 0 or 1
- `GET /stats` - `processed_in_db`, plus session counters
  `processed_total_session` and `dedup_hits_session`

## What `make test-all` Proves

`scripts/07-test.sh` runs five steps against a temporary port-forward to
both pods:

1. **`POST /tasks`** with a fresh `Idempotency-Key` returns a `task_id`
   and `event_id`.
2. **The relay drains the outbox.** `GET /outbox/pending` reaches `count: 0`.
3. **The subscriber records the event.** `GET /processed/{event_id}/count`
   reaches `1`.
4. **Idempotent command.** Re-POSTing with the same `Idempotency-Key`
   returns the same `task_id` and `event_id`, and the events table count
   does not grow.
5. **Idempotent consumer.** `POST /admin/republish/{event_id}` re-emits
   the same event. The subscriber's session `dedup_hits` increments, but
   `processed_events` count for that `event_id` stays at `1`.

Finally it pulls pod logs and asserts the lines `RELAY_PUBLISHED`,
`EVENT_PROCESSED`, and `DEDUP_HIT` are present.

## Explore RabbitMQ in the UI

While the demo is up, open <http://localhost:15672>. Sign in as
`tasks` / `tasks`. Worth a click each:

- **Exchanges -> integration.events** - the topic exchange the relay
  publishes to.
- **Queues -> task.subscriber** - durable queue, binding key `task.*`.
  The "Get messages" tool can peek at messages without consuming them.
- **Connections** - the publisher's relay connection and the subscriber's
  consumer connection.
- **Channels** - `confirm-mode` should be on for the publisher's channel.

## Inspect Postgres directly

```sh
# Last few events plus their outbox state:
docker compose exec -T postgres psql -U tasks -d taskdb -c "
  SELECT global_sequence, event_type, published_at IS NOT NULL AS published
  FROM domain_events ORDER BY global_sequence DESC LIMIT 10;"

# Anything still pending publish:
docker compose exec -T postgres psql -U tasks -d taskdb -c "
  SELECT count(*) AS pending FROM domain_events WHERE published_at IS NULL;"

# What the subscriber has processed:
docker compose exec -T postgres psql -U tasks -d taskdb -c "
  SELECT event_id, routing_key, processed_at FROM processed_events
  ORDER BY processed_at DESC LIMIT 10;"
```

Watching `pending` go from `1` to `0` after a `POST /tasks` is the core
thing this PoC tries to make tangible: the write hits Postgres
atomically, and the relay closes the gap to RabbitMQ asynchronously and
exactly-once-effectively (publisher confirms + dedup).

## How this maps to a DDD / event-sourced system

In a real event-sourced system the command handler appends to a stream
and emits one or more domain events. To publish those as **integration
events** to other bounded contexts without a dual-write bug, you write a
row to an outbox table inside the same transaction, then have a separate
relay process publish to the broker.

This PoC keeps that shape with the simplification that the event store
*is* the outbox - the `published_at` column is the only thing the relay
needs. In a richer system you would likely have a separate `outbox` table
holding the integration event payload (often a different shape than the
domain event), but the failure modes are the same:

- Crash after `INSERT` and before publish: relay retries on next tick.
- Crash after publish and before `UPDATE published_at`: relay republishes,
  consumer dedups.
- RabbitMQ rejects publish (queue full, exchange gone): publisher confirm
  is a nack, transaction rolls back, retry on next tick.

## Cleanup Guarantee

`make clean` removes and verifies removal of:

- Kubernetes namespace `rabbitmq-demo`
- Docker Compose containers (`rabbitmq-demo-postgres`, `rabbitmq-demo-broker`)
- Docker Compose volumes
- Docker network
- local images `rabbitmq-demo-publisher:demo` and `rabbitmq-demo-subscriber:demo`
- `logs/`
- `/tmp/rabbitmq-demo-pub-pf.log`, `/tmp/rabbitmq-demo-sub-pf.log`

After `make clean`, a new run starts from an empty runtime state.
