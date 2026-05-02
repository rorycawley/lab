#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${CERT_DIR:-generated/certs}"
mkdir -p "$CERT_DIR"

echo "Generating demo CA and PostgreSQL certificates..."

openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "$CERT_DIR/ca.key" \
  -out "$CERT_DIR/ca.crt" \
  -subj "/CN=migrations-demo-ca" >/dev/null 2>&1

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
  postgres \
  external-pg \
  "DNS:external-pg,DNS:external-pg.migrations-demo,DNS:external-pg.migrations-demo.svc,DNS:external-pg.migrations-demo.svc.cluster.local,DNS:host.rancher-desktop.internal,DNS:localhost,IP:127.0.0.1" \
  "serverAuth"

make_cert \
  app \
  app_user \
  "DNS:app_user" \
  "clientAuth"

make_cert \
  migrator \
  migrator_user \
  "DNS:migrator_user" \
  "clientAuth"

chmod 0600 "$CERT_DIR"/*.key
rm -f "$CERT_DIR"/*.csr "$CERT_DIR"/*.ext "$CERT_DIR"/*.srl

echo "Generated certificates in $CERT_DIR"
echo "  CA:       $CERT_DIR/ca.crt"
echo "  server:   CN=external-pg"
echo "  app:      CN=app_user"
echo "  migrator: CN=migrator_user"

