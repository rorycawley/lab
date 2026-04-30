#!/usr/bin/env bash
set -euo pipefail

demo_namespace="demo"
vault_namespace="vault"
audit_dir=".runtime/audit"
test_pod="audit-drill-tester"

mkdir -p "$audit_dir"
rm -f "$audit_dir"/*.log "$audit_dir"/report.json "$audit_dir"/report.md 2>/dev/null || true

vault_pod="$(kubectl get pod --namespace "$vault_namespace" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
vault_token="$(kubectl get secret vault-dev-root-token --namespace "$vault_namespace" -o jsonpath='{.data.token}' | base64 --decode)"
app_pod="$(kubectl get pod --namespace "$demo_namespace" -l app.kubernetes.io/name=python-postgres-demo -o jsonpath='{.items[0].metadata.name}')"

vault_exec() {
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$vault_token" "$@"
}

vault_audit_size() {
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
    sh -ec 'wc -c </vault/audit/audit.log 2>/dev/null || echo 0' | tr -d '[:space:]'
}

vault_audit_diff() {
  local before="$1"
  local out="$2"
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
    sh -ec "tail -c +$((before + 1)) /vault/audit/audit.log" >"$out"
}

cleanup_test_pod() {
  kubectl delete pod "$test_pod" --namespace "$demo_namespace" \
    --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
}

cleanup_other_namespace() {
  kubectl delete namespace phase4-other --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}

trap 'cleanup_test_pod; cleanup_other_namespace' EXIT

run_vault_denial() {
  local id="$1"
  local description="$2"
  shift 2
  local before
  before="$(vault_audit_size)"

  if "$@" >/tmp/audit-drill-stdout 2>/tmp/audit-drill-stderr; then
    echo "error: drill case '$id' ($description) unexpectedly succeeded"
    cat /tmp/audit-drill-stdout
    return 1
  fi

  sleep 1
  vault_audit_diff "$before" "$audit_dir/$id.log"

  if [[ ! -s "$audit_dir/$id.log" ]]; then
    echo "error: drill case '$id' produced no Vault audit entry"
    return 1
  fi
  echo "ok: $id - $description"
}

login_with_token() {
  local sa_token="$1"
  local role="$2"
  vault_exec sh -ec "vault write -format=json auth/kubernetes/login role=$role jwt=\"$sa_token\""
}

echo "Phase 14 audit drill."
echo "Writing per-case evidence to $audit_dir/"

default_token="$(kubectl create token default --namespace "$demo_namespace" --duration=10m)"
run_vault_denial "01-default-sa-cannot-login" \
  "demo/default cannot authenticate to Vault as the app role" \
  login_with_token "$default_token" "demo-app"

if ! kubectl get namespace phase4-other >/dev/null 2>&1; then
  kubectl create namespace phase4-other >/dev/null
fi
kubectl create serviceaccount demo-app --namespace phase4-other --dry-run=client -o yaml | kubectl apply -f - >/dev/null
other_token="$(kubectl create token demo-app --namespace phase4-other --duration=10m)"
run_vault_denial "02-other-namespace-cannot-login" \
  "phase4-other/demo-app cannot authenticate as the app role" \
  login_with_token "$other_token" "demo-app"

demo_app_token="$(kubectl create token demo-app --namespace "$demo_namespace" --duration=10m)"
runtime_login_json="$(login_with_token "$demo_app_token" "demo-app")"
runtime_token="$(jq -r '.auth.client_token' <<<"$runtime_login_json")"
demo_migrate_token="$(kubectl create token demo-migrate --namespace "$demo_namespace" --duration=10m)"
migrate_login_json="$(login_with_token "$demo_migrate_token" "demo-migrate")"
migrate_token="$(jq -r '.auth.client_token' <<<"$migrate_login_json")"

run_vault_denial "03-runtime-cannot-read-migrate" \
  "runtime identity cannot read database/creds/demo-app-migrate" \
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$runtime_token" \
    vault read database/creds/demo-app-migrate

run_vault_denial "04-migrate-cannot-read-runtime" \
  "migration identity cannot read database/creds/demo-app-runtime" \
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$migrate_token" \
    vault read database/creds/demo-app-runtime

prove_denied="$(kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- python -c '
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:8080/security/prove-denied",
    data=b"{}",
    method="POST",
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=10) as response:
    print(response.read().decode())
')"
if ! grep -q '"allowed":[[:space:]]*false' <<<"$prove_denied"; then
  echo "error: app /security/prove-denied did not return allowed=false"
  echo "$prove_denied"
  exit 1
fi
printf '%s\n' "$prove_denied" >"$audit_dir/05-drop-table-and-create-role.log"
docker compose --env-file .runtime/postgres.env logs --tail=200 postgres 2>/dev/null \
  | grep -E 'ERROR|permission denied' >>"$audit_dir/05-drop-table-and-create-role.log" || true
echo "ok: 05-drop-table-and-create-role - app proves DROP TABLE and CREATE ROLE are denied"

cleanup_test_pod
kubectl run "$test_pod" \
  --namespace "$demo_namespace" \
  --image=busybox:1.36 \
  --restart=Never \
  --labels="app.kubernetes.io/name=audit-drill-tester" \
  --command -- sh -c 'sleep 120' >/dev/null
kubectl wait --for=condition=Ready "pod/$test_pod" \
  --namespace "$demo_namespace" --timeout=60s >/dev/null

if kubectl exec --namespace "$demo_namespace" "$test_pod" -- \
  sh -c 'nc -z -w 3 vault.vault.svc.cluster.local 8200' >/dev/null 2>&1; then
  echo "error: drill case '06-netpol-vault' unexpectedly reached Vault:8200"
  exit 1
fi
echo "blocked by NetworkPolicy: TCP timeout reaching vault.vault.svc.cluster.local:8200" \
  >"$audit_dir/06-netpol-vault.log"
echo "ok: 06-netpol-vault - random Pod cannot reach Vault:8200"

postgres_host_ip="$(kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- \
  python -c 'import socket; print(socket.gethostbyname("host.rancher-desktop.internal"))')"
if kubectl exec --namespace "$demo_namespace" "$test_pod" -- \
  sh -c "nc -z -w 3 $postgres_host_ip 5432" >/dev/null 2>&1; then
  echo "error: drill case '07-netpol-postgres' unexpectedly reached PostgreSQL:5432"
  exit 1
fi
echo "blocked by NetworkPolicy: TCP timeout reaching $postgres_host_ip:5432" \
  >"$audit_dir/07-netpol-postgres.log"
echo "ok: 07-netpol-postgres - random Pod cannot reach PostgreSQL:5432"

priv_manifest='
apiVersion: v1
kind: Pod
metadata:
  name: privileged-drill
  namespace: demo
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sh","-c","sleep 60"]
      securityContext:
        privileged: true
'
if echo "$priv_manifest" | kubectl apply --dry-run=server -f - >/tmp/audit-drill-priv.out 2>&1; then
  echo "error: drill case '08-psa-privileged' was admitted by the demo namespace"
  cat /tmp/audit-drill-priv.out
  exit 1
fi
if ! grep -qi 'violates PodSecurity\|forbidden' /tmp/audit-drill-priv.out; then
  echo "error: privileged Pod was rejected, but not by PodSecurity admission:"
  cat /tmp/audit-drill-priv.out
  exit 1
fi
cp /tmp/audit-drill-priv.out "$audit_dir/08-psa-privileged.log"
echo "ok: 08-psa-privileged - privileged Pod is rejected by PodSecurity admission"

issued_json="$(vault_exec vault read -format=json database/creds/demo-app-runtime)"
issued_username="$(jq -r '.data.username' <<<"$issued_json")"
issued_password="$(jq -r '.data.password' <<<"$issued_json")"
issued_lease="$(jq -r '.lease_id' <<<"$issued_json")"

if ! kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- python -c "
import os
import psycopg
import sys

conn = psycopg.connect(
    host='host.rancher-desktop.internal',
    port=5432,
    dbname='demo_registry',
    user='$issued_username',
    password='$issued_password',
    sslmode='verify-full',
    sslrootcert='/etc/postgres-ca/ca.crt',
    connect_timeout=5,
)
with conn.cursor() as cur:
    cur.execute('SELECT current_user')
    print(cur.fetchone()[0])
conn.close()
" >/tmp/audit-drill-pre-revoke 2>&1; then
  echo "error: freshly issued Vault credential could not connect to PostgreSQL"
  cat /tmp/audit-drill-pre-revoke
  exit 1
fi

vault_exec vault lease revoke "$issued_lease" >/dev/null
sleep 2

if kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- python -c "
import psycopg

conn = psycopg.connect(
    host='host.rancher-desktop.internal',
    port=5432,
    dbname='demo_registry',
    user='$issued_username',
    password='$issued_password',
    sslmode='verify-full',
    sslrootcert='/etc/postgres-ca/ca.crt',
    connect_timeout=5,
)
conn.close()
" >/tmp/audit-drill-post-revoke 2>&1; then
  echo "error: revoked Vault credential unexpectedly still works"
  cat /tmp/audit-drill-post-revoke
  exit 1
fi
{
  echo "lease_id=$issued_lease"
  echo "username=$issued_username"
  echo "post-revoke connection error:"
  cat /tmp/audit-drill-post-revoke
  echo "---postgres log tail---"
  docker compose --env-file .runtime/postgres.env logs --tail=100 postgres 2>/dev/null \
    | grep -E "$issued_username|FATAL|ERROR" || true
} >"$audit_dir/09-revoked-lease.log"
echo "ok: 09-revoked-lease - revoking the lease stops the credential from connecting"

echo "Phase 14 audit drill: all denied cases verified."
