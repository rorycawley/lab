#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="redis-demo"

echo "Forwarding localhost:8080 -> redis-demo-app:8080"
echo "Press Ctrl+C to stop."

kubectl -n "$NAMESPACE" port-forward service/redis-demo-app 8080:8080
