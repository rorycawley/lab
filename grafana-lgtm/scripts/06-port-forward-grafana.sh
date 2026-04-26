#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

echo "Forwarding http://localhost:3000 to Grafana. Press Ctrl+C to stop."
kubectl port-forward -n "$NAMESPACE" service/grafana-lgtm 3000:3000
