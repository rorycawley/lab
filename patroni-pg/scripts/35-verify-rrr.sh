#!/usr/bin/env bash
set -euo pipefail

echo "Phase 15: rotation, revocation, and recovery drills."

./scripts/31-verify-rotation.sh
./scripts/32-verify-revocation.sh
./scripts/33-verify-recovery.sh

echo "Phase 15 verify-rrr passed: rotation + revocation + recovery."
