#!/usr/bin/env bash
set -euo pipefail

echo "Applying namespaces..."
kubectl apply -f k8s/00-namespaces.yaml
