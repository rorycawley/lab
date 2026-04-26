import json
import logging
import os
import sys
import threading
import time
import uuid
from typing import Any

import pika
import pika.exceptions
import psycopg
from fastapi import FastAPI, Header, HTTPException
from psycopg.rows import dict_row
from pydantic import BaseModel


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("rabbitmq-demo-publisher")
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

RELAY_INTERVAL_SECONDS = float(os.environ.get("RELAY_INTERVAL_SECONDS", "0.5"))
RELAY_BATCH_SIZE = int(os.environ.get("RELAY_BATCH_SIZE", "100"))


CONNINFO = (
    f"host={POSTGRES_HOST} port={POSTGRES_PORT} dbname={POSTGRES_DB} "
    f"user={POSTGRES_USER} password={POSTGRES_PASSWORD} "
    f"sslmode=disable connect_timeout=5"
)


def db_connect() -> psycopg.Connection:
    return psycopg.connect(CONNINFO, row_factory=dict_row)


# ---------------------------------------------------------------------------
# Outbox relay
# ---------------------------------------------------------------------------


class OutboxRelay(threading.Thread):
    """Drains domain_events rows where published_at IS NULL.

    Uses RabbitMQ publisher confirms + the mandatory flag, and only stamps
    published_at after the broker has acked the publish.
    """

    def __init__(self) -> None:
        super().__init__(daemon=True, name="outbox-relay")
        self._stop = threading.Event()
        self._channel: pika.adapters.blocking_connection.BlockingChannel | None = None
        self._connection: pika.BlockingConnection | None = None
        self.published_total = 0

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        logger.info("RELAY_STARTED interval=%ss batch=%s", RELAY_INTERVAL_SECONDS, RELAY_BATCH_SIZE)
        while not self._stop.is_set():
            try:
                self._tick()
            except Exception:
                logger.exception("RELAY_TICK_FAILED")
                self._close_channel()
                time.sleep(1.0)
            self._stop.wait(RELAY_INTERVAL_SECONDS)
        self._close_channel()

    def _ensure_channel(self) -> pika.adapters.blocking_connection.BlockingChannel:
        if self._channel is not None and self._channel.is_open:
            return self._channel
        creds = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
        params = pika.ConnectionParameters(
            host=RABBITMQ_HOST,
            port=RABBITMQ_PORT,
            credentials=creds,
            heartbeat=30,
            blocked_connection_timeout=10,
        )
        self._connection = pika.BlockingConnection(params)
        ch = self._connection.channel()
        ch.exchange_declare(
            exchange=RABBITMQ_EXCHANGE,
            exchange_type="topic",
            durable=True,
        )
        ch.confirm_delivery()
        self._channel = ch
        logger.info("RELAY_CONNECTED exchange=%s", RABBITMQ_EXCHANGE)
        return ch

    def _close_channel(self) -> None:
        try:
            if self._channel is not None and self._channel.is_open:
                self._channel.close()
        except Exception:
            pass
        try:
            if self._connection is not None and self._connection.is_open:
                self._connection.close()
        except Exception:
            pass
        self._channel = None
        self._connection = None

    def _tick(self) -> None:
        ch = self._ensure_channel()
        with db_connect() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT global_sequence, event_id, stream_id, stream_version,
                           event_type, event_data, occurred_at
                    FROM domain_events
                    WHERE published_at IS NULL
                    ORDER BY global_sequence
                    FOR UPDATE SKIP LOCKED
                    LIMIT %s
                    """,
                    (RELAY_BATCH_SIZE,),
                )
                rows = cur.fetchall()
                if not rows:
                    conn.rollback()
                    return
                for row in rows:
                    routing_key = self._routing_key(row["event_type"])
                    body = json.dumps(
                        {
                            "event_id": str(row["event_id"]),
                            "stream_id": row["stream_id"],
                            "stream_version": row["stream_version"],
                            "event_type": row["event_type"],
                            "occurred_at": row["occurred_at"].isoformat(),
                            "data": row["event_data"],
                        }
                    ).encode("utf-8")
                    properties = pika.BasicProperties(
                        content_type="application/json",
                        delivery_mode=2,
                        message_id=str(row["event_id"]),
                        type=row["event_type"],
                        timestamp=int(row["occurred_at"].timestamp()),
                    )
                    try:
                        ch.basic_publish(
                            exchange=RABBITMQ_EXCHANGE,
                            routing_key=routing_key,
                            body=body,
                            properties=properties,
                            mandatory=True,
                        )
                    except pika.exceptions.UnroutableError:
                        logger.error(
                            "RELAY_UNROUTABLE event_id=%s routing_key=%s",
                            row["event_id"],
                            routing_key,
                        )
                        conn.rollback()
                        return
                    cur.execute(
                        "UPDATE domain_events SET published_at = now() WHERE global_sequence = %s",
                        (row["global_sequence"],),
                    )
                    self.published_total += 1
                    logger.info(
                        "RELAY_PUBLISHED event_id=%s routing_key=%s seq=%s",
                        row["event_id"],
                        routing_key,
                        row["global_sequence"],
                    )
                conn.commit()

    @staticmethod
    def _routing_key(event_type: str) -> str:
        return f"task.{event_type.removeprefix('task-')}"


_relay: OutboxRelay | None = None


# ---------------------------------------------------------------------------
# FastAPI
# ---------------------------------------------------------------------------


app = FastAPI(title="rabbitmq-demo publisher")


class CreateTaskRequest(BaseModel):
    title: str


@app.on_event("startup")
def startup() -> None:
    global _relay
    _relay = OutboxRelay()
    _relay.start()


@app.on_event("shutdown")
def shutdown() -> None:
    if _relay is not None:
        _relay.stop()


@app.get("/")
def root() -> dict[str, Any]:
    return {
        "endpoints": [
            "/healthz",
            "/readyz",
            "POST /tasks (header: Idempotency-Key)",
            "/events",
            "/outbox/pending",
            "POST /admin/republish/{event_id}",
        ],
        "postgres_host": POSTGRES_HOST,
        "rabbitmq_host": RABBITMQ_HOST,
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
    try:
        creds = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
        params = pika.ConnectionParameters(
            host=RABBITMQ_HOST, port=RABBITMQ_PORT, credentials=creds, heartbeat=10,
            blocked_connection_timeout=5, socket_timeout=5,
        )
        conn = pika.BlockingConnection(params)
        conn.close()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"rabbitmq: {exc}")
    return {"status": "ok"}


@app.post("/tasks", status_code=201)
def create_task(
    body: CreateTaskRequest,
    idempotency_key: str = Header(..., alias="Idempotency-Key"),
) -> dict[str, Any]:
    with db_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT response FROM command_idempotency WHERE idempotency_key = %s",
                (idempotency_key,),
            )
            existing = cur.fetchone()
            if existing is not None:
                return existing["response"]

            task_id = str(uuid.uuid4())
            event_id = str(uuid.uuid4())
            stream_id = f"task-{task_id}"
            event_data = {"task_id": task_id, "title": body.title}

            cur.execute(
                """
                INSERT INTO domain_events
                    (event_id, stream_id, stream_version, event_type, event_data)
                VALUES (%s, %s, %s, %s, %s::jsonb)
                """,
                (event_id, stream_id, 1, "task-created", json.dumps(event_data)),
            )
            response = {
                "task_id": task_id,
                "event_id": event_id,
                "stream_id": stream_id,
                "title": body.title,
            }
            cur.execute(
                """
                INSERT INTO command_idempotency (idempotency_key, event_id, response)
                VALUES (%s, %s, %s::jsonb)
                """,
                (idempotency_key, event_id, json.dumps(response)),
            )
            conn.commit()
            logger.info(
                "TASK_CREATED task_id=%s event_id=%s key=%s",
                task_id, event_id, idempotency_key,
            )
            return response


@app.get("/events")
def list_events(limit: int = 50) -> dict[str, Any]:
    with db_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT global_sequence, event_id, stream_id, stream_version,
                       event_type, event_data, occurred_at, published_at
                FROM domain_events
                ORDER BY global_sequence DESC
                LIMIT %s
                """,
                (limit,),
            )
            rows = cur.fetchall()
    return {
        "count": len(rows),
        "events": [
            {
                "global_sequence": r["global_sequence"],
                "event_id": str(r["event_id"]),
                "stream_id": r["stream_id"],
                "stream_version": r["stream_version"],
                "event_type": r["event_type"],
                "event_data": r["event_data"],
                "occurred_at": r["occurred_at"].isoformat(),
                "published_at": r["published_at"].isoformat() if r["published_at"] else None,
            }
            for r in rows
        ],
    }


