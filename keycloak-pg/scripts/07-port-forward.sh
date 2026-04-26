#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="keycloak-pg-demo"

echo "Forwarding http://localhost:8080 to the API service. Press Ctrl+C to stop."
kubectl port-forward -n "$NAMESPACE" service/keycloak-pg-demo-app 8080:8080
