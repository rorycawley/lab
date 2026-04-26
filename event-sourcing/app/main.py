import json
import hashlib
import logging
import os
import sys
import uuid
from datetime import datetime, timezone
from typing import Any

import psycopg
from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("event-sourcing-demo")

app = FastAPI(title="Single-file Event Sourcing + CQRS demo")

EVENT_STORE_DATABASE_URL = os.environ["EVENT_STORE_DATABASE_URL"]
READ_STORE_DATABASE_URL = os.environ["READ_STORE_DATABASE_URL"]


class CreateTaskRequest(BaseModel):
    title: str = Field(..., min_length=1, examples=["Learn event sourcing"])
    assigned_to: str | None = Field(None, examples=["Rory"])


class RenameTaskRequest(BaseModel):
    title: str = Field(..., min_length=1, examples=["Learn CQRS projections"])


def request_hash(payload: dict[str, Any]) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def rows_as_dicts(cursor: psycopg.Cursor) -> list[dict[str, Any]]:
    columns = [desc.name for desc in cursor.description]
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


def fetch_one(conn: psycopg.Connection, sql: str, params: tuple[Any, ...] = ()) -> tuple[Any, ...] | None:
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def event_response(row: dict[str, Any], idempotent: bool = False) -> dict[str, Any]:
    return {
        "global_sequence": row["global_sequence"],
        "event_id": str(row["event_id"]),
        "stream_id": row["stream_id"],
        "stream_version": row["stream_version"],
        "event_type": row["event_type"],
        "event_data": row["event_data"],
        "correlation_id": str(row["correlation_id"]),
        "occurred_at": row["occurred_at"].isoformat(),
        "idempotent": idempotent,
    }


def find_existing_event_for_key(
    cur: psycopg.Cursor, idempotency_key: str, payload_hash: str
) -> dict[str, Any] | None:
    cur.execute(
        """
        SELECT request_hash, global_sequence
        FROM command_idempotency
        WHERE idempotency_key = %s;
        """,
        (idempotency_key,),
    )
    existing = cur.fetchone()
    if existing is None:
        return None

    existing_hash, global_sequence = existing
    if existing_hash != payload_hash:
        logger.warning("IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST key=%s", idempotency_key)
        raise HTTPException(
            status_code=409,
            detail="Idempotency-Key was already used for a different command payload",
        )

    cur.execute(
        """
        SELECT global_sequence, event_id, stream_id, stream_version, event_type, event_data,
               correlation_id, occurred_at
        FROM domain_events
        WHERE global_sequence = %s;
        """,
        (global_sequence,),
    )
    columns = [desc.name for desc in cur.description]
    row = dict(zip(columns, cur.fetchone()))
    logger.info(
        "IDEMPOTENT_REPLAY key=%s event_type=%s stream_id=%s stream_version=%s",
        idempotency_key,
        row["event_type"],
        row["stream_id"],
        row["stream_version"],
    )
    return row


