#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

echo "Applying namespace and Grafana provisioning ConfigMaps..."
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-grafana-lgtm-configmaps.yaml

echo "Creating Grafana dashboard ConfigMap from k8s/grafana-provisioning/dashboards/..."
kubectl create configmap grafana-lgtm-dashboards \
  --namespace "$NAMESPACE" \
  --from-file=k8s/grafana-provisioning/dashboards \
  --dry-run=client \
  -o yaml | kubectl apply -f -
