import os
import sys
from typing import Any

import psycopg
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


DATABASE_URL = os.environ["DATABASE_URL"]

app = FastAPI(title="Migration permissions demo")


class TodoIn(BaseModel):
    title: str = Field(..., min_length=1)


def query_one(sql: str, params: tuple[Any, ...] = ()) -> tuple[Any, ...] | None:
    with psycopg.connect(DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchone()


def query_all(sql: str, params: tuple[Any, ...] = ()) -> list[tuple[Any, ...]]:
    with psycopg.connect(DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/db-healthz")
def db_healthz() -> dict[str, Any]:
    row = query_one(
        """
        SELECT current_user,
               current_database(),
               (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()) AS tls;
        """
    )
    assert row is not None
    return {"status": "ok", "current_user": row[0], "database": row[1], "tls": row[2]}


@app.get("/todos")
def list_todos() -> list[dict[str, Any]]:
    rows = query_all("SELECT id, title, created_by FROM app.todos ORDER BY id;")
    return [{"id": row[0], "title": row[1], "created_by": row[2]} for row in rows]


@app.post("/todos", status_code=201)
def create_todo(todo: TodoIn) -> dict[str, Any]:
    row = query_one(
        """
        INSERT INTO app.todos(title, created_by)
        VALUES (%s, current_user)
        RETURNING id, title, created_by;
        """,
        (todo.title,),
    )
    assert row is not None
    return {"id": row[0], "title": row[1], "created_by": row[2]}


@app.post("/prove/app-cannot-ddl")
def prove_app_cannot_ddl() -> dict[str, Any]:
    try:
        query_one("CREATE TABLE app.app_should_not_create(id bigint);")
    except psycopg.Error as exc:
        return {
            "status": "denied-as-expected",
            "current_user": "app_user",
            "sqlstate": exc.sqlstate,
            "error": str(exc).splitlines()[0],
        }
    raise HTTPException(status_code=500, detail="app_user unexpectedly created a table")


@app.get("/")
def root() -> dict[str, Any]:
    return {
        "name": "Migration permissions demo",
        "pid": os.getpid(),
        "python": sys.version.split()[0],
        "endpoints": ["/healthz", "/db-healthz", "/todos", "/prove/app-cannot-ddl"],
    }

