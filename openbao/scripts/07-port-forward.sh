#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="openbao-demo"

echo "Forwarding http://localhost:8080 to the API service. Press Ctrl+C to stop."
kubectl port-forward -n "$NAMESPACE" service/openbao-demo-app 8080:8080
