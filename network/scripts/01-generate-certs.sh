#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${CERT_DIR:-generated/certs}"
mkdir -p "$CERT_DIR"

echo "Generating lab CA..."
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "$CERT_DIR/ca.key" \
  -out "$CERT_DIR/ca.crt" \
  -subj "/CN=network-zero-trust-demo-ca" >/dev/null 2>&1

make_cert() {
  local name="$1"
  local cn="$2"
  local san="$3"
  local usage="$4"
  local ext="$CERT_DIR/${name}.ext"

  cat > "$ext" <<EOF
subjectAltName = ${san}
extendedKeyUsage = ${usage}
keyUsage = digitalSignature, keyEncipherment
EOF

  openssl req -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/${name}.key" \
    -out "$CERT_DIR/${name}.csr" \
    -subj "/CN=${cn}" >/dev/null 2>&1

  openssl x509 -req -in "$CERT_DIR/${name}.csr" \
    -CA "$CERT_DIR/ca.crt" \
    -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERT_DIR/${name}.crt" \
    -days 30 \
    -sha256 \
    -extfile "$ext" >/dev/null 2>&1
}

make_cert \
  alpha \
  alpha.network-zero-trust.local \
  "DNS:alpha-app,DNS:alpha-app.network-alpha,DNS:alpha-app.network-alpha.svc,DNS:alpha-app.network-alpha.svc.cluster.local" \
  "serverAuth, clientAuth"

make_cert \
  beta \
  beta.network-zero-trust.local \
  "DNS:beta-app,DNS:beta-app.network-beta,DNS:beta-app.network-beta.svc,DNS:beta-app.network-beta.svc.cluster.local" \
  "serverAuth"

rm -f "$CERT_DIR"/*.csr "$CERT_DIR"/*.ext "$CERT_DIR"/*.srl

echo "Generated certs in $CERT_DIR"
echo "  CA:     $CERT_DIR/ca.crt"
echo "  alpha:  CN=alpha.network-zero-trust.local, serverAuth+clientAuth"
echo "  beta:   CN=beta.network-zero-trust.local, serverAuth"
