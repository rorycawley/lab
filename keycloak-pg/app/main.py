import logging
import os
import sys
from typing import Any

import psycopg
import requests
from fastapi import FastAPI, HTTPException


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("keycloak-pg-demo")

app = FastAPI(title="Keycloak + Postgres demo")

KEYCLOAK_TOKEN_URL = os.environ["KEYCLOAK_TOKEN_URL"]
KEYCLOAK_CLIENT_ID = os.environ["KEYCLOAK_CLIENT_ID"]
KEYCLOAK_CLIENT_SECRET = os.environ["KEYCLOAK_CLIENT_SECRET"]
PG_PROXY_HOST = os.environ["PG_PROXY_HOST"]
PG_PROXY_PORT = os.environ.get("PG_PROXY_PORT", "6432")
PG_DATABASE = os.environ.get("PG_DATABASE", "pocdb")
PG_USER_FIELD = os.environ.get("PG_USER_FIELD", "poc-app")


def fetch_token() -> dict[str, Any]:
    resp = requests.post(
        KEYCLOAK_TOKEN_URL,
        data={
            "grant_type": "client_credentials",
            "client_id": KEYCLOAK_CLIENT_ID,
            "client_secret": KEYCLOAK_CLIENT_SECRET,
        },
        timeout=5,
    )
    resp.raise_for_status()
    body = resp.json()
    logger.info("TOKEN_FETCHED expires_in=%s", body.get("expires_in"))
    return body


def query_with_token(token: str) -> dict[str, Any]:
    conninfo = (
        f"host={PG_PROXY_HOST} port={PG_PROXY_PORT} dbname={PG_DATABASE} "
        f"user={PG_USER_FIELD} password={token} sslmode=disable connect_timeout=5"
    )
    with psycopg.connect(conninfo) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT session_user, current_user, now(), "
                "(SELECT text FROM messages ORDER BY id LIMIT 1)"
            )
            row = cur.fetchone()
            return {
                "session_user": row[0],
                "current_user": row[1],
                "now": row[2].isoformat(),
                "message": row[3],
            }


@app.get("/")
def root() -> dict[str, Any]:
    return {
        "endpoints": ["/healthz", "/query", "/query/bad-token"],
        "keycloak_token_url": KEYCLOAK_TOKEN_URL,
        "pg_proxy": f"{PG_PROXY_HOST}:{PG_PROXY_PORT}",
    }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/query")
def query() -> dict[str, Any]:
    """
    Happy path: fetch a real JWT from Keycloak, hand it to the PG
    proxy as the password, run a small SELECT through the resulting
    session.
    """
    try:
        token_body = fetch_token()
    except Exception as exc:
        logger.exception("TOKEN_FETCH_FAILED")
        raise HTTPException(status_code=502, detail=f"keycloak token fetch failed: {exc}")

    try:
        result = query_with_token(token_body["access_token"])
    except Exception as exc:
        logger.exception("PG_QUERY_FAILED")
        raise HTTPException(status_code=502, detail=f"postgres query failed: {exc}")

    return {
        "source": "keycloak-jwt",
        "token_expires_in": token_body.get("expires_in"),
        **result,
    }


@app.get("/query/bad-token")
def query_bad_token() -> dict[str, Any]:
    """
    Negative path: hand the proxy a syntactically-valid-looking but
    unsigned-by-Keycloak JWT. Proves the proxy actually validates
    rather than just stripping the token.
    """
    forged = (
        "eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJmYWtlIn0."
        "eyJzdWIiOiJhdHRhY2tlciIsImF6cCI6InBvYy1hcHAiLCJwZ19yb2xlIjoicGdyZWFkZXIiLCJpc3MiOiJodHRwOi8vYW55d2hlcmUiLCJleHAiOjk5OTk5OTk5OTksImlhdCI6MX0."
        "AAAA"
    )
    try:
        query_with_token(forged)
    except Exception as exc:
        return {"rejected": True, "error": str(exc)}
    raise HTTPException(status_code=500, detail="forged token was accepted; proxy is broken")
