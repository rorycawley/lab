#!/usr/bin/env bash
set -euo pipefail

echo "==> Namespaces"
kubectl get namespace network-alpha network-beta --ignore-not-found

echo
echo "==> Alpha"
kubectl -n network-alpha get pods,svc,secret,networkpolicy

echo
echo "==> Beta"
kubectl -n network-beta get pods,svc,secret,networkpolicy

echo
echo "==> Recent alpha logs"
kubectl -n network-alpha logs deployment/alpha-app --tail=20 2>/dev/null || true

echo
echo "==> Recent beta logs"
kubectl -n network-beta logs deployment/beta-app --tail=20 2>/dev/null || true
