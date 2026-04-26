#!/usr/bin/env bash
set -euo pipefail

echo "Starting Redis and RedisInsight via Docker Compose..."
docker compose up -d redis redisinsight

echo "Waiting for Redis..."
until docker compose exec -T redis redis-cli -a redispass --no-auth-warning PING >/dev/null 2>&1; do
  sleep 1
done

echo "Services are ready."
echo "  Redis:           localhost:6379   (password: redispass)"
echo "  RedisInsight:    http://localhost:5540"
