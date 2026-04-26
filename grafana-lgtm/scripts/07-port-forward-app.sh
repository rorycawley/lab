#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

echo "Forwarding http://localhost:8080 to the Python app. Press Ctrl+C to stop."
kubectl port-forward -n "$NAMESPACE" service/otel-demo-app 8080:8080
