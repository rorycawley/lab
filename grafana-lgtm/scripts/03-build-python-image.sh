#!/usr/bin/env bash
set -euo pipefail

echo "Building otel-demo-app image..."
docker build -t otel-demo-app:demo app

echo "Building payment-service image..."
docker build -t payment-service:demo payment-service
