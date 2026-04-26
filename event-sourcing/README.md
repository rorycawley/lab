# Event Sourcing + CQRS Demo

A small learning project that demonstrates event sourcing and CQRS with one
Python file, two PostgreSQL databases, Flyway migrations, Docker Compose, and
Rancher Desktop Kubernetes.

## What It Shows

- Commands append immutable events to an event store.
- Queries read from a separate projected read store.
- A projector turns events into queryable state.
- Every command uses an `Idempotency-Key`.
- Existing-stream commands require `expected_version` for optimistic concurrency.
- Flyway creates the event-store and read-store schemas.

## Architecture

```text
HTTP client
  |
  v
Python API in Kubernetes
  |                         |
  | commands                | queries
  v                         v
Postgres event store        Postgres read store
domain_events               task_read_model
command_idempotency         projection_checkpoint
```

The two PostgreSQL 18 databases run with Docker Compose. Kubernetes reaches
them through `host.rancher-desktop.internal`.

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
make verify-db
make clean
```

`make clean` runs even if a check fails.

## Manual Flow

Start the databases, run Flyway, build the API image, and deploy to Kubernetes:

```sh
make up
```

Run the smoke test and stress test with a temporary port-forward:

```sh
make test-all
```

Inspect the event store and read store directly:

```sh
make verify-db
```

Check what is currently running:

```sh
make status
```

Remove all runtime state:

```sh
make clean
```

## Useful Targets

- `make up` - start Postgres, run Flyway jobs, deploy the API
- `make test` - run the narrative HTTP smoke test; needs port-forward
- `make stress` - stress idempotency and optimistic concurrency; needs port-forward
- `make test-all` - run smoke + stress with a temporary port-forward
- `make verify-db` - query database tables directly
- `make status` - show Kubernetes, Docker, image, log, and port state
- `make full-check` - run everything and always clean up
- `make clean` - remove all demo runtime state

## API Shape

Command endpoints write events:

- `POST /commands/tasks`
- `POST /commands/tasks/{task_id}/rename?expected_version=N`
- `POST /commands/tasks/{task_id}/complete?expected_version=N`
- `POST /commands/tasks/{task_id}/reopen?expected_version=N`

Projection endpoint updates the read store:

- `POST /projector/run`

Query endpoints read state or event history:

- `GET /queries/events`
- `GET /queries/tasks`
- `GET /queries/tasks/{task_id}`
- `GET /queries/projection`

Every command needs an `Idempotency-Key` header.

## Cleanup Guarantee

`make clean` removes and verifies removal of:

- Kubernetes namespace `event-sourcing-demo`
- Docker Compose containers
- Docker Compose volumes
- Docker network
- local image `task-event-sourcing-api:demo`
- `logs/`
- `/tmp/event-sourcing-port-forward.log`

After `make clean`, a new run starts from an empty runtime state.
