#!/usr/bin/env bash
set -euo pipefail

APP_URL="${APP_URL:-http://localhost:8080}"
LOG_DIR="${LOG_DIR:-logs}"
APP_LOG="$LOG_DIR/app.log"
NAMESPACE="${NAMESPACE:-keycloak-oidc-demo}"

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq >/dev/null   || { echo "jq is required"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required"; exit 1; }

mkdir -p "$LOG_DIR"

echo "Waiting for $APP_URL/healthz..."
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "$APP_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]] || { echo "App not ready at $APP_URL/healthz" >&2; exit 1; }

# Drive the OIDC authorisation-code flow with curl + a cookie jar,
# returning 0 on success and printing nothing on stdout. Stores the
# session cookie in the supplied jar; subsequent calls with -b "$JAR"
# behave as the logged-in user.
login_user() {
  local username="$1"
  local password="$2"
  local jar="$3"

  rm -f "$jar"

  # 1. /login -> 302 to Keycloak auth URL.
  local auth_url
  auth_url="$(curl -sS -o /dev/null -w '%{redirect_url}' \
    -c "$jar" -b "$jar" "$APP_URL/login")"
  [[ -n "$auth_url" ]] || { echo "no redirect from /login" >&2; return 1; }

  # 2. GET the auth URL -> Keycloak login HTML. Pull the form action.
  local login_html action
  login_html="$(curl -sS -c "$jar" -b "$jar" "$auth_url")"
  action="$(printf '%s' "$login_html" \
    | grep -oE 'id="kc-form-login"[^>]*action="[^"]+"' \
    | grep -oE 'action="[^"]+"' \
    | head -n 1 \
    | sed 's|action="||;s|"$||;s|&amp;|\&|g')"
  [[ -n "$action" ]] || {
    echo "could not find login form action in Keycloak HTML" >&2
    printf '%s\n' "$login_html" | head -40 >&2
    return 1
  }

  # 3. POST credentials -> 302 to BFF /callback?code=...&state=...
  local cb_url
  cb_url="$(curl -sS -o /dev/null -w '%{redirect_url}' \
    -c "$jar" -b "$jar" \
    --data-urlencode "username=$username" \
    --data-urlencode "password=$password" \
    --data-urlencode "credentialId=" \
    "$action")"
  [[ "$cb_url" == "$APP_URL/callback"* ]] || {
    echo "expected redirect to $APP_URL/callback, got: $cb_url" >&2
    return 1
  }

  # 4. GET /callback -> BFF sets bff_session cookie and 302s to "/".
  local home_url
  home_url="$(curl -sS -o /dev/null -w '%{redirect_url}' \
    -c "$jar" -b "$jar" "$cb_url")"
  [[ "$home_url" == "$APP_URL/"* || -z "$home_url" ]] || {
    echo "callback did not redirect home, got: $home_url" >&2
    return 1
  }

  # Sanity: the jar must now hold a bff_session cookie.
  grep -q "bff_session" "$jar" || {
    echo "no bff_session cookie set after callback" >&2
    return 1
  }
}

ALICE_JAR="$(mktemp)"
BOB_JAR="$(mktemp)"
cleanup() { rm -f "$ALICE_JAR" "$BOB_JAR"; }
trap cleanup EXIT

echo
echo "Negative path: GET /me without a session must be 401."
status="$(curl -sS -o /dev/null -w '%{http_code}' "$APP_URL/me")"
[[ "$status" == "401" ]] || { echo "expected 401, got $status" >&2; exit 1; }
echo "  ok: 401 unauthenticated"

echo
echo "Logging alice in via the auth-code flow..."
login_user alice alice "$ALICE_JAR"
me_alice="$(curl -sS -b "$ALICE_JAR" "$APP_URL/me")"
echo "$me_alice" | jq .
got_email="$(echo "$me_alice" | jq -r '.claims.email')"
got_username="$(echo "$me_alice" | jq -r '.claims.preferred_username')"
got_profile_email="$(echo "$me_alice" | jq -r '.profile.email')"
[[ "$got_email" == "alice@example.com" ]]    || { echo "wrong email for alice: $got_email" >&2; exit 1; }
[[ "$got_username" == "alice" ]]              || { echo "wrong preferred_username for alice: $got_username" >&2; exit 1; }
[[ "$got_profile_email" == "alice@example.com" ]] || { echo "alice profile not provisioned" >&2; exit 1; }

echo
echo "Logging bob in via the auth-code flow..."
login_user bob bob "$BOB_JAR"
me_bob="$(curl -sS -b "$BOB_JAR" "$APP_URL/me")"
echo "$me_bob" | jq .
[[ "$(echo "$me_bob" | jq -r '.claims.preferred_username')" == "bob" ]] \
  || { echo "wrong preferred_username for bob" >&2; exit 1; }

echo
echo "Adding a note as alice..."
curl -fsS -b "$ALICE_JAR" -H 'Content-Type: application/json' \
  -d '{"text":"alice was here"}' \
  "$APP_URL/notes" | jq .

echo
echo "Adding a note as bob..."
curl -fsS -b "$BOB_JAR" -H 'Content-Type: application/json' \
  -d '{"text":"bob was here"}' \
  "$APP_URL/notes" | jq .

echo
echo "Listing alice's notes..."
alice_notes="$(curl -fsS -b "$ALICE_JAR" "$APP_URL/notes")"
echo "$alice_notes" | jq .
alice_count="$(echo "$alice_notes" | jq '.notes | length')"
alice_text="$(echo "$alice_notes" | jq -r '.notes[0].text')"
[[ "$alice_count" == "1" ]] || { echo "alice should have 1 note, got $alice_count" >&2; exit 1; }
[[ "$alice_text" == "alice was here" ]] || { echo "wrong note text for alice: $alice_text" >&2; exit 1; }

echo
echo "Listing bob's notes (must not include alice's)..."
bob_notes="$(curl -fsS -b "$BOB_JAR" "$APP_URL/notes")"
echo "$bob_notes" | jq .
bob_count="$(echo "$bob_notes" | jq '.notes | length')"
bob_text="$(echo "$bob_notes" | jq -r '.notes[0].text')"
[[ "$bob_count" == "1" ]] || { echo "bob should have 1 note, got $bob_count" >&2; exit 1; }
[[ "$bob_text" == "bob was here" ]] || { echo "wrong note text for bob: $bob_text" >&2; exit 1; }
echo "$bob_notes" | jq -e '.notes | map(.text) | index("alice was here") == null' >/dev/null \
  || { echo "data isolation broken: bob can see alice's note" >&2; exit 1; }

echo
echo "Logging alice out (RP-initiated)..."
logout_redirect="$(curl -sS -o /dev/null -w '%{redirect_url}' -X POST \
  -b "$ALICE_JAR" -c "$ALICE_JAR" "$APP_URL/logout")"
[[ "$logout_redirect" == *"/realms/poc/protocol/openid-connect/logout"* ]] || {
  echo "expected RP-initiated logout redirect to Keycloak, got: $logout_redirect" >&2
  exit 1
}

echo "  redirect target: $logout_redirect"

echo
echo "After logout, /me with the same cookie must be 401..."
status="$(curl -sS -o /dev/null -w '%{http_code}' -b "$ALICE_JAR" "$APP_URL/me")"
[[ "$status" == "401" ]] || { echo "expected 401 after logout, got $status" >&2; exit 1; }

echo
echo "Collecting logs to $LOG_DIR/..."
kubectl logs -n "$NAMESPACE" deployment/keycloak-oidc-demo-app > "$APP_LOG"
grep -q "LOGIN_OK sub=.* email=alice@example.com"   "$APP_LOG"
grep -q "LOGIN_OK sub=.* email=bob@example.com"     "$APP_LOG"
grep -q "USER_PROVISIONED"                          "$APP_LOG"
grep -q "NOTE_ADDED"                                "$APP_LOG"
grep -q "LOGOUT"                                    "$APP_LOG"

echo
echo "Smoke test passed."
echo "  alice notes: $alice_count   bob notes: $bob_count"
echo "  RP-initiated logout sends user to Keycloak's end_session_endpoint."
