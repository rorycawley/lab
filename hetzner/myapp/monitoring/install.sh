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
SEALED_DIR="${DIR}/secrets"

echo "==> Adding Helm repos..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add minio   https://charts.min.io/
helm repo update

echo "==> Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── Apply sealed secrets ───────────────────────────────────────────
# Grafana, MinIO, and Mimir all read their credentials from K8s
# Secrets that the Sealed Secrets controller materializes from the
# encrypted YAMLs in monitoring/secrets/. Run `bb monitoring-seal-secrets`
# to (re)generate them.
if ! ls "${SEALED_DIR}"/*.sealedsecret.yaml >/dev/null 2>&1; then
  echo ""
  echo "✗ No sealed secrets found in ${SEALED_DIR}/"
  echo "  Run this once to generate and seal credentials:"
  echo "    bb monitoring-seal-secrets"
  exit 1
fi

if ! kubectl get deployment sealed-secrets -n kube-system >/dev/null 2>&1; then
  echo ""
  echo "✗ Sealed Secrets controller is not installed."
  echo "  Run: bb monitoring-seal-secrets   (it installs the controller too)"
  exit 1
fi

echo "==> Applying sealed secrets..."
kubectl apply -n "${NAMESPACE}" -f "${SEALED_DIR}/"

echo "==> Waiting for the controller to materialize Secrets..."
for name in grafana-admin-creds minio-root-creds; do
  for i in $(seq 1 30); do
    if kubectl get secret "${name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      echo "    ✓ ${name}"
      break
    fi
    [ "${i}" = "30" ] && { echo "    ✗ ${name} did not materialize in 30s"; exit 1; }
    sleep 1
  done
done

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
echo "    → http://localhost:3000"
echo "    Credentials are in your password manager (set when you ran"
echo "    bb monitoring-seal-secrets) or can be reset via:"
echo "      kubectl exec -n monitoring deploy/grafana -- \\"
echo "        grafana-cli admin reset-admin-password '<new>'"
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
