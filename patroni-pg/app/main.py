import os
import threading
import uuid
from contextlib import contextmanager

import psycopg
from psycopg_pool import ConnectionPool
from flask import Flask, jsonify, request


DB_HOST = os.environ.get("DB_HOST", "host.rancher-desktop.internal")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "demo_registry")
DB_CREDS_FILE = os.environ.get("DB_CREDS_FILE", "/vault/secrets/db-creds")
DB_SSLMODE = os.environ.get("DB_SSLMODE", "disable")
DB_SSLROOTCERT = os.environ.get("DB_SSLROOTCERT")
DB_POOL_MIN_SIZE = int(os.environ.get("DB_POOL_MIN_SIZE", "1"))
DB_POOL_MAX_SIZE = int(os.environ.get("DB_POOL_MAX_SIZE", "4"))
DB_POOL_MAX_LIFETIME = int(os.environ.get("DB_POOL_MAX_LIFETIME", "600"))

app = Flask(__name__)
pool_lock = threading.Lock()
pool = None
pool_creds = None
pool_generation = 0


def read_db_creds():
    values = {}
    with open(DB_CREDS_FILE, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key] = value

    username = values.get("DB_USERNAME")
    password = values.get("DB_PASSWORD")
    if not username or not password:
        raise RuntimeError(f"{DB_CREDS_FILE} must contain DB_USERNAME and DB_PASSWORD")

    return username, password


def conninfo(username, password):
    parts = [
        f"host={DB_HOST} "
        f"port={DB_PORT}",
        f"dbname={DB_NAME}",
        f"user={username}",
        f"password={password}",
        "connect_timeout=5",
        f"sslmode={DB_SSLMODE}",
    ]
    if DB_SSLROOTCERT:
        parts.append(f"sslrootcert={DB_SSLROOTCERT}")
    return " ".join(parts)


def close_pool(current_pool):
    if current_pool is not None:
        current_pool.close(timeout=5)


def ensure_pool(force=False):
    global pool, pool_creds, pool_generation

    creds = read_db_creds()
    with pool_lock:
        if force or pool is None or pool_creds != creds:
            old_pool = pool
            pool = ConnectionPool(
                conninfo=conninfo(*creds),
                min_size=DB_POOL_MIN_SIZE,
                max_size=DB_POOL_MAX_SIZE,
                max_lifetime=DB_POOL_MAX_LIFETIME,
                check=ConnectionPool.check_connection,
                open=True,
            )
            pool_creds = creds
            pool_generation += 1
            close_pool(old_pool)
        return pool


@contextmanager
def db_connection():
    current_pool = ensure_pool()
    with current_pool.connection() as conn:
        yield conn


def pool_status_payload():
    username, _ = read_db_creds()
    current_pool = ensure_pool()
    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user")
            current_user = cur.fetchone()[0]

    return {
        "pool_enabled": True,
        "pool_generation": pool_generation,
        "pool_min_size": DB_POOL_MIN_SIZE,
        "pool_max_size": DB_POOL_MAX_SIZE,
        "pool_max_lifetime_seconds": DB_POOL_MAX_LIFETIME,
        "sslmode": DB_SSLMODE,
        "rendered_username": username,
        "current_user": current_user,
        "pool_size": current_pool.get_stats().get("pool_size"),
        "pool_available": current_pool.get_stats().get("pool_available"),
    }


def company_row(row):
    return {
        "id": str(row[0]),
        "name": row[1],
        "status": row[2],
        "created_at": row[3].isoformat(),
    }


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok"})


@app.get("/db-identity")
def db_identity():
    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user")
            user = cur.fetchone()[0]
    return jsonify({"current_user": user})


@app.get("/pool/status")
def pool_status():
    return jsonify(pool_status_payload())


@app.post("/pool/reload")
def pool_reload():
    ensure_pool(force=True)
    return jsonify(pool_status_payload())


