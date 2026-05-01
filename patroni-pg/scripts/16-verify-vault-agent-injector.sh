#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

pod="vault-injector-smoke"
namespace="demo"

kubectl rollout status deployment/vault-agent-injector-agent-injector --namespace vault --timeout=120s >/dev/null
echo "ok: Vault Agent Injector deployment is ready"

kubectl get mutatingwebhookconfiguration vault-agent-injector-agent-injector-cfg >/dev/null
echo "ok: Vault Agent Injector mutating webhook exists"

kubectl wait --for=condition=Ready "pod/$pod" --namespace "$namespace" --timeout=120s >/dev/null
echo "ok: annotated smoke Pod is Ready"

init_count="$(kubectl get pod "$pod" --namespace "$namespace" -o jsonpath='{.spec.initContainers[*].name}' | tr ' ' '\n' | grep -c '^vault-agent-init$' || true)"
sidecar_count="$(kubectl get pod "$pod" --namespace "$namespace" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep -c '^vault-agent$' || true)"

if [[ "$init_count" != "1" ]]; then
  echo "error: expected vault-agent-init init container"
  exit 1
fi
echo "ok: Vault Agent init container was injected"

if [[ "$sidecar_count" != "1" ]]; then
  echo "error: expected vault-agent sidecar container"
  exit 1
fi
echo "ok: Vault Agent sidecar container was injected"

kubectl exec --namespace "$namespace" "$pod" -c app -- test -f /vault/secrets/db-creds
echo "ok: rendered credential file exists"

perms="$(kubectl exec --namespace "$namespace" "$pod" -c app -- stat -c '%a' /vault/secrets/db-creds)"
if [[ "$perms" != "400" ]]; then
  echo "error: expected /vault/secrets/db-creds permissions 400, got $perms"
  exit 1
fi
echo "ok: rendered credential file permissions are 0400"

kubectl exec --namespace "$namespace" "$pod" -c app -- grep -q '^DB_USERNAME=' /vault/secrets/db-creds
kubectl exec --namespace "$namespace" "$pod" -c app -- grep -q '^DB_PASSWORD=' /vault/secrets/db-creds
echo "ok: rendered credential file contains DB_USERNAME and DB_PASSWORD"

if kubectl get pod vault-injector-unannotated --namespace "$namespace" >/dev/null 2>&1; then
  kubectl delete pod vault-injector-unannotated --namespace "$namespace" --wait=true >/dev/null
fi

apply_psa_test_pod vault-injector-unannotated "$namespace" vault-injector-unannotated hashicorp/vault:1.17.6 100 1000
kubectl wait --for=condition=Ready pod/vault-injector-unannotated --namespace "$namespace" --timeout=120s >/dev/null

unannotated_sidecar_count="$(kubectl get pod vault-injector-unannotated --namespace "$namespace" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep -c '^vault-agent$' || true)"
kubectl delete pod vault-injector-unannotated --namespace "$namespace" --wait=true >/dev/null

if [[ "$unannotated_sidecar_count" != "0" ]]; then
  echo "error: unannotated Pod was unexpectedly injected"
  exit 1
fi
echo "ok: unannotated Pod was not injected"

echo "Phase 7 Vault Agent Injector verification passed."
