#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${CERT_DIR:-generated/certs}"

for file in ca.crt alpha.crt alpha.key beta.crt beta.key; do
  if [[ ! -f "$CERT_DIR/$file" ]]; then
    echo "Missing $CERT_DIR/$file. Run make tls first." >&2
    exit 1
  fi
done

echo "Applying TLS secrets..."
kubectl -n network-alpha create secret generic alpha-tls \
  --from-file=tls.crt="$CERT_DIR/alpha.crt" \
  --from-file=tls.key="$CERT_DIR/alpha.key" \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n network-beta create secret generic beta-tls \
  --from-file=tls.crt="$CERT_DIR/beta.crt" \
  --from-file=tls.key="$CERT_DIR/beta.key" \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n network-alpha get deployment alpha-app >/dev/null 2>&1; then
  echo "Restarting alpha-app so it reloads updated TLS material..."
  kubectl -n network-alpha rollout restart deployment/alpha-app
fi

if kubectl -n network-beta get deployment beta-app >/dev/null 2>&1; then
  echo "Restarting beta-app so it reloads updated TLS material..."
  kubectl -n network-beta rollout restart deployment/beta-app
fi