@app.post("/companies")
def create_company():
    payload = request.get_json(silent=True) or {}
    company_id = payload.get("id") or str(uuid.uuid4())
    name = payload.get("name") or "Acme Ltd"
    status = payload.get("status") or "active"

    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO registry.company (id, name, status)
                VALUES (%s, %s, %s)
                ON CONFLICT (id) DO UPDATE
                SET name = EXCLUDED.name,
                    status = EXCLUDED.status
                RETURNING id, name, status, created_at
                """,
                (company_id, name, status),
            )
            row = cur.fetchone()
        conn.commit()

    return jsonify(company_row(row)), 201


@app.get("/companies/<company_id>")
def get_company(company_id):
    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, name, status, created_at
                FROM registry.company
                WHERE id = %s
                """,
                (company_id,),
            )
            row = cur.fetchone()

    if row is None:
        return jsonify({"error": "not_found"}), 404
    return jsonify(company_row(row))


@app.patch("/companies/<company_id>")
def update_company(company_id):
    payload = request.get_json(silent=True) or {}
    status = payload.get("status") or "inactive"

    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE registry.company
                SET status = %s
                WHERE id = %s
                RETURNING id, name, status, created_at
                """,
                (status, company_id),
            )
            row = cur.fetchone()
        conn.commit()

    if row is None:
        return jsonify({"error": "not_found"}), 404
    return jsonify(company_row(row))


@app.delete("/companies/<company_id>")
def delete_company(company_id):
    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM registry.company WHERE id = %s RETURNING id", (company_id,))
            row = cur.fetchone()
        conn.commit()

    if row is None:
        return jsonify({"deleted": False}), 404
    return jsonify({"deleted": True, "id": str(row[0])})


@app.post("/security/prove-denied")
def prove_denied():
    checks = {
        "drop_table": "DROP TABLE registry.company",
        "create_role": "CREATE ROLE attacker",
    }
    results = {}

    with db_connection() as conn:
        for name, sql in checks.items():
            try:
                with conn.cursor() as cur:
                    cur.execute(sql)
                conn.commit()
                results[name] = {"allowed": True}
            except Exception as exc:
                conn.rollback()
                results[name] = {
                    "allowed": False,
                    "error": exc.__class__.__name__,
                }

    status = 200 if all(not item["allowed"] for item in results.values()) else 500
    return jsonify(results), status


@app.post("/security/evidence")
def security_evidence():
    company_id = "00000000-0000-0000-0000-000000000009"
    evidence = {
        "credential_file": {
            "path": DB_CREDS_FILE,
            "exists": os.path.exists(DB_CREDS_FILE),
            "password_source": "vault_agent_rendered_file",
        },
        "database": {},
        "allowed": {},
        "denied": {},
    }

    username, _ = read_db_creds()
    evidence["credential_file"]["username_prefix"] = username[:24]

    with db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user")
            evidence["database"]["current_user"] = cur.fetchone()[0]

            cur.execute(
                """
                INSERT INTO registry.company (id, name, status)
                VALUES (%s, %s, %s)
                ON CONFLICT (id) DO UPDATE
                SET name = EXCLUDED.name,
                    status = EXCLUDED.status
                RETURNING id
                """,
                (company_id, "Phase 9 Evidence Ltd", "active"),
            )
            evidence["allowed"]["insert"] = str(cur.fetchone()[0]) == company_id

            cur.execute("SELECT status FROM registry.company WHERE id = %s", (company_id,))
            evidence["allowed"]["select"] = cur.fetchone()[0] == "active"

            cur.execute(
                "UPDATE registry.company SET status = 'inactive' WHERE id = %s RETURNING status",
                (company_id,),
            )
            evidence["allowed"]["update"] = cur.fetchone()[0] == "inactive"

            cur.execute("DELETE FROM registry.company WHERE id = %s RETURNING id", (company_id,))
            evidence["allowed"]["delete"] = str(cur.fetchone()[0]) == company_id

        conn.commit()

        denied_checks = {
            "drop_table": "DROP TABLE registry.company",
            "create_role": "CREATE ROLE attacker",
        }
        for name, sql in denied_checks.items():
            try:
                with conn.cursor() as cur:
                    cur.execute(sql)
                conn.commit()
                evidence["denied"][name] = {"allowed": True}
            except Exception as exc:
                conn.rollback()
                evidence["denied"][name] = {
                    "allowed": False,
                    "error": exc.__class__.__name__,
                }

    evidence["summary"] = {
        "all_allowed_operations_succeeded": all(evidence["allowed"].values()),
        "all_forbidden_operations_denied": all(
            not item["allowed"] for item in evidence["denied"].values()
        ),
    }
    status = 200 if all(evidence["summary"].values()) else 500
    return jsonify(evidence), status


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
