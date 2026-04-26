#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

echo "Kubernetes resources:"
kubectl get all -n "$NAMESPACE"

echo
echo "Workload images:"
kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'

echo
echo "Grafana health through an in-cluster curl pod:"
kubectl run grafana-health-check \
  --namespace "$NAMESPACE" \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'curl -fsS http://grafana-lgtm:3000/api/health'

echo
echo "App health through an in-cluster curl pod:"
kubectl run app-health-check \
  --namespace "$NAMESPACE" \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'curl -fsS http://otel-demo-app:8080/healthz'
