#!/usr/bin/env bash
set -euo pipefail

echo "Starting PostgreSQL and RabbitMQ via Docker Compose..."
docker compose up -d postgres rabbitmq

echo "Waiting for PostgreSQL..."
until docker compose exec -T postgres pg_isready -U tasks -d taskdb >/dev/null 2>&1; do
  sleep 1
done

echo "Waiting for RabbitMQ..."
until docker compose exec -T rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1; do
  sleep 1
done

echo "Services are ready."
echo "  PostgreSQL:   localhost:5432   (tasks/tasks, db=taskdb)"
echo "  RabbitMQ:     localhost:5672   (tasks/tasks)"
echo "  RabbitMQ UI:  http://localhost:15672"
