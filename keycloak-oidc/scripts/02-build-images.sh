#!/usr/bin/env bash
set -euo pipefail

echo "Building the OIDC BFF demo app image..."
docker build -t keycloak-oidc-demo-app:demo app
