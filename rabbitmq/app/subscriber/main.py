import json
import logging
import os
import sys
import threading
import time
from typing import Any

import pika
import pika.exceptions
import psycopg
from fastapi import FastAPI, HTTPException
from psycopg.rows import dict_row


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("rabbitmq-demo-subscriber")
logging.getLogger("pika").setLevel(logging.WARNING)


POSTGRES_HOST = os.environ["POSTGRES_HOST"]
POSTGRES_PORT = os.environ.get("POSTGRES_PORT", "5432")
POSTGRES_DB = os.environ.get("POSTGRES_DB", "taskdb")
POSTGRES_USER = os.environ.get("POSTGRES_USER", "tasks")
POSTGRES_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "tasks")

RABBITMQ_HOST = os.environ["RABBITMQ_HOST"]
RABBITMQ_PORT = int(os.environ.get("RABBITMQ_PORT", "5672"))
RABBITMQ_USER = os.environ.get("RABBITMQ_USER", "tasks")
RABBITMQ_PASSWORD = os.environ.get("RABBITMQ_PASSWORD", "tasks")
RABBITMQ_EXCHANGE = os.environ.get("RABBITMQ_EXCHANGE", "integration.events")
RABBITMQ_QUEUE = os.environ.get("RABBITMQ_QUEUE", "task.subscriber")
RABBITMQ_BINDING_KEY = os.environ.get("RABBITMQ_BINDING_KEY", "task.*")
PREFETCH_COUNT = int(os.environ.get("PREFETCH_COUNT", "10"))


CONNINFO = (
    f"host={POSTGRES_HOST} port={POSTGRES_PORT} dbname={POSTGRES_DB} "
    f"user={POSTGRES_USER} password={POSTGRES_PASSWORD} "
    f"sslmode=disable connect_timeout=5"
)


def db_connect() -> psycopg.Connection:
    return psycopg.connect(CONNINFO, row_factory=dict_row)


# ---------------------------------------------------------------------------
# Consumer
# ---------------------------------------------------------------------------


class Consumer(threading.Thread):
    def __init__(self) -> None:
        super().__init__(daemon=True, name="rabbit-consumer")
        self._stop = threading.Event()
        self.ready = threading.Event()
        self.processed_total = 0
        self.dedup_hits = 0

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        logger.info(
            "CONSUMER_STARTED queue=%s binding=%s exchange=%s",
            RABBITMQ_QUEUE, RABBITMQ_BINDING_KEY, RABBITMQ_EXCHANGE,
        )
        while not self._stop.is_set():
            try:
                self._run_once()
            except Exception:
                logger.exception("CONSUMER_LOOP_FAILED reconnecting")
                time.sleep(2.0)

    def _run_once(self) -> None:
        creds = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
        params = pika.ConnectionParameters(
            host=RABBITMQ_HOST,
            port=RABBITMQ_PORT,
            credentials=creds,
            heartbeat=30,
            blocked_connection_timeout=10,
        )
        connection = pika.BlockingConnection(params)
        try:
            channel = connection.channel()
            channel.exchange_declare(
                exchange=RABBITMQ_EXCHANGE, exchange_type="topic", durable=True,
            )
            channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
            channel.queue_bind(
                exchange=RABBITMQ_EXCHANGE,
                queue=RABBITMQ_QUEUE,
                routing_key=RABBITMQ_BINDING_KEY,
            )
            channel.basic_qos(prefetch_count=PREFETCH_COUNT)
            channel.basic_consume(
                queue=RABBITMQ_QUEUE,
                on_message_callback=self._on_message,
                auto_ack=False,
            )
            self.ready.set()
            logger.info("CONSUMER_READY")
            while not self._stop.is_set():
                connection.process_data_events(time_limit=1.0)
        finally:
            self.ready.clear()
            try:
                connection.close()
            except Exception:
                pass

    def _on_message(self, channel, method, properties, body: bytes) -> None:
        try:
            payload = json.loads(body.decode("utf-8"))
            event_id = payload["event_id"]
        except Exception:
            logger.exception("BAD_MESSAGE delivery_tag=%s", method.delivery_tag)
            channel.basic_ack(delivery_tag=method.delivery_tag)
            return

        try:
            with db_connect() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        INSERT INTO processed_events (event_id, routing_key, payload)
                        VALUES (%s, %s, %s::jsonb)
                        ON CONFLICT (event_id) DO NOTHING
                        RETURNING event_id
                        """,
                        (event_id, method.routing_key, json.dumps(payload)),
                    )
                    inserted = cur.fetchone() is not None
                    conn.commit()
        except Exception:
            logger.exception("PROCESS_FAILED event_id=%s", event_id)
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
            return

        if inserted:
            self.processed_total += 1
            logger.info(
                "EVENT_PROCESSED event_id=%s routing_key=%s",
                event_id, method.routing_key,
            )
        else:
            self.dedup_hits += 1
            logger.info(
                "DEDUP_HIT event_id=%s routing_key=%s",
                event_id, method.routing_key,
            )
        channel.basic_ack(delivery_tag=method.delivery_tag)


_consumer: Consumer | None = None


# ---------------------------------------------------------------------------
# FastAPI (status + health only)
# ---------------------------------------------------------------------------


app = FastAPI(title="rabbitmq-demo subscriber")


@app.on_event("startup")
def startup() -> None:
    global _consumer
    _consumer = Consumer()
    _consumer.start()


@app.on_event("shutdown")
def shutdown() -> None:
    if _consumer is not None:
        _consumer.stop()


@app.get("/")
def root() -> dict[str, Any]:
    return {
        "endpoints": ["/healthz", "/readyz", "/processed", "/stats"],
        "queue": RABBITMQ_QUEUE,
        "binding_key": RABBITMQ_BINDING_KEY,
        "exchange": RABBITMQ_EXCHANGE,
    }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, Any]:
    try:
        with db_connect() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"db: {exc}")
    if _consumer is None or not _consumer.ready.is_set():
        raise HTTPException(status_code=503, detail="consumer: queue not bound yet")
    return {"status": "ok"}


@app.get("/stats")
def stats() -> dict[str, Any]:
    with db_connect() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) AS n FROM processed_events")
            n = cur.fetchone()["n"]
    return {
        "processed_in_db": n,
        "processed_total_session": _consumer.processed_total if _consumer else 0,
        "dedup_hits_session": _consumer.dedup_hits if _consumer else 0,
    }


@app.get("/processed")
def processed(limit: int = 50) -> dict[str, Any]:
    with db_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT event_id, routing_key, payload, processed_at
                FROM processed_events
                ORDER BY processed_at DESC
                LIMIT %s
                """,
                (limit,),
            )
            rows = cur.fetchall()
    return {
        "count": len(rows),
        "processed": [
            {
                "event_id": str(r["event_id"]),
                "routing_key": r["routing_key"],
                "processed_at": r["processed_at"].isoformat(),
                "payload": r["payload"],
            }
            for r in rows
        ],
    }


@app.get("/processed/{event_id}/count")
def processed_count(event_id: str) -> dict[str, Any]:
    """Returns 1 if processed, 0 otherwise. Used by the smoke test to assert
    consumer-side dedup: re-delivering the same event must keep this at 1."""
    with db_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) AS n FROM processed_events WHERE event_id = %s",
                (event_id,),
            )
            n = cur.fetchone()["n"]
    return {"event_id": event_id, "count": n}
