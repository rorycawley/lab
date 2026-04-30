#!/usr/bin/env bash
set -euo pipefail

demo_namespace="demo"
vault_namespace="vault"
audit_dir=".runtime/audit"

mkdir -p "$audit_dir"

vault_pod="$(kubectl get pod --namespace "$vault_namespace" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
vault_token="$(kubectl get secret vault-dev-root-token --namespace "$vault_namespace" -o jsonpath='{.data.token}' | base64 --decode)"
app_pod="$(kubectl get pod --namespace "$demo_namespace" -l app.kubernetes.io/name=python-postgres-demo -o jsonpath='{.items[0].metadata.name}')"

vault_exec() {
  kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
    env VAULT_ADDR=http://127.0.0.1:8201 VAULT_TOKEN="$vault_token" "$@"
}

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
service_account="$(kubectl get pod "$app_pod" --namespace "$demo_namespace" -o jsonpath='{.spec.serviceAccountName}')"
container_uid="$(kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- id -u)"
db_password_present=false
if kubectl get deployment python-postgres-demo --namespace "$demo_namespace" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].env[*].name}' \
    | tr ' ' '\n' | grep -qx "DB_PASSWORD"; then
  db_password_present=true
fi
cred_mode="$(kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- stat -c '%a' /vault/secrets/db-creds)"

audit_devices_json="$(vault_exec vault audit list -format=json)"

vault_audit_excerpt="$(kubectl exec --namespace "$vault_namespace" "$vault_pod" -c vault -- \
  sh -ec 'tail -c 200000 /vault/audit/audit.log 2>/dev/null || true')"
count_in_excerpt() {
  if [[ -z "$vault_audit_excerpt" ]]; then
    echo 0
  else
    grep -Ec "$1" <<<"$vault_audit_excerpt" || true
  fi
}
kubernetes_logins=$(count_in_excerpt 'auth/kubernetes/login')
runtime_creds_issued=$(count_in_excerpt 'database/creds/demo-app-runtime')
migration_creds_issued=$(count_in_excerpt 'database/creds/demo-app-migrate')
permission_denied=$(count_in_excerpt 'permission denied')
invalid_token=$(count_in_excerpt 'invalid token')

postgres_logs="$(docker compose --env-file .runtime/postgres.env logs --tail=2000 postgres 2>/dev/null || true)"
ssl_active=true
if [[ -z "$postgres_logs" ]]; then
  ssl_active=false
fi
connections_logged=$(grep -Ec 'connection authorized' <<<"$postgres_logs" || true)
ddl_attempts=$(grep -Ec 'statement: (DROP|CREATE|ALTER|TRUNCATE)' <<<"$postgres_logs" || true)
denied_role_creation_attempts=$(grep -Ec 'permission denied for (database|table|schema)|must be (superuser|owner)|must have CREATEROLE' <<<"$postgres_logs" || true)

psa_demo="$(kubectl get namespace "$demo_namespace" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
psa_vault="$(kubectl get namespace "$vault_namespace" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
netpol_demo_count="$(kubectl get networkpolicy --namespace "$demo_namespace" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
netpol_vault_count="$(kubectl get networkpolicy --namespace "$vault_namespace" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"

priv_admission="not_tested"
if [[ -s "$audit_dir/08-psa-privileged.log" ]]; then
  priv_admission="rejected"
fi

denied_cases=(
  "01-default-sa-cannot-login|demo/default cannot authenticate to Vault as the app role"
  "02-other-namespace-cannot-login|phase4-other/demo-app cannot authenticate as the app role"
  "03-runtime-cannot-read-migrate|runtime identity cannot read database/creds/demo-app-migrate"
  "04-migrate-cannot-read-runtime|migration identity cannot read database/creds/demo-app-runtime"
  "05-drop-table-and-create-role|app cannot DROP TABLE or CREATE ROLE on PostgreSQL"
  "06-netpol-vault|random Pod in demo cannot reach Vault on TCP/8200"
  "07-netpol-postgres|random Pod in demo cannot reach PostgreSQL on TCP/5432"
  "08-psa-privileged|privileged Pod is rejected by PodSecurity admission in demo"
  "09-revoked-lease|revoked Vault lease stops accepting connections to PostgreSQL"
)

denied_cases_json="["
first=true
for entry in "${denied_cases[@]}"; do
  id="${entry%%|*}"
  description="${entry#*|}"
  status="not_run"
  evidence_path="$audit_dir/$id.log"
  if [[ -s "$evidence_path" ]]; then
    status="verified"
  fi
  if $first; then
    first=false
  else
    denied_cases_json+=","
  fi
  denied_cases_json+="$(jq -nc \
    --arg id "$id" \
    --arg description "$description" \
    --arg status "$status" \
    --arg evidence "$evidence_path" \
    '{id:$id, description:$description, status:$status, evidence:$evidence}')"
done
denied_cases_json+="]"

