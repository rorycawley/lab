#!/usr/bin/env bash
set -euo pipefail

echo "Building the single-file OpenTelemetry Python API image..."
docker build -t otel-demo-app:demo app
