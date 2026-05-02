#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-network-zero-trust-app:demo}"

echo "Deploying apps and network policies..."
kubectl apply -f k8s/10-alpha.yaml
kubectl apply -f k8s/20-beta.yaml
kubectl apply -f k8s/30-network-policies.yaml

echo "Using image $IMAGE..."
kubectl -n network-alpha set image deployment/alpha-app app="$IMAGE"
kubectl -n network-beta set image deployment/beta-app app="$IMAGE"

echo "Waiting for deployments to roll out..."
kubectl -n network-alpha rollout status deployment/alpha-app --timeout=120s
kubectl -n network-beta rollout status deployment/beta-app --timeout=120s