def idempotent_replay(idempotency_key: str, idempotency_payload: dict[str, Any]) -> dict[str, Any] | None:
    payload_hash = request_hash(idempotency_payload)
    with psycopg.connect(EVENT_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            existing = find_existing_event_for_key(cur, idempotency_key, payload_hash)
            return event_response(existing, idempotent=True) if existing is not None else None


def append_event(
    stream_id: str,
    event_type: str,
    event_data: dict[str, Any],
    expected_version: int | None,
    idempotency_key: str,
    idempotency_payload: dict[str, Any],
) -> dict[str, Any]:
    event_id = uuid.uuid4()
    correlation_id = uuid.uuid4()
    occurred_at = datetime.now(timezone.utc)
    payload_hash = request_hash(idempotency_payload)

    with psycopg.connect(EVENT_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            existing = find_existing_event_for_key(cur, idempotency_key, payload_hash)
            if existing is not None:
                return event_response(existing, idempotent=True)

            # This transaction-level advisory lock serializes writers for the same stream.
            # The unique (stream_id, stream_version) constraint is the database backstop.
            cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s));", (stream_id,))
            cur.execute("SELECT COALESCE(MAX(stream_version), 0) FROM domain_events WHERE stream_id = %s;", (stream_id,))
            current = cur.fetchone()[0]
            if expected_version is not None and current != expected_version:
                logger.warning(
                    "OPTIMISTIC_CONCURRENCY_CONFLICT stream_id=%s expected_version=%s actual_version=%s",
                    stream_id,
                    expected_version,
                    current,
                )
                raise HTTPException(
                    status_code=409,
                    detail={
                        "message": "Optimistic concurrency check failed",
                        "stream_id": stream_id,
                        "expected_version": expected_version,
                        "actual_version": current,
                    },
                )

            next_version = current + 1
            cur.execute(
                """
                INSERT INTO domain_events (
                    event_id,
                    stream_id,
                    stream_version,
                    event_type,
                    event_data,
                    correlation_id,
                    occurred_at
                )
                VALUES (%s, %s, %s, %s, %s::jsonb, %s, %s)
                RETURNING global_sequence;
                """,
                (
                    event_id,
                    stream_id,
                    next_version,
                    event_type,
                    json.dumps(event_data),
                    correlation_id,
                    occurred_at,
                ),
            )
            global_sequence = cur.fetchone()[0]
            cur.execute(
                """
                INSERT INTO command_idempotency (
                    idempotency_key,
                    request_hash,
                    event_id,
                    global_sequence,
                    created_at
                )
                VALUES (%s, %s, %s, %s, now());
                """,
                (idempotency_key, payload_hash, event_id, global_sequence),
            )

    logger.info(
        "COMMAND_APPEND event_type=%s stream_id=%s stream_version=%s global_sequence=%s idempotency_key=%s",
        event_type,
        stream_id,
        next_version,
        global_sequence,
        idempotency_key,
    )

    return {
        "global_sequence": global_sequence,
        "event_id": str(event_id),
        "stream_id": stream_id,
        "stream_version": next_version,
        "event_type": event_type,
        "event_data": event_data,
        "correlation_id": str(correlation_id),
        "occurred_at": occurred_at.isoformat(),
        "idempotent": False,
    }


