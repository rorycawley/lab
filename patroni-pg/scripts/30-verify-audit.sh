#!/usr/bin/env bash
set -euo pipefail

audit_dir=".runtime/audit"
report="$audit_dir/report.json"

./scripts/28-audit-drill.sh
./scripts/29-audit-evidence-report.sh >/dev/null

if [[ ! -s "$report" ]]; then
  echo "error: report file $report is missing or empty"
  exit 1
fi

if ! jq -e . "$report" >/dev/null; then
  echo "error: report file $report is not valid JSON"
  exit 1
fi
echo "ok: $report is valid JSON"

audit_device_count="$(jq 'if (.vault.audit_devices|type)=="object" then (.vault.audit_devices|length) else (.vault.audit_devices|length) end' "$report")"
if (( audit_device_count < 2 )); then
  echo "error: Vault has $audit_device_count audit devices, expected at least 2"
  exit 1
fi
echo "ok: Vault has $audit_device_count audit devices"

if [[ "$(jq -r '.identity.db_password_env_present' "$report")" != "false" ]]; then
  echo "error: DB_PASSWORD env present on the app container"
  exit 1
fi
echo "ok: DB_PASSWORD is absent from the app environment"

for ns in demo vault; do
  enforce="$(jq -r ".kubernetes.psa_enforce.$ns" "$report")"
  if [[ "$enforce" != "restricted" ]]; then
    echo "error: namespace $ns PSA enforce is '$enforce', expected restricted"
    exit 1
  fi
done
echo "ok: PSA enforce=restricted on demo and vault"

logins="$(jq -r '.vault.counts.kubernetes_logins' "$report")"
runtime_creds="$(jq -r '.vault.counts.runtime_creds_issued' "$report")"
if (( logins == 0 )); then
  echo "error: report shows zero Kubernetes auth logins on Vault"
  exit 1
fi
if (( runtime_creds == 0 )); then
  echo "error: report shows zero runtime credentials issued by Vault"
  exit 1
fi
echo "ok: Vault audit shows $logins login(s) and $runtime_creds runtime credential issuance(s)"

unverified="$(jq -r '.denied_cases[] | select(.status != "verified") | .id' "$report")"
if [[ -n "$unverified" ]]; then
  echo "error: the following denied cases are not verified:"
  echo "$unverified"
  exit 1
fi
echo "ok: every denied case in the report is verified"

priv_admission="$(jq -r '.kubernetes.privileged_pod_admission' "$report")"
if [[ "$priv_admission" != "rejected" ]]; then
  echo "error: privileged Pod admission status is '$priv_admission', expected rejected"
  exit 1
fi
echo "ok: privileged Pod admission was rejected"

echo "Phase 14 audit evidence verification passed."