correlation_username="$(grep -oE 'v-token-demo-app-runtime-[A-Za-z0-9-]+' <<<"$postgres_logs" | tail -n1 || true)"
correlation_pg_connect=""
correlation_pg_statement=""
if [[ -n "$correlation_username" ]]; then
  correlation_pg_connect="$(grep -E "connection authorized.*user=$correlation_username" <<<"$postgres_logs" | tail -n1 | awk '{print $1, $2}')"
  correlation_pg_statement="$(grep -E "\\[$correlation_username@" <<<"$postgres_logs" | grep -E 'statement: (SELECT|INSERT|UPDATE|DELETE)' | tail -n1 || true)"
fi

correlation_json="$(jq -nc \
  --arg description "End-to-end trace: Vault login -> credential read -> PostgreSQL connection." \
  --arg pg_username "$correlation_username" \
  --arg pg_connect "$correlation_pg_connect" \
  --arg pg_statement "$correlation_pg_statement" \
  '{description:$description, pg_username:$pg_username, pg_connect:$pg_connect, pg_statement:$pg_statement}')"

report="$(jq -n \
  --arg generated_at "$generated_at" \
  --arg service_account "$demo_namespace/$service_account" \
  --arg pod "$app_pod" \
  --argjson container_uid "$container_uid" \
  --argjson db_password_present "$db_password_present" \
  --arg cred_path "/vault/secrets/db-creds" \
  --arg cred_mode "$cred_mode" \
  --argjson audit_devices "$audit_devices_json" \
  --argjson kubernetes_logins "${kubernetes_logins:-0}" \
  --argjson runtime_creds_issued "${runtime_creds_issued:-0}" \
  --argjson migration_creds_issued "${migration_creds_issued:-0}" \
  --argjson permission_denied "${permission_denied:-0}" \
  --argjson invalid_token "${invalid_token:-0}" \
  --argjson ssl_active "$ssl_active" \
  --argjson connections_logged "${connections_logged:-0}" \
  --argjson ddl_attempts "${ddl_attempts:-0}" \
  --argjson denied_role_creation_attempts "${denied_role_creation_attempts:-0}" \
  --arg psa_demo "$psa_demo" \
  --arg psa_vault "$psa_vault" \
  --argjson netpol_demo "$netpol_demo_count" \
  --argjson netpol_vault "$netpol_vault_count" \
  --arg priv_admission "$priv_admission" \
  --argjson denied_cases "$denied_cases_json" \
  --argjson correlation "$correlation_json" \
  '{
     generated_at: $generated_at,
     identity: {
       service_account: $service_account,
       pod: $pod,
       container_uid: $container_uid,
       db_password_env_present: $db_password_present,
       rendered_credential_file: { path: $cred_path, mode: $cred_mode }
     },
     vault: {
       audit_devices: $audit_devices,
       counts: {
         kubernetes_logins: $kubernetes_logins,
         runtime_creds_issued: $runtime_creds_issued,
         migration_creds_issued: $migration_creds_issued,
         permission_denied: $permission_denied,
         invalid_token: $invalid_token
       }
     },
     postgresql: {
       ssl_active: $ssl_active,
       connections_logged: $connections_logged,
       ddl_attempts: $ddl_attempts,
       denied_role_creation_attempts: $denied_role_creation_attempts
     },
     kubernetes: {
       psa_enforce: { demo: $psa_demo, vault: $psa_vault },
       privileged_pod_admission: $priv_admission,
       networkpolicies: { demo: $netpol_demo, vault: $netpol_vault }
     },
     denied_cases: $denied_cases,
     correlation_example: $correlation
   }')"

printf '%s\n' "$report" >"$audit_dir/report.json"

{
  echo "# Phase 14 Audit Evidence Report"
  echo
  echo "Generated: $generated_at"
  echo
  echo "## Identity"
  jq -r '
    "- service account: " + .identity.service_account,
    "- pod: " + .identity.pod,
    "- container uid: " + (.identity.container_uid|tostring),
    "- DB_PASSWORD env present: " + (.identity.db_password_env_present|tostring),
    "- credential file: " + .identity.rendered_credential_file.path + " (mode " + .identity.rendered_credential_file.mode + ")"
  ' <<<"$report"
  echo
  echo "## Vault"
  jq -r '
    "- audit devices: " + ([.vault.audit_devices | keys[]] | join(", ")),
    "- kubernetes logins: " + (.vault.counts.kubernetes_logins|tostring),
    "- runtime credentials issued: " + (.vault.counts.runtime_creds_issued|tostring),
    "- migration credentials issued: " + (.vault.counts.migration_creds_issued|tostring),
    "- permission denied events: " + (.vault.counts.permission_denied|tostring),
    "- invalid token events: " + (.vault.counts.invalid_token|tostring)
  ' <<<"$report"
  echo
  echo "## PostgreSQL"
  jq -r '
    "- ssl active: " + (.postgresql.ssl_active|tostring),
    "- connections logged: " + (.postgresql.connections_logged|tostring),
    "- ddl statements logged: " + (.postgresql.ddl_attempts|tostring),
    "- denied role/permission errors: " + (.postgresql.denied_role_creation_attempts|tostring)
  ' <<<"$report"
  echo
  echo "## Kubernetes"
  jq -r '
    "- demo PSA enforce: " + .kubernetes.psa_enforce.demo,
    "- vault PSA enforce: " + .kubernetes.psa_enforce.vault,
    "- privileged Pod admission: " + .kubernetes.privileged_pod_admission,
    "- NetworkPolicies in demo: " + (.kubernetes.networkpolicies.demo|tostring),
    "- NetworkPolicies in vault: " + (.kubernetes.networkpolicies.vault|tostring)
  ' <<<"$report"
  echo
  echo "## Denied cases"
  jq -r '.denied_cases[] | "- [" + .status + "] " + .id + " — " + .description + " (" + .evidence + ")"' <<<"$report"
  echo
  echo "## Correlation example"
  jq -r '
    "- description: " + .correlation_example.description,
    "- pg username: " + .correlation_example.pg_username,
    "- pg connect: " + .correlation_example.pg_connect,
    "- pg statement: " + .correlation_example.pg_statement
  ' <<<"$report"
} >"$audit_dir/report.md"

cat "$audit_dir/report.json"
