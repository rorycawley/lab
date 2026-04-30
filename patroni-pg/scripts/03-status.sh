#!/usr/bin/env bash
set -euo pipefail

echo "Namespaces:"
kubectl get namespaces demo vault database

echo ""
echo "ServiceAccounts in demo:"
kubectl get serviceaccounts --namespace demo

echo ""
echo "Effective permissions for demo/demo-app:"
kubectl auth can-i --list --namespace demo --as system:serviceaccount:demo:demo-app

echo ""
echo "PostgreSQL resources:"
docker compose --env-file .runtime/postgres.env ps postgres

echo ""
echo "Vault resources:"
kubectl get deployment,service,pod --namespace vault -l app.kubernetes.io/name=vault

echo ""
echo "Vault TokenReview identity:"
kubectl get serviceaccount vault-auth --namespace vault