def load_stream(stream_id: str) -> list[dict[str, Any]]:
    with psycopg.connect(EVENT_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT global_sequence, event_id, stream_id, stream_version, event_type, event_data, occurred_at
                FROM domain_events
                WHERE stream_id = %s
                ORDER BY stream_version;
                """,
                (stream_id,),
            )
            return rows_as_dicts(cur)


def task_state_from_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    state: dict[str, Any] = {"exists": False, "completed": False, "version": 0}
    for event in events:
        data = event["event_data"]
        state["version"] = event["stream_version"]
        if event["event_type"] == "task-created":
            state.update(
                {
                    "exists": True,
                    "task_id": data["task_id"],
                    "title": data["title"],
                    "assigned_to": data.get("assigned_to"),
                    "completed": False,
                }
            )
        elif event["event_type"] == "task-renamed":
            state["title"] = data["title"]
        elif event["event_type"] == "task-completed":
            state["completed"] = True
        elif event["event_type"] == "task-reopened":
            state["completed"] = False
    return state


def require_task_state(task_id: str) -> dict[str, Any]:
    state = task_state_from_events(load_stream(f"task-{task_id}"))
    if not state["exists"]:
        raise HTTPException(status_code=404, detail=f"Task {task_id} has no task-created event")
    return state


def require_expected_version(expected_version: int | None) -> int:
    if expected_version is None:
        raise HTTPException(
            status_code=422,
            detail="expected_version query parameter is required for commands that update an existing stream",
        )
    return expected_version


def project_event(read_conn: psycopg.Connection, event: dict[str, Any]) -> None:
    data = event["event_data"]
    event_type = event["event_type"]

    with read_conn.cursor() as cur:
        if event_type == "task-created":
            cur.execute(
                """
                INSERT INTO task_read_model (
                    task_id,
                    title,
                    assigned_to,
                    status,
                    version,
                    last_event_sequence,
                    updated_at
                )
                VALUES (%s, %s, %s, 'open', %s, %s, %s)
                ON CONFLICT (task_id)
                DO UPDATE SET
                    title = EXCLUDED.title,
                    assigned_to = EXCLUDED.assigned_to,
                    status = EXCLUDED.status,
                    version = EXCLUDED.version,
                    last_event_sequence = EXCLUDED.last_event_sequence,
                    updated_at = EXCLUDED.updated_at;
                """,
                (
                    data["task_id"],
                    data["title"],
                    data.get("assigned_to"),
                    event["stream_version"],
                    event["global_sequence"],
                    event["occurred_at"],
                ),
            )
        elif event_type == "task-renamed":
            cur.execute(
                """
                UPDATE task_read_model
                SET title = %s,
                    version = %s,
                    last_event_sequence = %s,
                    updated_at = %s
                WHERE task_id = %s;
                """,
                (
                    data["title"],
                    event["stream_version"],
                    event["global_sequence"],
                    event["occurred_at"],
                    data["task_id"],
                ),
            )
        elif event_type == "task-completed":
            cur.execute(
                """
                UPDATE task_read_model
                SET status = 'completed',
                    completed_at = %s,
                    version = %s,
                    last_event_sequence = %s,
                    updated_at = %s
                WHERE task_id = %s;
                """,
                (
                    event["occurred_at"],
                    event["stream_version"],
                    event["global_sequence"],
                    event["occurred_at"],
                    data["task_id"],
                ),
            )
        elif event_type == "task-reopened":
            cur.execute(
                """
                UPDATE task_read_model
                SET status = 'open',
                    completed_at = NULL,
                    version = %s,
                    last_event_sequence = %s,
                    updated_at = %s
                WHERE task_id = %s;
                """,
                (
                    event["stream_version"],
                    event["global_sequence"],
                    event["occurred_at"],
                    data["task_id"],
                ),
            )


@app.get("/healthz")
def healthz() -> dict[str, str]:
    logger.info("QUERY healthz")
    return {"status": "ok"}


@app.get("/db-healthz")
def db_healthz() -> dict[str, Any]:
    with psycopg.connect(EVENT_STORE_DATABASE_URL) as event_conn:
        event_db, event_user = fetch_one(event_conn, "SELECT current_database(), current_user;")
    with psycopg.connect(READ_STORE_DATABASE_URL) as read_conn:
        read_db, read_user = fetch_one(read_conn, "SELECT current_database(), current_user;")

    logger.info("QUERY db-healthz event_store=%s read_store=%s", event_db, read_db)
    return {
        "status": "ok",
        "event_store": {
            "database": event_db,
            "user": event_user,
            "table": "domain_events",
            "purpose": "Commands append immutable facts here.",
        },
        "read_store": {
            "database": read_db,
            "user": read_user,
            "tables": ["task_read_model", "projection_checkpoint"],
            "purpose": "Queries read projected task state here.",
        },
    }


@app.get("/ui", response_class=HTMLResponse)
def ui() -> str:
    return """
    <!doctype html>
    <html>
      <head>
        <title>Event Sourcing Demo</title>
        <style>
          body { font-family: system-ui, sans-serif; max-width: 960px; margin: 40px auto; line-height: 1.45; }
          code, pre { background: #f4f4f4; padding: 2px 4px; border-radius: 4px; }
          section { border-top: 1px solid #ddd; padding-top: 18px; margin-top: 24px; }
          input, button { font: inherit; padding: 8px; margin: 4px; }
          button { cursor: pointer; }
          pre { padding: 12px; overflow: auto; }
        </style>
      </head>
      <body>
        <h1>Event Sourcing + CQRS: Tasks</h1>
        <p>
          Commands write events to <code>domain_events</code>. Queries read task state from
          <code>task_read_model</code>. Run the projector to move from the event log to the read model.
        </p>
        <section>
          <h2>1. Command: append a task-created event</h2>
          <input id="title" value="Learn event sourcing" />
          <input id="assigned" value="Rory" />
          <button onclick="createTask()">Create task</button>
        </section>
        <section>
          <h2>2. Query the event store, project, then query the read store</h2>
          <button onclick="getEvents()">Show events</button>
          <button onclick="runProjector()">Run projector</button>
          <button onclick="getTasks()">Show projected tasks</button>
        </section>
        <pre id="out">{}</pre>
        <script>
          async function call(path, options) {
            const res = await fetch(path, options);
            const data = await res.json();
            document.getElementById("out").textContent = JSON.stringify(data, null, 2);
          }
          function key() {
            return crypto.randomUUID ? crypto.randomUUID() : String(Date.now());
          }
          function createTask() {
            call("/commands/tasks", {
              method: "POST",
              headers: {"Content-Type": "application/json", "Idempotency-Key": key()},
              body: JSON.stringify({
                title: document.getElementById("title").value,
                assigned_to: document.getElementById("assigned").value
              })
            });
          }
          function getEvents() { call("/queries/events"); }
          function runProjector() { call("/projector/run", {method: "POST"}); }
          function getTasks() { call("/queries/tasks"); }
        </script>
      </body>
    </html>
    """


@app.post("/commands/tasks", status_code=201)
def create_task(request: CreateTaskRequest, idempotency_key: str = Header(..., alias="Idempotency-Key")) -> dict[str, Any]:
    task_id = str(uuid.uuid4())
    event = append_event(
        stream_id=f"task-{task_id}",
        event_type="task-created",
        event_data={"task_id": task_id, "title": request.title, "assigned_to": request.assigned_to},
        expected_version=0,
        idempotency_key=idempotency_key,
        idempotency_payload={
            "command": "create-task",
            "title": request.title,
            "assigned_to": request.assigned_to,
        },
    )
    return {
        "message": "Command accepted. This wrote one immutable task-created event to domain_events.",
        "event": event,
        "next_step": "POST /projector/run to update the read-store projection.",
    }


@app.post("/commands/tasks/{task_id}/rename")
def rename_task(
    task_id: str,
    request: RenameTaskRequest,
    idempotency_key: str = Header(..., alias="Idempotency-Key"),
    expected_version: int | None = Query(None),
) -> dict[str, Any]:
    expected = require_expected_version(expected_version)
    require_task_state(task_id)
    event = append_event(
        stream_id=f"task-{task_id}",
        event_type="task-renamed",
        event_data={"task_id": task_id, "title": request.title},
        expected_version=expected,
        idempotency_key=idempotency_key,
        idempotency_payload={
            "command": "rename-task",
            "task_id": task_id,
            "title": request.title,
            "expected_version": expected,
        },
    )
    return {"message": "Appended task-renamed event.", "event": event}


@app.post("/commands/tasks/{task_id}/complete")
def complete_task(
    task_id: str,
    idempotency_key: str = Header(..., alias="Idempotency-Key"),
    expected_version: int | None = Query(None),
) -> dict[str, Any]:
    expected = require_expected_version(expected_version)
    replay = idempotent_replay(
        idempotency_key,
        {"command": "complete-task", "task_id": task_id, "expected_version": expected},
    )
    if replay is not None:
        return {"message": "Idempotent replay of task-completed event.", "event": replay}

    state = require_task_state(task_id)
    if state["completed"]:
        raise HTTPException(status_code=409, detail="Task is already completed")
    event = append_event(
        stream_id=f"task-{task_id}",
        event_type="task-completed",
        event_data={"task_id": task_id},
        expected_version=expected,
        idempotency_key=idempotency_key,
        idempotency_payload={
            "command": "complete-task",
            "task_id": task_id,
            "expected_version": expected,
        },
    )
    return {"message": "Appended task-completed event.", "event": event}


@app.post("/commands/tasks/{task_id}/reopen")
def reopen_task(
    task_id: str,
    idempotency_key: str = Header(..., alias="Idempotency-Key"),
    expected_version: int | None = Query(None),
) -> dict[str, Any]:
    expected = require_expected_version(expected_version)
    replay = idempotent_replay(
        idempotency_key,
        {"command": "reopen-task", "task_id": task_id, "expected_version": expected},
    )
    if replay is not None:
        return {"message": "Idempotent replay of task-reopened event.", "event": replay}

    state = require_task_state(task_id)
    if not state["completed"]:
        raise HTTPException(status_code=409, detail="Task is already open")
    event = append_event(
        stream_id=f"task-{task_id}",
        event_type="task-reopened",
        event_data={"task_id": task_id},
        expected_version=expected,
        idempotency_key=idempotency_key,
        idempotency_payload={
            "command": "reopen-task",
            "task_id": task_id,
            "expected_version": expected,
        },
    )
    return {"message": "Appended task-reopened event.", "event": event}


@app.post("/projector/run")
def run_projector() -> dict[str, Any]:
    with psycopg.connect(READ_STORE_DATABASE_URL) as read_conn:
        last_sequence = fetch_one(
            read_conn,
            "SELECT last_global_sequence FROM projection_checkpoint WHERE projection_name = 'task_read_model';",
        )[0]

        with psycopg.connect(EVENT_STORE_DATABASE_URL) as event_conn:
            with event_conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT global_sequence, event_id, stream_id, stream_version, event_type, event_data, occurred_at
                    FROM domain_events
                    WHERE global_sequence > %s
                    ORDER BY global_sequence;
                    """,
                    (last_sequence,),
                )
                events = rows_as_dicts(cur)

        for event in events:
            project_event(read_conn, event)
            with read_conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE projection_checkpoint
                    SET last_global_sequence = %s, updated_at = now()
                    WHERE projection_name = 'task_read_model';
                    """,
                    (event["global_sequence"],),
                )

    logger.info(
        "PROJECTOR_RUN events_projected=%s last_global_sequence=%s",
        len(events),
        events[-1]["global_sequence"] if events else last_sequence,
    )
    return {
        "message": "Projected new events into the read-store task_read_model table.",
        "events_projected": len(events),
        "last_global_sequence": events[-1]["global_sequence"] if events else last_sequence,
    }


@app.get("/queries/events")
def get_events() -> dict[str, Any]:
    with psycopg.connect(EVENT_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT global_sequence, event_id, stream_id, stream_version, event_type, event_data, occurred_at
                FROM domain_events
                ORDER BY global_sequence;
                """
            )
            events = rows_as_dicts(cur)
    logger.info("QUERY events count=%s", len(events))
    return {
        "message": "This is the event log. These rows are facts, not current state.",
        "table": "event_store.domain_events",
        "events": events,
    }


@app.get("/queries/tasks")
def get_tasks() -> dict[str, Any]:
    with psycopg.connect(READ_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT task_id, title, assigned_to, status, version, last_event_sequence, completed_at, updated_at
                FROM task_read_model
                ORDER BY updated_at DESC, task_id;
                """
            )
            tasks = rows_as_dicts(cur)
    logger.info("QUERY tasks count=%s", len(tasks))
    return {
        "message": "This is projected read state. It changes only after POST /projector/run.",
        "table": "read_store.task_read_model",
        "tasks": tasks,
    }


@app.get("/queries/tasks/{task_id}")
def get_task(task_id: str) -> dict[str, Any]:
    with psycopg.connect(READ_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT task_id, title, assigned_to, status, version, last_event_sequence, completed_at, updated_at
                FROM task_read_model
                WHERE task_id = %s;
                """,
                (task_id,),
            )
            row = cur.fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail=f"Task {task_id} is not in the read model")
            columns = [desc.name for desc in cur.description]
    logger.info("QUERY task task_id=%s", task_id)
    return {"message": "Single task read from read_store.task_read_model.", "task": dict(zip(columns, row))}


@app.get("/queries/projection")
def get_projection_checkpoint() -> dict[str, Any]:
    with psycopg.connect(READ_STORE_DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT projection_name, last_global_sequence, updated_at
                FROM projection_checkpoint
                ORDER BY projection_name;
                """
            )
            checkpoints = rows_as_dicts(cur)
    logger.info("QUERY projection checkpoints=%s", len(checkpoints))
    return {
        "message": "The checkpoint records how far the projector has read through domain_events.",
        "table": "read_store.projection_checkpoint",
        "checkpoints": checkpoints,
    }
