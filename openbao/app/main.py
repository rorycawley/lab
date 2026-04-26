import logging
import os
import sys
import threading
from typing import Any

import hvac
import psycopg
from fastapi import FastAPI, HTTPException


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("openbao-demo")

app = FastAPI(title="OpenBao + Postgres demo")

OPENBAO_ADDR = os.environ["OPENBAO_ADDR"]
OPENBAO_ROLE_ID = os.environ["OPENBAO_ROLE_ID"]
OPENBAO_SECRET_ID = os.environ["OPENBAO_SECRET_ID"]
OPENBAO_KV_MOUNT = os.environ.get("OPENBAO_KV_MOUNT", "kv")
OPENBAO_KV_PATH = os.environ.get("OPENBAO_KV_PATH", "postgres")
OPENBAO_DB_ROLE = os.environ.get("OPENBAO_DB_ROLE", "poc-role")
POSTGRES_HOST = os.environ["POSTGRES_HOST"]
POSTGRES_PORT = os.environ.get("POSTGRES_PORT", "5432")
POSTGRES_DB = os.environ.get("POSTGRES_DB", "pocdb")


_token_lock = threading.Lock()
_cached_token: str | None = None


def _approle_login() -> str:
    client = hvac.Client(url=OPENBAO_ADDR)
    result = client.auth.approle.login(
        role_id=OPENBAO_ROLE_ID, secret_id=OPENBAO_SECRET_ID
    )
    token = result["auth"]["client_token"]
    logger.info("APPROLE_LOGIN_OK ttl=%s", result["auth"].get("lease_duration"))
    return token


def get_client(force_refresh: bool = False) -> hvac.Client:
    global _cached_token
    with _token_lock:
        if force_refresh or _cached_token is None:
            _cached_token = _approle_login()
        return hvac.Client(url=OPENBAO_ADDR, token=_cached_token)


def with_openbao(fn):
    try:
        return fn(get_client())
    except hvac.exceptions.Forbidden:
        logger.warning("OPENBAO_TOKEN_REJECTED reauthenticating")
        return fn(get_client(force_refresh=True))


def read_static_creds() -> dict[str, str]:
    def call(client: hvac.Client) -> dict[str, Any]:
        return client.secrets.kv.v2.read_secret_version(
            mount_point=OPENBAO_KV_MOUNT, path=OPENBAO_KV_PATH, raise_on_deleted_version=True
        )

    secret = with_openbao(call)
    data = secret["data"]["data"]
    return {"username": data["username"], "password": data["password"]}


def read_dynamic_creds() -> dict[str, Any]:
    def call(client: hvac.Client) -> dict[str, Any]:
        return client.secrets.database.generate_credentials(name=OPENBAO_DB_ROLE)

    secret = with_openbao(call)
    return {
        "username": secret["data"]["username"],
        "password": secret["data"]["password"],
        "lease_id": secret["lease_id"],
        "lease_duration": secret["lease_duration"],
        "renewable": secret["renewable"],
    }


def query_one(username: str, password: str) -> dict[str, Any]:
    conninfo = (
        f"host={POSTGRES_HOST} port={POSTGRES_PORT} dbname={POSTGRES_DB} "
        f"user={username} password={password} sslmode=disable connect_timeout=5"
    )
    with psycopg.connect(conninfo) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user, now()")
            row = cur.fetchone()
            return {"current_user": row[0], "now": row[1].isoformat()}


@app.on_event("startup")
def startup() -> None:
    get_client()


@app.get("/")
def root() -> dict[str, Any]:
    return {
        "endpoints": [
            "/healthz",
            "/db-healthz",
            "/query/static",
            "/query/dynamic",
        ],
        "openbao_addr": OPENBAO_ADDR,
        "postgres_host": POSTGRES_HOST,
    }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/db-healthz")
def db_healthz() -> dict[str, str]:
    try:
        creds = read_static_creds()
        query_one(creds["username"], creds["password"])
        return {"status": "ok"}
    except Exception as exc:
        logger.exception("DB_HEALTHZ_FAILED")
        raise HTTPException(status_code=503, detail=str(exc))


@app.get("/query/static")
def query_static() -> dict[str, Any]:
    creds = read_static_creds()
    result = query_one(creds["username"], creds["password"])
    return {"source": "kv", "path": f"{OPENBAO_KV_MOUNT}/data/{OPENBAO_KV_PATH}", **result}


@app.get("/query/dynamic")
def query_dynamic() -> dict[str, Any]:
    creds = read_dynamic_creds()
    result = query_one(creds["username"], creds["password"])
    return {
        "source": "database",
        "path": f"database/creds/{OPENBAO_DB_ROLE}",
        "lease_id": creds["lease_id"],
        "lease_duration": creds["lease_duration"],
        "renewable": creds["renewable"],
        **result,
    }
