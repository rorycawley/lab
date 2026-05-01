#!/usr/bin/env bash
set -euo pipefail

cat <<'BANNER'
================================================================================
make recover-vault: dev-mode bootstrap recovery, NOT production state recovery.

Vault dev mode loses every auth method, policy, secrets engine, and lease on
restart. This script re-runs the Vault bootstrap chain to put the cluster back
into a working state, but it does not restore prior state.

In production, Vault uses integrated storage (Raft) with auto-unseal (KMS,
HSM, or Shamir), so a Vault Pod restart preserves auth methods, policies,
secrets engines, and leases without re-running this chain.
================================================================================
BANNER

./scripts/07-apply-vault.sh
./scripts/36-apply-terraform.sh
./scripts/15-install-vault-agent-injector.sh

kubectl rollout restart deployment/python-postgres-demo --namespace demo
kubectl rollout status  deployment/python-postgres-demo --namespace demo --timeout=180s

./scripts/08-verify-vault.sh
./scripts/10-verify-vault-kubernetes-auth.sh
./scripts/12-verify-vault-policies.sh
./scripts/14-verify-vault-database-secrets.sh
./scripts/16-verify-vault-agent-injector.sh
./scripts/19-verify-python-app.sh

echo "Vault re-bootstrapped and the app is healthy."
