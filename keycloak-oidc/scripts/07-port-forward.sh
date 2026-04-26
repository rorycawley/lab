#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="keycloak-oidc-demo"

echo "Forwarding http://localhost:8080 to the BFF service. Press Ctrl+C to stop."
kubectl port-forward -n "$NAMESPACE" service/keycloak-oidc-demo-app 8080:8080
