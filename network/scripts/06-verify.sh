#!/usr/bin/env bash
set -euo pipefail

echo "Verifying namespaces..."
kubectl get namespace network-alpha >/dev/null
kubectl get namespace network-beta >/dev/null

echo "Verifying services, deployments, policies, and secrets..."
kubectl -n network-alpha get service alpha-app >/dev/null
kubectl -n network-beta get service beta-app >/dev/null
kubectl -n network-alpha get deployment alpha-app >/dev/null
kubectl -n network-beta get deployment beta-app >/dev/null
kubectl -n network-alpha get secret alpha-tls >/dev/null
kubectl -n network-beta get secret beta-tls >/dev/null
kubectl -n network-alpha get networkpolicy default-deny-all alpha-egress-dns alpha-egress-to-beta-only >/dev/null
kubectl -n network-beta get networkpolicy default-deny-all beta-ingress-from-alpha-app-only >/dev/null

echo "Verifying app pods are Ready..."
kubectl -n network-alpha rollout status deployment/alpha-app --timeout=120s
kubectl -n network-beta rollout status deployment/beta-app --timeout=120s

echo "Verify passed."
