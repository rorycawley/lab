#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak-oidc-demo}"
REALM="${REALM:-poc}"
CLIENT_ID="${CLIENT_ID:-bff}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# The two seeded users. Passwords match usernames for the POC; the
# smoke test uses these directly.
USERS=("alice|alice@example.com|Alice|Anderson|alice"
       "bob|bob@example.com|Bob|Brown|bob")

# Run kcadm.sh inside the Keycloak container.
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

echo "Creating client '$CLIENT_ID' (confidential, auth-code + PKCE) ..."
existing_client_uuid="$(kcadm get clients -r "$REALM" -q "clientId=$CLIENT_ID" \
  --fields id --format csv --noquotes 2>/dev/null | csv_value || true)"

if [[ -n "${existing_client_uuid}" && "${existing_client_uuid}" != "id" ]]; then
  CLIENT_UUID="$existing_client_uuid"
  echo "  client already exists (uuid=$CLIENT_UUID); updating..."
  kcadm update "clients/$CLIENT_UUID" -r "$REALM" \
    -s 'redirectUris=["http://localhost:8080/callback"]' \
    -s 'webOrigins=["http://localhost:8080"]' \
    -s 'attributes."post.logout.redirect.uris"="http://localhost:8080/"' \
    -s 'attributes."pkce.code.challenge.method"="S256"' \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s publicClient=false >/dev/null
else
  kcadm create clients -r "$REALM" \
    -s "clientId=$CLIENT_ID" \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s 'redirectUris=["http://localhost:8080/callback"]' \
    -s 'webOrigins=["http://localhost:8080"]' \
    -s 'attributes."post.logout.redirect.uris"="http://localhost:8080/"' \
    -s 'attributes."pkce.code.challenge.method"="S256"' >/dev/null
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

echo "Seeding users..."
for entry in "${USERS[@]}"; do
  IFS='|' read -r username email first last password <<<"$entry"
  existing_user_uuid="$(kcadm get users -r "$REALM" -q "username=$username" \
    --fields id --format csv --noquotes 2>/dev/null | csv_value || true)"
  if [[ -n "${existing_user_uuid}" && "${existing_user_uuid}" != "id" ]]; then
    echo "  user $username already exists (uuid=$existing_user_uuid)"
    USER_UUID="$existing_user_uuid"
  else
    kcadm create users -r "$REALM" \
      -s "username=$username" \
      -s "email=$email" \
      -s "firstName=$first" \
      -s "lastName=$last" \
      -s emailVerified=true \
      -s enabled=true >/dev/null
    USER_UUID="$(kcadm get users -r "$REALM" -q "username=$username" \
      --fields id --format csv --noquotes | csv_value)"
    echo "  created user $username (uuid=$USER_UUID)"
  fi
  kcadm set-password -r "$REALM" --userid "$USER_UUID" --new-password "$password" \
    >/dev/null
done

echo "Ensuring namespace $NAMESPACE exists..."
kubectl apply -f k8s/00-namespace.yaml >/dev/null

echo "Writing Kubernetes secret 'oidc-client' in namespace $NAMESPACE..."
kubectl create secret generic oidc-client \
  --namespace "$NAMESPACE" \
  --from-literal=client_id="$CLIENT_ID" \
  --from-literal=client_secret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Keycloak bootstrap complete."
echo "  realm        : $REALM"
echo "  client_id    : $CLIENT_ID"
echo "  users        : alice / alice, bob / bob"
echo "  k8s secret   : kubectl -n $NAMESPACE get secret oidc-client"
