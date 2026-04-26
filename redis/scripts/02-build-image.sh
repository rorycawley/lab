#!/usr/bin/env bash
set -euo pipefail

echo "Building app image..."
docker build -t redis-demo-app:demo ./app

echo "Built:"
docker images redis-demo-app:demo --format '  {{.Repository}}:{{.Tag}} {{.ID}}'
