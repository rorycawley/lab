#!/usr/bin/env bash
set -euo pipefail

demo_namespace="demo"
vault_namespace="vault"

app_pod() {
  kubectl get pod --namespace "$demo_namespace" -l app.kubernetes.io/name=python-postgres-demo -o jsonpath='{.items[0].metadata.name}'
}

app_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local pod
  pod="$(app_pod)"

  kubectl exec --namespace "$demo_namespace" "$pod" -c app -- python -c '
import json
import sys
import urllib.request

method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
data = body.encode() if body else None
headers = {"Content-Type": "application/json"} if body else {}
req = urllib.request.Request(
    "http://127.0.0.1:8080" + path,
    data=data,
    method=method,
    headers=headers,
)
with urllib.request.urlopen(req, timeout=10) as response:
    print(response.read().decode())
' "$method" "$path" "$body"
}

app_request_status() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local pod
  pod="$(app_pod)"

  kubectl exec --namespace "$demo_namespace" "$pod" -c app -- python -c '
import sys
import urllib.error
import urllib.request

method, path, body = sys.argv[1], sys.argv[2], sys.argv[3]
data = body.encode() if body else None
headers = {"Content-Type": "application/json"} if body else {}
req = urllib.request.Request(
    "http://127.0.0.1:8080" + path,
    data=data,
    method=method,
    headers=headers,
)
try:
    with urllib.request.urlopen(req, timeout=10) as response:
        print(response.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
except Exception:
    print("0")
' "$method" "$path" "$body"
}

echo "Phase 15 recovery drill A: Vault outage."

app_request POST /companies '{"id":"00000000-0000-0000-0000-000000000040","name":"Recovery Pre","status":"active"}' >/dev/null
app_request DELETE /companies/00000000-0000-0000-0000-000000000040 >/dev/null
echo "ok: pre-outage CRUD works"

kubectl scale deployment vault --namespace "$vault_namespace" --replicas=0 >/dev/null
kubectl wait --for=delete pod -l app.kubernetes.io/name=vault --namespace "$vault_namespace" --timeout=60s >/dev/null 2>&1 || true
echo "ok: Vault scaled to 0 replicas"

mid_status="$(app_request_status GET /db-identity)"
if [[ "$mid_status" != "200" ]]; then
  echo "error: app /db-identity returned $mid_status while Vault was down (expected pool to keep serving)"
  kubectl scale deployment vault --namespace "$vault_namespace" --replicas=1 >/dev/null
  exit 1
fi
echo "ok: existing pool keeps serving CRUD while Vault is unreachable"

app_request POST /companies '{"id":"00000000-0000-0000-0000-000000000041","name":"Recovery Mid","status":"active"}' >/dev/null
app_request GET /companies/00000000-0000-0000-0000-000000000041 | grep -q "Recovery Mid"
app_request DELETE /companies/00000000-0000-0000-0000-000000000041 >/dev/null
echo "ok: CRUD works against the existing pool while Vault is at replicas=0"

kubectl scale deployment vault --namespace "$vault_namespace" --replicas=1 >/dev/null
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=vault --namespace "$vault_namespace" --timeout=120s >/dev/null
echo "ok: Vault is back to replicas=1 and Ready"

if [[ ! -d .runtime/audit ]]; then
  mkdir -p .runtime/audit
fi

# Vault dev mode is in-memory only: scaling to 0 wiped every auth method,
# policy, secrets engine, and audit device. Re-apply via Terraform so
# subsequent verify steps (and the rest of the demo) have a working Vault.
# This is the operational reality the documented `make recover-vault` target
# represents, executed automatically here so the drill leaves the system in a
# consistent state.
#
# A subtlety: if the rotation drill ran earlier in the same verify chain, it
# rotated the vault_admin password Vault uses to manage PostgreSQL. Vault
# stored that rotated password, then lost it on outage. PG still has it.
# Terraform's random_password.vault_admin is unchanged in state but represents
# a password PG no longer accepts. Reset PG's vault_admin to match what
# Terraform knows, THEN re-apply Vault config.
echo "ok: re-applying Vault configuration via Terraform (dev mode lost state on outage)"
set -a
# shellcheck source=/dev/null
source .runtime/vault-postgres.env
set +a
./scripts/41-apply-vault-admin-pg-role.sh >/tmp/phase15-recover-pg.log 2>&1 || {
  echo "error: PG vault_admin password reset after Vault outage failed:"
  cat /tmp/phase15-recover-pg.log
  exit 1
}
./scripts/36-apply-terraform.sh >/tmp/phase15-recover-tf.log 2>&1 || {
  echo "error: terraform re-apply after Vault outage failed:"
  cat /tmp/phase15-recover-tf.log
  exit 1
}

# After Terraform re-applies, the app's existing pool still references creds
# from the now-evicted lease. Roll the deployment to force a fresh sidecar
# render against the freshly bootstrapped Vault.
kubectl rollout restart deployment/python-postgres-demo --namespace "$demo_namespace" >/dev/null
kubectl rollout status  deployment/python-postgres-demo --namespace "$demo_namespace" --timeout=180s >/dev/null
app_request POST /companies '{"id":"00000000-0000-0000-0000-000000000042","name":"Recovery Post","status":"active"}' >/dev/null
app_request DELETE /companies/00000000-0000-0000-0000-000000000042 >/dev/null
echo "ok: post-recovery CRUD works against re-bootstrapped Vault"

echo "Phase 15 recovery drill B: PostgreSQL restart."

pre_generation="$(app_request GET /pool/status | jq -r '.pool_generation')"
docker compose --env-file .runtime/postgres.env restart postgres >/dev/null
echo "ok: docker compose restart postgres issued"

healthy=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if docker compose --env-file .runtime/postgres.env ps --format json postgres 2>/dev/null \
      | jq -r '.Health' 2>/dev/null | grep -qx "healthy"; then
    healthy=true
    break
  fi
  sleep 2
done
if ! $healthy; then
  echo "error: PostgreSQL did not return to healthy within the wait window"
  exit 1
fi
echo "ok: PostgreSQL container is healthy again"

reconnected=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  status="$(app_request_status GET /db-identity)"
  if [[ "$status" == "200" ]]; then
    reconnected=true
    break
  fi
  app_request POST /pool/reload '{}' >/dev/null 2>&1 || true
  sleep 2
done
if ! $reconnected; then
  echo "error: app pool did not recover after PostgreSQL restart"
  exit 1
fi
echo "ok: app pool recovered after PostgreSQL restart"

post_user="$(app_request GET /db-identity | jq -r '.current_user')"
if [[ "$post_user" != v-* ]]; then
  echo "error: post-recovery user '$post_user' is not a Vault-issued v-... user"
  exit 1
fi
echo "ok: app still connects as Vault-issued $post_user after PostgreSQL restart"

app_request POST /companies '{"id":"00000000-0000-0000-0000-000000000043","name":"PG Recovery Post","status":"active"}' >/dev/null
app_request GET /companies/00000000-0000-0000-0000-000000000043 | grep -q "PG Recovery Post"
app_request DELETE /companies/00000000-0000-0000-0000-000000000043 >/dev/null
echo "ok: post-restart CRUD works"

echo "Phase 15 recovery drill passed (Vault outage + PostgreSQL restart)."
