#!/usr/bin/env bash
set -euo pipefail

kubectl -n migrations-demo port-forward service/migrations-demo-api 8080:8080

