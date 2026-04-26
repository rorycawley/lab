#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak-pg-demo}"
REALM="${REALM:-poc}"
CLIENT_ID="${CLIENT_ID:-poc-app}"
SCOPE_NAME="${SCOPE_NAME:-pg-role}"
ROLE_CLAIM_NAME="${ROLE_CLAIM_NAME:-pg_role}"
ROLE_CLAIM_VALUE="${ROLE_CLAIM_VALUE:-pgreader}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# Run kcadm.sh inside the Keycloak container. Each invocation writes
# its login state to /opt/keycloak/.kcadm/, which persists for the
# lifetime of the container.
kcadm() {
  docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

# kcadm with --format csv --noquotes prints a header row and one
# value row. Pull the value off the bottom.
csv_value() {
  tail -n 1 | tr -d '\r'
}

echo "Logging in to Keycloak admin..."
kcadm config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$ADMIN_USER" \
  --password "$ADMIN_PASSWORD" >/dev/null

echo "Creating realm '$REALM' (idempotent)..."
if kcadm get "realms/$REALM" >/dev/null 2>&1; then
  echo "  realm already exists, skipping create"
else
  kcadm create realms -s "realm=$REALM" -s enabled=true >/dev/null
fi

echo "Creating client '$CLIENT_ID' (confidential, service-accounts) ..."
existing_client_uuid="$(kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" \
  --fields id --format csv --noquotes 2>/dev/null | csv_value || true)"

if [[ -n "${existing_client_uuid}" && "${existing_client_uuid}" != "id" ]]; then
  CLIENT_UUID="$existing_client_uuid"
  echo "  client already exists (uuid=$CLIENT_UUID)"
else
  kcadm create clients -r "$REALM" \
    -s "clientId=$CLIENT_ID" \
    -s enabled=true \
    -s publicClient=false \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s 'attributes."client.secret.creation.time"=0' >/dev/null
  CLIENT_UUID="$(kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" \
    --fields id --format csv --noquotes | csv_value)"
  echo "  created client uuid=$CLIENT_UUID"
fi

echo "Resetting client secret..."
kcadm create "clients/$CLIENT_UUID/client-secret" -r "$REALM" >/dev/null
CLIENT_SECRET="$(kcadm get "clients/$CLIENT_UUID/client-secret" -r "$REALM" \
  --fields value --format csv --noquotes | csv_value)"
if [[ -z "$CLIENT_SECRET" || "$CLIENT_SECRET" == "value" ]]; then
  echo "Failed to read client secret" >&2
  exit 1
fi

echo "Creating client scope '$SCOPE_NAME' with hardcoded '$ROLE_CLAIM_NAME' claim..."
# kcadm's `-q` filter is not honoured by /client-scopes, so we list
# all scopes and filter client-side on the name column.
find_scope_uuid() {
  kcadm get client-scopes -r "$REALM" --fields id,name --format csv --noquotes 2>/dev/null \
    | awk -F, -v want="$SCOPE_NAME" 'NR>1 && $2==want {print $1; exit}'
}
existing_scope_uuid="$(find_scope_uuid || true)"
if [[ -n "${existing_scope_uuid}" ]]; then
  SCOPE_UUID="$existing_scope_uuid"
  echo "  scope already exists (uuid=$SCOPE_UUID)"
else
  kcadm create client-scopes -r "$REALM" \
    -s "name=$SCOPE_NAME" \
    -s protocol=openid-connect >/dev/null
  SCOPE_UUID="$(find_scope_uuid)"
  if [[ -z "$SCOPE_UUID" ]]; then
    echo "Failed to find newly-created scope $SCOPE_NAME" >&2
    exit 1
  fi
  echo "  created scope uuid=$SCOPE_UUID"

  kcadm create "client-scopes/$SCOPE_UUID/protocol-mappers/models" -r "$REALM" \
    -s "name=${ROLE_CLAIM_NAME}-claim" \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-hardcoded-claim-mapper \
    -s "config.\"claim.name\"=$ROLE_CLAIM_NAME" \
    -s "config.\"claim.value\"=$ROLE_CLAIM_VALUE" \
    -s 'config."jsonType.label"=String' \
    -s 'config."id.token.claim"=false' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=false' >/dev/null
fi

echo "Attaching scope '$SCOPE_NAME' to client '$CLIENT_ID' as a default scope..."
kcadm update "clients/$CLIENT_UUID/default-client-scopes/$SCOPE_UUID" -r "$REALM" >/dev/null

echo "Ensuring namespace $NAMESPACE exists..."
kubectl apply -f k8s/00-namespace.yaml >/dev/null

echo "Writing Kubernetes secret 'keycloak-client' in namespace $NAMESPACE..."
kubectl create secret generic keycloak-client \
  --namespace "$NAMESPACE" \
  --from-literal=client_id="$CLIENT_ID" \
  --from-literal=client_secret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Keycloak bootstrap complete."
echo "  realm        : $REALM"
echo "  client_id    : $CLIENT_ID"
echo "  pg_role claim: $ROLE_CLAIM_VALUE"
echo "  k8s secret   : kubectl -n $NAMESPACE get secret keycloak-client"
