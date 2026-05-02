#!/usr/bin/env bash
set -euo pipefail

cat > "$PGDATA/pg_hba.conf" <<'HBA'
local   all             all                                     trust
hostnossl all           all             0.0.0.0/0               reject
hostnossl all           all             ::0/0                   reject
hostssl appdb           app_user        0.0.0.0/0               scram-sha-256 clientcert=verify-full
hostssl appdb           app_user        ::0/0                   scram-sha-256 clientcert=verify-full
hostssl appdb           migrator_user   0.0.0.0/0               scram-sha-256 clientcert=verify-full
hostssl appdb           migrator_user   ::0/0                   scram-sha-256 clientcert=verify-full
hostssl all             postgres        0.0.0.0/0               scram-sha-256
hostssl all             postgres        ::0/0                   scram-sha-256
hostssl all             all             0.0.0.0/0               reject
hostssl all             all             ::0/0                   reject
HBA

