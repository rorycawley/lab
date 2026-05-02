import hashlib
import os
from pathlib import Path

import psycopg


DATABASE_URL = os.environ["DATABASE_URL"]
MIGRATIONS_DIR = Path(os.environ.get("MIGRATIONS_DIR", "/migrator/migrations"))


def checksum(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main() -> None:
    files = sorted(MIGRATIONS_DIR.glob("V*.sql"))
    if not files:
        raise SystemExit(f"no migrations found in {MIGRATIONS_DIR}")

    with psycopg.connect(DATABASE_URL) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT current_user,
                       (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()) AS tls;
                """
            )
            current_user, tls = cur.fetchone()
            print(f"connected current_user={current_user} tls={tls}")
            if current_user != "migrator_user":
                raise SystemExit(f"expected migrator_user, got {current_user}")
            if tls is not True:
                raise SystemExit("expected TLS connection")

            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS app.schema_migrations (
                  version text PRIMARY KEY,
                  checksum text NOT NULL,
                  applied_by text NOT NULL DEFAULT current_user,
                  applied_at timestamptz NOT NULL DEFAULT now()
                );
                """
            )

            for path in files:
                version = path.name.split("__", 1)[0]
                sql = path.read_text(encoding="utf-8")
                digest = checksum(sql)
                cur.execute("SELECT checksum FROM app.schema_migrations WHERE version = %s;", (version,))
                existing = cur.fetchone()
                if existing:
                    if existing[0] != digest:
                        raise SystemExit(f"checksum mismatch for {path.name}")
                    print(f"skip {path.name}")
                    continue

                print(f"apply {path.name}")
                cur.execute(sql)
                cur.execute(
                    """
                    INSERT INTO app.schema_migrations(version, checksum)
                    VALUES (%s, %s);
                    """,
                    (version, digest),
                )

            conn.commit()

            try:
                cur.execute("CREATE ROLE migrator_should_not_create;")
            except psycopg.Error as exc:
                print(f"expected denial CREATE ROLE sqlstate={exc.sqlstate}")
                conn.rollback()
            else:
                raise SystemExit("migrator_user unexpectedly created a role")

    print("migrations complete")


if __name__ == "__main__":
    main()
