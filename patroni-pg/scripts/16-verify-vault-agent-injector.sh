#!/usr/bin/env bash
set -euo pipefail

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

kubectl apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: vault-injector-unannotated
  namespace: demo
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: vault-injector-unannotated
      image: hashicorp/vault:1.17.6
      command: ["sh", "-ec", "sleep 60"]
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
      resources:
        requests: { cpu: 25m, memory: 32Mi }
        limits:   { cpu: 100m, memory: 64Mi }
YAML
kubectl wait --for=condition=Ready pod/vault-injector-unannotated --namespace "$namespace" --timeout=120s >/dev/null

unannotated_sidecar_count="$(kubectl get pod vault-injector-unannotated --namespace "$namespace" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep -c '^vault-agent$' || true)"
kubectl delete pod vault-injector-unannotated --namespace "$namespace" --wait=true >/dev/null

if [[ "$unannotated_sidecar_count" != "0" ]]; then
  echo "error: unannotated Pod was unexpectedly injected"
  exit 1
fi
echo "ok: unannotated Pod was not injected"

echo "Phase 7 Vault Agent Injector verification passed."
