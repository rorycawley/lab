#!/usr/bin/env bash
set -euo pipefail

docker build -t python-postgres-vault-demo:phase8 ./app

echo "Phase 8 Python app image built."

