#!/usr/bin/env bash
set -euo pipefail

kubectl delete namespace demo vault database --ignore-not-found=true

echo "Phase 1 namespaces removed."

