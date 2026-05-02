#!/usr/bin/env bash
set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8443}"

echo "Forwarding https://localhost:${LOCAL_PORT} -> network-alpha/service/alpha-app:8443"
echo "Use curl -k https://localhost:${LOCAL_PORT}/call-peer"
kubectl -n network-alpha port-forward service/alpha-app "${LOCAL_PORT}:8443"
