#!/usr/bin/env bash
set -euo pipefail

demo_namespace="demo"
vault_namespace="vault"

echo "Phase 13 container hardening verification."

for ns in "$demo_namespace" "$vault_namespace"; do
  enforce="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
  if [[ "$enforce" != "restricted" ]]; then
    echo "error: namespace $ns enforce label is '$enforce', expected 'restricted'"
    exit 1
  fi
done
echo "ok: demo and vault namespaces enforce Pod Security 'restricted'"

priv_manifest='
apiVersion: v1
kind: Pod
metadata:
  name: privileged-test
  namespace: demo
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sh", "-c", "sleep 60"]
      securityContext:
        privileged: true
'
if echo "$priv_manifest" | kubectl apply --dry-run=server -f - >/tmp/phase13-priv.out 2>&1; then
  echo "error: privileged Pod was admitted by the demo namespace"
  cat /tmp/phase13-priv.out
  exit 1
fi
if ! grep -qi 'violates PodSecurity\|forbidden' /tmp/phase13-priv.out; then
  echo "error: privileged Pod was rejected, but not by PodSecurity admission:"
  cat /tmp/phase13-priv.out
  exit 1
fi
echo "ok: privileged Pod is rejected by PodSecurity admission in demo"

check_pod_hardening() {
  local namespace="$1"
  local pod="$2"

  local pod_json
  pod_json="$(kubectl get pod "$pod" --namespace "$namespace" -o json)"

  local pod_run_as_non_root
  pod_run_as_non_root="$(jq -r '.spec.securityContext.runAsNonRoot // false' <<<"$pod_json")"
  local pod_run_as_user
  pod_run_as_user="$(jq -r '.spec.securityContext.runAsUser // 0' <<<"$pod_json")"
  if [[ "$pod_run_as_non_root" != "true" && "$pod_run_as_user" == "0" ]]; then
    echo "error: pod $namespace/$pod does not run as non-root at the pod level"
    exit 1
  fi

  local container_count
  container_count="$(jq -r '.spec.containers | length' <<<"$pod_json")"
  for ((i = 0; i < container_count; i++)); do
    local container_name
    container_name="$(jq -r ".spec.containers[$i].name" <<<"$pod_json")"

    local allow_pe
    allow_pe="$(jq -r "if .spec.containers[$i].securityContext | has(\"allowPrivilegeEscalation\") then .spec.containers[$i].securityContext.allowPrivilegeEscalation else true end" <<<"$pod_json")"
    if [[ "$allow_pe" != "false" ]]; then
      echo "error: $namespace/$pod container $container_name allows privilege escalation"
      exit 1
    fi

    local drops
    drops="$(jq -r "(.spec.containers[$i].securityContext.capabilities.drop // []) | join(\",\")" <<<"$pod_json")"
    if [[ ",$drops," != *",ALL,"* ]]; then
      echo "error: $namespace/$pod container $container_name does not drop ALL capabilities (drops='$drops')"
      exit 1
    fi

    local seccomp
    seccomp="$(jq -r "(.spec.containers[$i].securityContext.seccompProfile.type // .spec.securityContext.seccompProfile.type // \"\")" <<<"$pod_json")"
    if [[ "$seccomp" != "RuntimeDefault" && "$seccomp" != "Localhost" ]]; then
      echo "error: $namespace/$pod container $container_name does not set seccompProfile (got '$seccomp')"
      exit 1
    fi

    local cpu_req mem_req cpu_lim mem_lim
    cpu_req="$(jq -r ".spec.containers[$i].resources.requests.cpu // \"\"" <<<"$pod_json")"
    mem_req="$(jq -r ".spec.containers[$i].resources.requests.memory // \"\"" <<<"$pod_json")"
    cpu_lim="$(jq -r ".spec.containers[$i].resources.limits.cpu // \"\"" <<<"$pod_json")"
    mem_lim="$(jq -r ".spec.containers[$i].resources.limits.memory // \"\"" <<<"$pod_json")"
    if [[ -z "$cpu_req" || -z "$mem_req" || -z "$cpu_lim" || -z "$mem_lim" ]]; then
      echo "error: $namespace/$pod container $container_name is missing CPU or memory requests/limits"
      exit 1
    fi
  done
}

demo_pods=()
while IFS= read -r line; do
  [[ -n "$line" ]] && demo_pods+=("$line")
done < <(kubectl get pod --namespace "$demo_namespace" -l app.kubernetes.io/part-of=vault-postgres-security-demo -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

vault_pods=()
while IFS= read -r line; do
  [[ -n "$line" ]] && vault_pods+=("$line")
done < <(kubectl get pod --namespace "$vault_namespace" -l app.kubernetes.io/part-of=vault-postgres-security-demo -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [[ "${#demo_pods[@]}" -eq 0 ]]; then
  echo "error: no demo Pods labeled with the demo's part-of label were found"
  exit 1
fi
if [[ "${#vault_pods[@]}" -eq 0 ]]; then
  echo "error: no vault Pods labeled with the demo's part-of label were found"
  exit 1
fi

for pod in "${demo_pods[@]}"; do
  check_pod_hardening "$demo_namespace" "$pod"
done
echo "ok: all demo Pods are non-root, drop ALL caps, set seccomp, and have resource limits"

for pod in "${vault_pods[@]}"; do
  check_pod_hardening "$vault_namespace" "$pod"
done
echo "ok: all vault Pods are non-root, drop ALL caps, set seccomp, and have resource limits"

app_pod="$(kubectl get pod --namespace "$demo_namespace" -l app.kubernetes.io/name=python-postgres-demo -o jsonpath='{.items[0].metadata.name}')"

ro_root="$(kubectl get pod "$app_pod" --namespace "$demo_namespace" -o jsonpath='{.spec.containers[?(@.name=="app")].securityContext.readOnlyRootFilesystem}')"
if [[ "$ro_root" != "true" ]]; then
  echo "error: app container does not have readOnlyRootFilesystem=true"
  exit 1
fi
echo "ok: app container runs with a read-only root filesystem"

if kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- sh -c 'echo x > /etc/intrusion 2>/dev/null && echo wrote' | grep -q wrote; then
  echo "error: app container can write to / despite readOnlyRootFilesystem"
  exit 1
fi
echo "ok: app container cannot write to / at runtime"

uid="$(kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- id -u)"
if [[ "$uid" == "0" ]]; then
  echo "error: app container is running as UID 0"
  exit 1
fi
echo "ok: app container runtime UID is $uid (non-root)"

kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- python -c '
import json
import urllib.request

with urllib.request.urlopen("http://127.0.0.1:8080/db-identity", timeout=10) as response:
    payload = json.loads(response.read().decode())
assert payload["current_user"].startswith("v-"), payload
print(payload["current_user"])
' | grep -q '^v-'
echo "ok: app still reaches PostgreSQL with Vault-issued runtime credentials"

kubectl exec --namespace "$demo_namespace" "$app_pod" -c app -- python -c '
import json
import urllib.request

req = urllib.request.Request(
    "http://127.0.0.1:8080/security/prove-denied",
    data=b"{}",
    method="POST",
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=10) as response:
    payload = json.loads(response.read().decode())
assert payload["create_role"]["allowed"] is False, payload
assert payload["drop_table"]["allowed"] is False, payload
'
echo "ok: app still proves forbidden DB operations are denied (DROP/CREATE ROLE)"

echo "Phase 13 container hardening verification passed."
