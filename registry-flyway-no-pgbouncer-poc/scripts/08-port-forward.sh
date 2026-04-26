#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

kubectl port-forward -n registry-poc svc/registry-python-app 8080:8080 &
PF_PID=$!
wait "$PF_PID"
