#!/usr/bin/env bash
set -euo pipefail

kubectl delete namespace demo vault database phase4-other --ignore-not-found=true
if [[ -f .runtime/postgres.env ]]; then
  docker compose --env-file .runtime/postgres.env down -v --remove-orphans
else
  docker compose down -v --remove-orphans
fi

# Wipe runtime artifacts and Terraform state. The Vault state Terraform tracks
# lives in a Vault that's now gone; the .runtime/vault-postgres.env file
# records a vault_admin PG password that's gone with the PG volume. Keeping
# either across a clean would let stale state mismatch fresh resources on the
# next apply (chicken-and-egg between PG role creation and Vault connection
# verification, since null_resource.vault_admin_pg_role only re-runs when the
# generated password changes).
rm -rf .runtime
rm -f  terraform/terraform.tfstate terraform/terraform.tfstate.backup
rm -rf terraform/.terraform terraform/.terraform.lock.hcl

echo "Kubernetes namespaces, Docker Compose state, runtime artifacts, and Terraform state removed."
