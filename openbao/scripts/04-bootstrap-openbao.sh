#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-openbao-demo}"
ROOT_TOKEN="${BAO_DEV_ROOT_TOKEN_ID:-root}"
KV_MOUNT="${KV_MOUNT:-kv}"
KV_PATH="${KV_PATH:-postgres}"
DB_MOUNT="${DB_MOUNT:-database}"
DB_CONNECTION="${DB_CONNECTION:-postgres-pocdb}"
DB_ROLE="${DB_ROLE:-poc-role}"
APPROLE_ROLE="${APPROLE_ROLE:-poc-app}"
POLICY_NAME="${POLICY_NAME:-poc-app}"

# Run bao inside the openbao container (it talks to itself; shares network with postgres).
bao() {
  docker compose exec -T \
    -e BAO_ADDR=http://127.0.0.1:8200 \
    -e BAO_TOKEN="$ROOT_TOKEN" \
    openbao bao "$@"
}

echo "Mounting KV v2 at $KV_MOUNT/..."
bao secrets enable -path="$KV_MOUNT" -version=2 kv >/dev/null 2>&1 || true

echo "Writing static Postgres credentials to $KV_MOUNT/data/$KV_PATH..."
bao kv put "$KV_MOUNT/$KV_PATH" username=appuser password=apppass >/dev/null

echo "Mounting database secrets engine at $DB_MOUNT/..."
bao secrets enable -path="$DB_MOUNT" database >/dev/null 2>&1 || true

echo "Configuring database connection $DB_CONNECTION -> postgres:5432/pocdb..."
bao write "$DB_MOUNT/config/$DB_CONNECTION" \
  plugin_name=postgresql-database-plugin \
  allowed_roles="$DB_ROLE" \
  connection_url="postgresql://{{username}}:{{password}}@postgres:5432/pocdb?sslmode=disable" \
  username="vaultadmin" \
  password="vaultadminpass" >/dev/null

echo "Creating database role $DB_ROLE (TTL 1m, max 5m)..."
bao write "$DB_MOUNT/roles/$DB_ROLE" \
  db_name="$DB_CONNECTION" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT CONNECT ON DATABASE pocdb TO \"{{name}}\"; GRANT pg_read_all_data TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL PRIVILEGES ON DATABASE pocdb FROM \"{{name}}\"; REVOKE pg_read_all_data FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1m" \
  max_ttl="5m" >/dev/null

echo "Writing policy $POLICY_NAME..."
docker compose exec -T \
  -e BAO_ADDR=http://127.0.0.1:8200 \
  -e BAO_TOKEN="$ROOT_TOKEN" \
  openbao sh -c "cat > /tmp/$POLICY_NAME.hcl <<EOF
path \"$KV_MOUNT/data/$KV_PATH\" {
  capabilities = [\"read\"]
}
path \"$DB_MOUNT/creds/$DB_ROLE\" {
  capabilities = [\"read\"]
}
EOF
bao policy write $POLICY_NAME /tmp/$POLICY_NAME.hcl"

echo "Enabling AppRole auth..."
bao auth enable approle >/dev/null 2>&1 || true

echo "Creating AppRole $APPROLE_ROLE bound to policy $POLICY_NAME..."
bao write "auth/approle/role/$APPROLE_ROLE" \
  token_policies="$POLICY_NAME" \
  token_ttl=1h \
  token_max_ttl=4h >/dev/null

echo "Fetching role_id and secret_id..."
ROLE_ID="$(bao read -field=role_id "auth/approle/role/$APPROLE_ROLE/role-id" | tr -d '\r')"
SECRET_ID="$(bao write -field=secret_id -force "auth/approle/role/$APPROLE_ROLE/secret-id" | tr -d '\r')"

if [[ -z "$ROLE_ID" || -z "$SECRET_ID" ]]; then
  echo "Failed to obtain AppRole credentials" >&2
  exit 1
fi

echo "Ensuring namespace $NAMESPACE exists..."
kubectl apply -f k8s/00-namespace.yaml >/dev/null

echo "Writing Kubernetes secret openbao-approle in namespace $NAMESPACE..."
kubectl create secret generic openbao-approle \
  --namespace "$NAMESPACE" \
  --from-literal=role_id="$ROLE_ID" \
  --from-literal=secret_id="$SECRET_ID" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "OpenBao bootstrap complete."
echo "  AppRole role_id : $ROLE_ID"
echo "  Stored secret in: kubectl -n $NAMESPACE get secret openbao-approle"
