#!/usr/bin/env bash
set -euo pipefail

echo "Building the OpenBao demo Python API image..."
docker build -t openbao-demo-app:demo app
