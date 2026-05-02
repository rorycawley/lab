#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-network-zero-trust-app:demo}"

echo "Building app image..."
docker build -t "$IMAGE" ./app

echo "Built:"
docker images "$IMAGE" --format '  {{.Repository}}:{{.Tag}} {{.ID}}'
