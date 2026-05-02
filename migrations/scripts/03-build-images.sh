#!/usr/bin/env bash
set -euo pipefail

echo "Building Python API image..."
docker build -t migrations-demo-api:demo app

echo "Building migration runner image..."
docker build -t migrations-demo-migrator:demo migrator

echo "Built images:"
docker image ls --filter reference='migrations-demo-*:demo'
