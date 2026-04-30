#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
helm repo add minio https://charts.min.io/ --force-update >/dev/null
helm repo update grafana minio >/dev/null

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f k8s/04-mailhog.yaml >/dev/null

helm upgrade --install alarik minio/minio \
  -n "$NAMESPACE" \
  -f monitoring/values-alarik.yaml \
  --wait --timeout 180s

kubectl run alarik-make-bucket \
  --namespace "$NAMESPACE" \
  --rm \
  -i \
  --restart=Never \
  --image=minio/mc:latest \
  --command -- sh -c '
    mc alias set local http://alarik-minio:9000 admin alarik123 >/dev/null &&
    mc mb -p local/loki >/dev/null || true
    mc mb -p local/mimir-blocks >/dev/null || true
    mc mb -p local/mimir-ruler >/dev/null || true
    mc mb -p local/mimir-alertmanager >/dev/null || true
    mc mb -p local/tempo-blocks >/dev/null || true
  '

helm upgrade --install loki grafana/loki \
  --version 6.33.0 \
  -n "$NAMESPACE" \
  -f monitoring/values-loki.yaml \
  --wait --timeout 240s

helm upgrade --install mimir grafana/mimir-distributed \
  --version 5.8.0 \
  -n "$NAMESPACE" \
  -f monitoring/values-mimir.yaml \
  --wait --timeout 240s

helm upgrade --install tempo grafana/tempo \
  -n "$NAMESPACE" \
  -f monitoring/values-tempo.yaml \
  --wait --timeout 300s

helm upgrade --install alloy grafana/alloy \
  -n "$NAMESPACE" \
  -f monitoring/values-alloy.yaml \
  --wait --timeout 180s

helm upgrade --install grafana grafana/grafana \
  -n "$NAMESPACE" \
  -f monitoring/values-grafana.yaml \
  --wait --timeout 180s
