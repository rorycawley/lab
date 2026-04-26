# Redis Cache-Aside Demo

A small learning project that shows a Python app in Rancher Desktop
Kubernetes using **Redis** (running outside the cluster, in Docker
Compose) as a **cache-aside** in front of a slow data source.

## What It Shows

- **Cache-aside reads**: the app checks Redis first; on a miss it
  queries the slow origin, writes the result back to Redis with a TTL,
  and returns the value. The next read for the same key is served from
  Redis until the TTL expires or the key is invalidated.
- **TTL expiry is the cache eviction**: each cached value has a per-key
  TTL (`SET ... EX`). The smoke test sets a 2-second TTL on one key and
  watches the next read fall through to the origin.
- **Manual invalidation**: `DELETE /cache/{id}` removes a single entry,
  `DELETE /cache` clears every `item:*` key via `SCAN` + `DEL`. The
  next read for an invalidated key is a miss again.
- **Hit/miss/latency are observable**: each `GET /items/{id}` returns
  `source` (`cache` or `origin`) and `elapsed_ms`. The cold call pays
  the origin's artificial 200 ms latency; the warm call is sub-millisecond.
- **App in Kubernetes, Redis on the host**: the pod talks to Redis on
  the host via `host.rancher-desktop.internal`, exposed inside the
  cluster as the `external-redis` ExternalName Service.

The slow origin here is a tiny in-memory dict with `time.sleep` baked
in. In a real app it would be Postgres, an HTTP upstream, or anything
that costs more than a Redis round-trip.

## Architecture

```text
HTTP client
  |
  v
Python API in Kubernetes (namespace: redis-demo)
  |
  | 1. GET /items/{id}
  |     GET item:{id} -> Redis
  |       hit  -> return value, source=cache
  |       miss -> origin_lookup(id)  (200 ms sleep)
  |               SET item:{id} value EX 60
  |               return value, source=origin
  v
Docker Compose host
  - redis         (port 6379, requirepass redispass, no persistence)
  - redisinsight  (port 5540, web UI)
```

The app inside Kubernetes reaches Redis via
`host.rancher-desktop.internal`, exposed as an ExternalName Service
named `external-redis`.

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
make clean
```

`make clean` runs even if a check fails.

## Manual Flow

Start Redis + RedisInsight, build the image, deploy the app:

```sh
make up
```

`up` runs, in order: start Docker Compose services (Redis +
RedisInsight), build the app image, apply the Kubernetes namespace
and ExternalName Service, deploy the app, and verify it is Ready.

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

- `make up` - start Redis, build image, deploy app
- `make test` - run the smoke test; needs a port-forward already running
- `make test-all` - run the smoke test with a temporary port-forward
- `make port-forward` - forward `localhost:8080 -> redis-demo-app:8080`
- `make status` - show Kubernetes, Docker, image, log, and port state
- `make full-check` - run everything and always clean up
- `make clean` - remove all demo runtime state
- `make check-local` - syntax-check Python and dry-run k8s manifests

## API Shape

- `GET /` - lists endpoints and configured upstreams
- `GET /healthz` - process liveness
- `GET /readyz` - Redis ping
- `GET /items/{id}?ttl_seconds=N` - cache-aside read. Returns
  `{item, source, key, ttl_remaining, elapsed_ms}`. `source` is
  `cache` or `origin`. `ttl_seconds` overrides the default per-call.
- `GET /cache/{id}` - inspect what is in Redis for this id (raw
  value + remaining TTL), without touching the origin.
- `DELETE /cache/{id}` - invalidate a single cached entry.
- `DELETE /cache` - invalidate every key matching `item:*` via
  `SCAN` + `DEL`.
- `GET /stats` - `hits`, `misses`, `hit_ratio`, `invalidations`,
  `keys_present`.

## What `make test-all` Proves

`scripts/07-test.sh` runs against a temporary port-forward and asserts:

1. **Cold call hits the origin.** `GET /items/1` returns
   `source=origin` and pays the ~200 ms origin latency.
2. **Warm call hits the cache.** A second `GET /items/1` returns
   `source=cache` and is much faster than the cold call. On a local
   run this is roughly `cold=200 ms` vs `warm=1 ms`.
3. **Stats reflect what happened.** `/stats` shows at least one hit
   and one miss.
4. **The key is really in Redis.** `GET /cache/1` shows the raw
   stored value and a positive TTL no greater than the default.
5. **Manual invalidation works.** `DELETE /cache/1` removes the key,
   and the next `GET /items/1` is a miss again.
6. **TTL expiry works.** `GET /items/2?ttl_seconds=2` is a miss; an
   immediate re-call is a hit; after a 3-second sleep the next call
   is a miss again.
7. **Logs prove it.** The app log contains `CACHE_MISS`,
   `CACHE_HIT`, and `CACHE_INVALIDATED`.

## Explore Redis in the UI

While the demo is up, open <http://localhost:5540>. Click **Add
Redis database** (manually). RedisInsight runs in the same Docker
Compose network as Redis, so use the Redis container's service
name as the host:

- **Host**: `redis-demo-server`
- **Port**: `6379`
- **Password**: `redispass`

Worth a click each:

- **Browser** - filter by `item:*` to see what the app has cached.
  Each entry shows the JSON value and remaining TTL. Run a few
  `GET /items/{id}` calls and watch new keys appear.
- **Workbench** - try `TTL item:1`, `KEYS item:*`, `GET item:1`,
  `INFO stats` (look at `keyspace_hits` / `keyspace_misses` from
  Redis's own perspective).

## Inspect Redis directly

```sh
# Keys the app has cached:
docker compose exec -T redis redis-cli -a redispass --no-auth-warning \
  --scan --pattern 'item:*'

# A specific value + its remaining TTL:
docker compose exec -T redis redis-cli -a redispass --no-auth-warning \
  GET item:1
docker compose exec -T redis redis-cli -a redispass --no-auth-warning \
  TTL item:1

# Server-side hit/miss counters:
docker compose exec -T redis redis-cli -a redispass --no-auth-warning \
  INFO stats | grep -E 'keyspace_hits|keyspace_misses'
```

Watching `keyspace_hits` climb on warm calls and `keyspace_misses`
climb only on cold/post-invalidation calls is the core thing this
PoC tries to make tangible.

## Cleanup Guarantee

`make clean` removes and verifies removal of:

- Kubernetes namespace `redis-demo`
- Docker Compose containers (`redis-demo-server`, `redis-demo-insight`)
- Docker Compose volumes
- Docker network
- local image `redis-demo-app:demo`
- `logs/`
- `/tmp/redis-demo-pf.log`

After `make clean`, a new run starts from an empty runtime state.
