#!/usr/bin/env bash
set -euo pipefail

echo "Building the single-file Python API image..."
docker build -t task-event-sourcing-api:demo app
