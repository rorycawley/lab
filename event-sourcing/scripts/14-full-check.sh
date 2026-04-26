#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  echo
  echo "Running cleanup after full-check..."
  make clean
}
trap cleanup EXIT

make up
make test-all
make verify-db

echo
echo "full-check passed."
