#!/usr/bin/env bash
set -euo pipefail

# ── Generate + seal monitoring credentials ────────────────────────
# Run once per cluster (and again to rotate). Requires:
#   - kubectl pointed at the target cluster
#   - kubeseal CLI installed (brew install kubeseal)
#
# What it does:
#   1. Installs the Sealed Secrets controller into kube-system if missing
#   2. Generates fresh random passwords for Grafana admin and MinIO root
#   3. Seals them with the controller's public key
#   4. Writes encrypted SealedSecret YAMLs to monitoring/secrets/
#
# The output files are SAFE to commit — only your cluster's controller
# can decrypt them. Commit them, then run: bb monitoring-install

NAMESPACE=monitoring
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${DIR}/secrets"

command -v kubeseal >/dev/null 2>&1 || {
  echo "✗ kubeseal not found. Install it with: brew install kubeseal"
  exit 1
}

mkdir -p "${OUT_DIR}"

# ── 1. Install Sealed Secrets controller (idempotent) ─────────────
if ! kubectl get deployment sealed-secrets -n kube-system >/dev/null 2>&1; then
  echo "==> Installing Sealed Secrets controller..."
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null
  helm repo update >/dev/null
  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    -n kube-system \
    --set fullnameOverride=sealed-secrets \
    --wait --timeout 120s
else
  echo "==> Sealed Secrets controller already installed."
fi

# Make sure the namespace exists so the materialized Secrets land somewhere
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ── 2. Generate random passwords ──────────────────────────────────
# 32 url-safe chars from /dev/urandom
gen_pw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

GRAFANA_USER="admin"
GRAFANA_PASSWORD="$(gen_pw)"
MINIO_USER="minio"
MINIO_PASSWORD="$(gen_pw)"

# ── 3. Build plaintext Secret manifests, pipe through kubeseal ────
seal() {
  local name=$1
  local file=$2
  shift 2
  local args=()
  for kv in "$@"; do args+=(--from-literal="${kv}"); done
  kubectl create secret generic "${name}" \
    --namespace "${NAMESPACE}" \
    "${args[@]}" \
    --dry-run=client -o yaml \
  | kubeseal \
      --controller-namespace kube-system \
      --controller-name sealed-secrets \
      --format yaml \
  > "${file}"
  echo "✓ Wrote ${file}"
}

echo "==> Sealing grafana-admin-creds..."
seal grafana-admin-creds "${OUT_DIR}/grafana-admin-creds.sealedsecret.yaml" \
  "admin-user=${GRAFANA_USER}" \
  "admin-password=${GRAFANA_PASSWORD}"

echo "==> Sealing minio-root-creds..."
seal minio-root-creds "${OUT_DIR}/minio-root-creds.sealedsecret.yaml" \
  "rootUser=${MINIO_USER}" \
  "rootPassword=${MINIO_PASSWORD}"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Sealed secrets written to monitoring/secrets/"
echo ""
echo "  Next steps:"
echo "    1. git add monitoring/secrets/ && git commit"
echo "    2. bb monitoring-install"
echo ""
echo "  Generated credentials (save to your password manager NOW —"
echo "  they are not stored anywhere else in plaintext):"
echo ""
echo "    Grafana  ${GRAFANA_USER} / ${GRAFANA_PASSWORD}"
echo "    MinIO    ${MINIO_USER} / ${MINIO_PASSWORD}"
echo ""
echo "  If you are rotating: restart the affected pods to pick up new"
echo "  values:"
echo "    kubectl rollout restart -n monitoring deploy/grafana"
echo "    kubectl rollout restart -n monitoring statefulset/minio-mimir"
echo "    kubectl rollout restart -n monitoring deploy/mimir"
echo ""
echo "  Note: Grafana stores the admin user in its database on first"
echo "  boot. To reset an existing Grafana, delete its PVC or use:"
echo "    kubectl exec -n monitoring deploy/grafana -- \\"
echo "      grafana-cli admin reset-admin-password '<new-password>'"
echo "════════════════════════════════════════════════════════════════"
