#!/usr/bin/env bash
set -euo pipefail

# ── Install full Grafana LGTM stack into the monitoring namespace ──
# Usage: ./monitoring/install.sh
# Or:    bb monitoring-install

NAMESPACE=monitoring
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Adding Helm repos..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add minio   https://charts.min.io/
helm repo update

echo "==> Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> [1/6] Installing MinIO (object storage)..."
helm upgrade --install minio minio/minio \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-minio.yaml" \
  --wait --timeout 120s

echo ""
echo "==> [2/6] Installing Mimir (metrics)..."
helm upgrade --install mimir grafana/mimir-distributed \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-mimir.yaml" \
  --wait --timeout 180s

echo ""
echo "==> [3/6] Installing Loki (logs)..."
helm upgrade --install loki grafana/loki \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-loki.yaml" \
  --wait --timeout 180s

echo ""
echo "==> [4/6] Installing Tempo (traces)..."
helm upgrade --install tempo grafana/tempo \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-tempo.yaml" \
  --wait --timeout 180s

echo ""
echo "==> [5/6] Installing Alloy (collection agent)..."
helm upgrade --install alloy grafana/alloy \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-alloy.yaml" \
  --wait --timeout 120s

echo ""
echo "==> [6/6] Installing Grafana (dashboards)..."
helm upgrade --install grafana grafana/grafana \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-grafana.yaml" \
  --wait --timeout 120s

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  LGTM stack installed!"
echo ""
echo "  Access Grafana:"
echo "    kubectl port-forward -n monitoring svc/grafana 3000:80"
echo "    → http://localhost:3000  (admin / admin-change-me)"
echo ""
echo "  Datasources pre-configured:"
echo "    • Mimir  → metrics (Prometheus-compatible)"
echo "    • Loki   → logs"
echo "    • Tempo  → traces"
echo ""
echo "  Verify all pods:"
echo "    kubectl get pods -n monitoring"
echo "════════════════════════════════════════════════════════════════"
