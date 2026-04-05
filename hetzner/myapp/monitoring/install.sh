#!/usr/bin/env bash
set -euo pipefail

# ── Install full Grafana LGTM stack into the monitoring namespace ──
# Usage: ./monitoring/install.sh
# Or:    bb monitoring-install
#
# Install order matters:
#   1. Loki first     — its built-in MinIO claims the "minio-sa" ServiceAccount
#   2. MinIO (Mimir)  — uses a different SA name "mimir-minio-sa" to avoid clash
#   3. Mimir          — points to the standalone MinIO
#   4. Tempo          — uses local filesystem (no MinIO needed)
#   5. Alloy          — collection agent
#   6. Grafana        — dashboards (no ingress, use bb grafana to port-forward)

NAMESPACE=monitoring
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Adding Helm repos..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add minio   https://charts.min.io/
helm repo update

echo "==> Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> [1/6] Installing Loki (logs)..."
echo "    Pinned to chart version 6.33.0 (newer versions have breaking changes)"
echo "    Loki's built-in MinIO claims the 'minio-sa' ServiceAccount"
helm upgrade --install loki grafana/loki \
  --version 6.33.0 \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-loki.yaml" \
  --wait --timeout 180s

echo ""
echo "==> [2/6] Installing MinIO (object storage for Mimir)..."
echo "    Uses custom SA name 'mimir-minio-sa' to avoid clash with Loki's MinIO"
helm upgrade --install minio-mimir minio/minio \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-minio.yaml" \
  --set serviceAccount.name=mimir-minio-sa \
  --wait --timeout 120s

echo ""
echo "==> [3/6] Installing Mimir (metrics)..."
helm upgrade --install mimir grafana/mimir-distributed \
  -n "${NAMESPACE}" \
  -f "${DIR}/values-mimir.yaml" \
  --wait --timeout 180s

echo ""
echo "==> [4/6] Installing Tempo (traces)..."
echo "    Pinned to chart version 1.10.3 (uses local filesystem storage)"
helm upgrade --install tempo grafana/tempo \
  --version 1.10.3 \
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
echo "    bb grafana"
echo "    → http://localhost:3000  (admin / admin-change-me)"
echo ""
echo "  Datasources pre-configured:"
echo "    • Mimir  → metrics (Prometheus-compatible)"
echo "    • Loki   → logs"
echo "    • Tempo  → traces"
echo ""
echo "  Verify all pods:"
echo "    bb monitoring-status"
echo ""
echo "  To enable OTel tracing in your app:"
echo "    Edit helm/myapp/values-prod.yaml → otel.enabled: \"true\""
echo "    bb helm-prod"
echo "════════════════════════════════════════════════════════════════"
