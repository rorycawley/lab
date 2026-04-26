#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="event-sourcing-demo"

echo "Forwarding http://localhost:8080 to the API service. Press Ctrl+C to stop."
kubectl port-forward -n "$NAMESPACE" service/task-event-sourcing-api 8080:8080
