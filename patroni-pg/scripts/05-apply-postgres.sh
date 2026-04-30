#!/usr/bin/env bash
set -euo pipefail

random_password() {
  openssl rand -hex 24
}

mkdir -p .runtime

if [[ ! -f .runtime/postgres.env ]]; then
  {
    printf 'POSTGRES_PASSWORD=%s\n' "$(random_password)"
    printf 'PHASE2_APP_PASSWORD=%s\n' "$(random_password)"
    printf 'PHASE2_MIGRATION_PASSWORD=%s\n' "$(random_password)"
  } > .runtime/postgres.env
  chmod 0600 .runtime/postgres.env
fi

set -a
source .runtime/postgres.env
set +a

docker compose --env-file .runtime/postgres.env up -d postgres

for _ in {1..60}; do
  if docker compose --env-file .runtime/postgres.env exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
    echo "Phase 2 PostgreSQL foundation applied."
    exit 0
  fi
  sleep 2
done

echo "error: PostgreSQL did not become ready"
exit 1
