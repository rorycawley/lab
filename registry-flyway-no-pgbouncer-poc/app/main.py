import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any

import psycopg
from fastapi import FastAPI
from pydantic import BaseModel, Field

app = FastAPI(title="Registry POC API - No PgBouncer")

EVENT_STORE_DATABASE_URL = os.environ["EVENT_STORE_DATABASE_URL"]
READ_STORE_DATABASE_URL = os.environ["READ_STORE_DATABASE_URL"]


class RegisterCompanyRequest(BaseModel):
    company_number: str = Field(..., examples=["777777"])
    company_name: str = Field(..., examples=["New Example Ltd"])
    registered_address: str | None = Field(None, examples=["7 Harbour Road, Galway"])


def fetch_one(conn: psycopg.Connection, sql: str) -> tuple[Any, ...]:
    with conn.cursor() as cur:
        cur.execute(sql)
        return cur.fetchone()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/db-healthz")
def db_healthz() -> dict[str, Any]:
    with psycopg.connect(EVENT_STORE_DATABASE_URL) as event_conn:
        event_db, event_user = fetch_one(event_conn, "select current_database(), current_user;")

    with psycopg.connect(READ_STORE_DATABASE_URL) as read_conn:
        read_db, read_user = fetch_one(read_conn, "select current_database(), current_user;")

    return {
        "status": "ok",
        "event_store": {
            "database": event_db,
            "user": event_user,
            "path": "python-api -> external-event-postgres -> Docker PostgreSQL",
        },
        "read_store": {
            "database": read_db,
            "user": read_user,
            "path": "python-api -> external-read-postgres -> Docker PostgreSQL",
        },
    }


@app.get("/companies")
def get_companies() -> dict[str, Any]:
    with psycopg.connect(READ_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    company_number,
                    company_name,
                    registered_address,
                    status,
                    last_event_id,
                    updated_at
                FROM company_read_model
                ORDER BY company_number;
                """
            )
            columns = [desc.name for desc in cur.description]
            rows = cur.fetchall()

    return {
        "message": "Data read from the read-store database",
        "companies": [dict(zip(columns, row)) for row in rows],
    }


@app.get("/events")
def get_events() -> dict[str, Any]:
    with psycopg.connect(EVENT_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    sequence,
                    event_id,
                    stream_id,
                    event_type,
                    event_data,
                    correlation_id,
                    occurred_at
                FROM domain_events
                ORDER BY sequence;
                """
            )
            columns = [desc.name for desc in cur.description]
            rows = cur.fetchall()

    return {
        "message": "Events read from the event-store database",
        "events": [dict(zip(columns, row)) for row in rows],
    }


@app.post("/companies/register", status_code=201)
def register_company(request: RegisterCompanyRequest) -> dict[str, Any]:
    event_id = uuid.uuid4()
    correlation_id = uuid.uuid4()
    stream_id = f"company-{request.company_number}"
    occurred_at = datetime.now(timezone.utc)
    event_data = {
        "company_number": request.company_number,
        "company_name": request.company_name,
        "registered_address": request.registered_address,
    }

    # In the real system, Marten/event sourcing would append the event transactionally
    # to the event store. This POC uses plain SQL to simulate the same idea.
    with psycopg.connect(EVENT_STORE_DATABASE_URL) as event_conn:
        with event_conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO domain_events (
                    event_id,
                    stream_id,
                    event_type,
                    event_data,
                    correlation_id,
                    occurred_at
                )
                VALUES (%s, %s, %s, %s::jsonb, %s, %s)
                RETURNING sequence;
                """,
                (
                    event_id,
                    stream_id,
                    "CompanyRegistered",
                    json.dumps(event_data),
                    correlation_id,
                    occurred_at,
                ),
            )
            sequence = cur.fetchone()[0]

    # In the real system, this would usually be an async projection worker.
    # For the POC, we update the read model synchronously so the flow is easy to see.
    with psycopg.connect(READ_STORE_DATABASE_URL) as read_conn:
        with read_conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO company_read_model (
                    company_number,
                    company_name,
                    registered_address,
                    status,
                    last_event_id,
                    updated_at
                )
                VALUES (%s, %s, %s, 'Registered', %s, now())
                ON CONFLICT (company_number)
                DO UPDATE SET
                    company_name = EXCLUDED.company_name,
                    registered_address = EXCLUDED.registered_address,
                    status = EXCLUDED.status,
                    last_event_id = EXCLUDED.last_event_id,
                    updated_at = now();
                """,
                (
                    request.company_number,
                    request.company_name,
                    request.registered_address,
                    event_id,
                ),
            )

    return {
        "message": "Company registered. Event store written and read model updated.",
        "event": {
            "sequence": sequence,
            "event_id": str(event_id),
            "stream_id": stream_id,
            "event_type": "CompanyRegistered",
            "correlation_id": str(correlation_id),
        },
    }