@app.get("/outbox/pending")
def outbox_pending() -> dict[str, Any]:
    with db_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT global_sequence, event_id, stream_id, event_type, occurred_at
                FROM domain_events
                WHERE published_at IS NULL
                ORDER BY global_sequence
                """
            )
            rows = cur.fetchall()
    return {
        "count": len(rows),
        "pending": [
            {
                "global_sequence": r["global_sequence"],
                "event_id": str(r["event_id"]),
                "stream_id": r["stream_id"],
                "event_type": r["event_type"],
                "occurred_at": r["occurred_at"].isoformat(),
            }
            for r in rows
        ],
    }


@app.post("/admin/republish/{event_id}")
def admin_republish(event_id: str) -> dict[str, Any]:
    """Re-emit an already-published event without going through the outbox.

    Used by the smoke test to prove the consumer dedups by event_id.
    Opens its own RabbitMQ channel so it does not interfere with the relay.
    """
    with db_connect() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT event_id, stream_id, stream_version, event_type,
                       event_data, occurred_at
                FROM domain_events
                WHERE event_id = %s
                """,
                (event_id,),
            )
            row = cur.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="event_id not found")

    routing_key = OutboxRelay._routing_key(row["event_type"])
    body = json.dumps(
        {
            "event_id": str(row["event_id"]),
            "stream_id": row["stream_id"],
            "stream_version": row["stream_version"],
            "event_type": row["event_type"],
            "occurred_at": row["occurred_at"].isoformat(),
            "data": row["event_data"],
        }
    ).encode("utf-8")

    creds = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
    params = pika.ConnectionParameters(
        host=RABBITMQ_HOST, port=RABBITMQ_PORT, credentials=creds, heartbeat=10,
    )
    rabbit_conn = pika.BlockingConnection(params)
    try:
        ch = rabbit_conn.channel()
        ch.exchange_declare(exchange=RABBITMQ_EXCHANGE, exchange_type="topic", durable=True)
        ch.confirm_delivery()
        ch.basic_publish(
            exchange=RABBITMQ_EXCHANGE,
            routing_key=routing_key,
            body=body,
            properties=pika.BasicProperties(
                content_type="application/json",
                delivery_mode=2,
                message_id=str(row["event_id"]),
                type=row["event_type"],
            ),
            mandatory=True,
        )
        logger.info("REPUBLISHED event_id=%s routing_key=%s", event_id, routing_key)
    finally:
        rabbit_conn.close()
    return {"event_id": event_id, "routing_key": routing_key, "republished": True}
