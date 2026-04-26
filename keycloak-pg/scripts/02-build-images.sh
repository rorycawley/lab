#!/usr/bin/env bash
set -euo pipefail

echo "Building the Keycloak demo Python API image..."
docker build -t keycloak-pg-demo-app:demo app

echo "Building the PG-JWT proxy image (also used by Compose)..."
docker build -t keycloak-pg-demo-proxy:demo proxy
