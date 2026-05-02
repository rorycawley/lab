#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  ./scripts/12-clean.sh || true
}
trap cleanup EXIT

make up
make test-all

