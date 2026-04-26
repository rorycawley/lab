import json
import logging
import os
import sys
import threading
import time
from typing import Any

import redis
from fastapi import FastAPI, HTTPException


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("redis-demo")


REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "")
REDIS_DB = int(os.environ.get("REDIS_DB", "0"))

CACHE_KEY_PREFIX = os.environ.get("CACHE_KEY_PREFIX", "item:")
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "60"))
ORIGIN_LATENCY_MS = int(os.environ.get("ORIGIN_LATENCY_MS", "200"))


# ---------------------------------------------------------------------------
# Slow "origin" data source (the thing we want to avoid hitting on every
# request). In a real app this is a database, an upstream HTTP service, or
# anything that costs more than a Redis round-trip.
# ---------------------------------------------------------------------------

ORIGIN: dict[int, dict[str, Any]] = {
    i: {"id": i, "name": f"Item {i}", "price": round(i * 1.5, 2)}
    for i in range(1, 21)
}


def origin_lookup(item_id: int) -> dict[str, Any] | None:
    time.sleep(ORIGIN_LATENCY_MS / 1000.0)
    return ORIGIN.get(item_id)


# ---------------------------------------------------------------------------
# Redis client + counters
# ---------------------------------------------------------------------------


_pool = redis.ConnectionPool(
    host=REDIS_HOST,
    port=REDIS_PORT,
    password=REDIS_PASSWORD or None,
    db=REDIS_DB,
    decode_responses=True,
    socket_connect_timeout=5,
    socket_timeout=5,
)


def r() -> redis.Redis:
    return redis.Redis(connection_pool=_pool)


class Counters:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.hits = 0
        self.misses = 0
        self.invalidations = 0

    def hit(self) -> None:
        with self._lock:
            self.hits += 1

    def miss(self) -> None:
        with self._lock:
            self.misses += 1

    def invalidated(self, n: int = 1) -> None:
        with self._lock:
            self.invalidations += n

    def snapshot(self) -> dict[str, int]:
        with self._lock:
            return {
                "hits": self.hits,
                "misses": self.misses,
                "invalidations": self.invalidations,
            }


counters = Counters()


def cache_key(item_id: int) -> str:
    return f"{CACHE_KEY_PREFIX}{item_id}"


# ---------------------------------------------------------------------------
# FastAPI
# ---------------------------------------------------------------------------


app = FastAPI(title="redis-demo cache-aside")


@app.get("/")
def root() -> dict[str, Any]:
    return {
        "endpoints": [
            "/healthz",
            "/readyz",
            "/items/{id}?ttl_seconds=N",
            "/cache/{id}",
            "DELETE /cache/{id}",
            "DELETE /cache",
            "/stats",
        ],
        "redis_host": REDIS_HOST,
        "redis_port": REDIS_PORT,
        "default_ttl_seconds": CACHE_TTL_SECONDS,
        "origin_latency_ms": ORIGIN_LATENCY_MS,
        "origin_size": len(ORIGIN),
    }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, Any]:
    try:
        r().ping()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"redis: {exc}")
    return {"status": "ok"}


@app.get("/items/{item_id}")
def get_item(item_id: int, ttl_seconds: int | None = None) -> dict[str, Any]:
    """Cache-aside: read Redis first, fall back to origin on miss, write back."""
    key = cache_key(item_id)
    ttl = ttl_seconds if ttl_seconds is not None else CACHE_TTL_SECONDS

    started = time.perf_counter()

    cached = r().get(key)
    if cached is not None:
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        counters.hit()
        logger.info("CACHE_HIT key=%s elapsed_ms=%s", key, elapsed_ms)
        return {
            "item": json.loads(cached),
            "source": "cache",
            "key": key,
            "ttl_remaining": r().ttl(key),
            "elapsed_ms": elapsed_ms,
        }

    item = origin_lookup(item_id)
    if item is None:
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        counters.miss()
        logger.info("ORIGIN_NOT_FOUND key=%s elapsed_ms=%s", key, elapsed_ms)
        raise HTTPException(status_code=404, detail=f"item {item_id} not found")

    r().set(key, json.dumps(item), ex=ttl)
    elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
    counters.miss()
    logger.info(
        "CACHE_MISS key=%s ttl=%s elapsed_ms=%s",
        key, ttl, elapsed_ms,
    )
    return {
        "item": item,
        "source": "origin",
        "key": key,
        "ttl_remaining": ttl,
        "elapsed_ms": elapsed_ms,
    }


@app.get("/cache/{item_id}")
def cache_inspect(item_id: int) -> dict[str, Any]:
    """Show what is in Redis for this id, without touching the origin."""
    key = cache_key(item_id)
    raw = r().get(key)
    return {
        "key": key,
        "present": raw is not None,
        "raw": raw,
        "ttl_remaining": r().ttl(key) if raw is not None else None,
    }


@app.delete("/cache/{item_id}")
def cache_invalidate(item_id: int) -> dict[str, Any]:
    key = cache_key(item_id)
    deleted = r().delete(key)
    counters.invalidated(deleted)
    logger.info("CACHE_INVALIDATED key=%s deleted=%s", key, deleted)
    return {"key": key, "deleted": deleted}


@app.delete("/cache")
def cache_flush() -> dict[str, Any]:
    """Delete every key matching CACHE_KEY_PREFIX*. Uses SCAN, not KEYS."""
    client = r()
    deleted = 0
    for batch in _scan_in_batches(client, match=f"{CACHE_KEY_PREFIX}*", count=200):
        if batch:
            deleted += client.delete(*batch)
    counters.invalidated(deleted)
    logger.info("CACHE_FLUSHED prefix=%s deleted=%s", CACHE_KEY_PREFIX, deleted)
    return {"prefix": CACHE_KEY_PREFIX, "deleted": deleted}


def _scan_in_batches(client: redis.Redis, match: str, count: int):
    cursor = 0
    while True:
        cursor, keys = client.scan(cursor=cursor, match=match, count=count)
        yield keys
        if cursor == 0:
            return


@app.get("/stats")
def stats() -> dict[str, Any]:
    snap = counters.snapshot()
    total = snap["hits"] + snap["misses"]
    hit_ratio = round(snap["hits"] / total, 4) if total else 0.0
    keys_present = sum(
        len(batch) for batch in _scan_in_batches(r(), match=f"{CACHE_KEY_PREFIX}*", count=200)
    )
    return {
        **snap,
        "hit_ratio": hit_ratio,
        "keys_present": keys_present,
    }
