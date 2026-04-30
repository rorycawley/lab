#!/usr/bin/env bash
set -euo pipefail

sa="system:serviceaccount:demo:demo-app"

require_ns() {
  local ns="$1"
  kubectl get namespace "$ns" >/dev/null
  echo "ok: namespace $ns exists"
}

require_cannot() {
  local verb="$1"
  local resource="$2"
  local namespace="$3"
  local result

  result="$(kubectl auth can-i "$verb" "$resource" --namespace "$namespace" --as "$sa" 2>&1 || true)"

  if [[ "$result" == "no" ]]; then
    echo "ok: demo/demo-app cannot $verb $resource in namespace $namespace"
  elif [[ "$result" == "yes" ]]; then
    echo "error: demo/demo-app can $verb $resource in namespace $namespace"
    exit 1
  else
    echo "error: unexpected kubectl auth response for $verb $resource in namespace $namespace: $result"
    exit 1
  fi
}

require_ns demo
require_ns vault
require_ns database

kubectl get serviceaccount demo-app --namespace demo >/dev/null
echo "ok: ServiceAccount demo/demo-app exists"

require_cannot list secrets demo
require_cannot list pods demo
require_cannot get configmaps demo
require_cannot list secrets vault
require_cannot list pods database

echo "Phase 1 verification passed."
