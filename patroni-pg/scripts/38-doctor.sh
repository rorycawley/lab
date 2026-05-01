#!/usr/bin/env bash
set -uo pipefail

fail=0
warn=0

ok()    { printf "  \xe2\x9c\x93 %s\n" "$1"; }
nope()  { printf "  \xe2\x9c\x97 %s\n" "$1"; fail=$((fail + 1)); }
info()  { printf "  \xe2\x80\xa2 %s\n" "$1"; }
wrn()   { printf "  ! %s\n" "$1"; warn=$((warn + 1)); }

echo "Phase 16 doctor: preflight check."
echo

echo "Required tools:"
for tool in kubectl docker helm jq openssl terraform; do
  if command -v "$tool" >/dev/null 2>&1; then
    version="$("$tool" --version 2>/dev/null | head -1 || true)"
    ok "$tool present (${version:-unknown version})"
  else
    nope "$tool is not installed or not on PATH"
  fi
done

echo
echo "Cluster:"
if kubectl config current-context >/dev/null 2>&1; then
  ctx="$(kubectl config current-context)"
  ok "kubectl current-context is $ctx"
else
  nope "no kubectl current-context set"
fi

if kubectl cluster-info >/dev/null 2>&1; then
  ok "Kubernetes API is reachable"
else
  nope "Kubernetes API is not reachable from this context"
fi

echo
echo "Docker:"
if docker info >/dev/null 2>&1; then
  ok "docker daemon is responsive"
else
  nope "docker daemon is not responsive"
fi

if docker compose version >/dev/null 2>&1; then
  ok "docker compose plugin available"
else
  nope "docker compose plugin not available"
fi

echo
echo "Workspace:"
if [[ -d .runtime || -w . ]]; then
  ok ".runtime/ is writable (or this directory is writable)"
else
  nope "current directory is not writable"
fi

if [[ -d terraform ]]; then
  ok "terraform/ module present"
else
  nope "terraform/ module is missing; Phase 16 needs it"
fi

echo
echo "Optional:"
if getent hosts host.rancher-desktop.internal >/dev/null 2>&1 \
  || dscacheutil -q host -a name host.rancher-desktop.internal 2>/dev/null | grep -q ip_address; then
  ok "host.rancher-desktop.internal resolves on this machine"
else
  wrn "host.rancher-desktop.internal does not resolve on this machine; resolution from inside the cluster is what actually matters"
fi

avail_kb=$(df -k . 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -n "$avail_kb" ]]; then
  if (( avail_kb > 1048576 )); then
    ok "more than 1 GB free in $(pwd)"
  else
    wrn "less than 1 GB free in $(pwd); the demo builds container images and may run short"
  fi
fi

echo
if (( fail > 0 )); then
  echo "doctor: $fail required checks failed, $warn warnings"
  exit 1
fi
if (( warn > 0 )); then
  echo "doctor: ok with $warn warnings"
else
  echo "doctor: ok"
fi
