#!/usr/bin/env bash
set -euo pipefail

echo "Building publisher image..."
docker build -t rabbitmq-demo-publisher:demo ./app/publisher

echo "Building subscriber image..."
docker build -t rabbitmq-demo-subscriber:demo ./app/subscriber

echo "Built:"
docker images rabbitmq-demo-publisher:demo --format '  {{.Repository}}:{{.Tag}} {{.ID}}'
docker images rabbitmq-demo-subscriber:demo --format '  {{.Repository}}:{{.Tag}} {{.ID}}'
