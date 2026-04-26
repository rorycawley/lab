#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="rabbitmq-demo"

echo "Deploying publisher and subscriber..."
kubectl apply -f k8s/03-publisher-deployment.yaml
kubectl apply -f k8s/04-publisher-service.yaml
kubectl apply -f k8s/05-subscriber-deployment.yaml
kubectl apply -f k8s/06-subscriber-service.yaml

kubectl -n "$NAMESPACE" rollout restart deployment/publisher
kubectl -n "$NAMESPACE" rollout restart deployment/subscriber

kubectl -n "$NAMESPACE" rollout status deployment/publisher --timeout=180s
kubectl -n "$NAMESPACE" rollout status deployment/subscriber --timeout=180s
