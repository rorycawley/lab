#!/usr/bin/env bash
set -euo pipefail

echo "Building Python app image..."
docker build -t registry-python-app:poc ./app

echo "Built image: registry-python-app:poc"
echo "If Rancher Desktop uses containerd rather than dockerd, use:"
echo "  nerdctl -n k8s.io build -t registry-python-app:poc ./app"
