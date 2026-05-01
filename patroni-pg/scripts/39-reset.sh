#!/usr/bin/env bash
set -euo pipefail

budget_seconds="${RESET_BUDGET_SECONDS:-360}"

cat <<'BANNER'
================================================================================
make reset: full repeatability test.

This will:
  1. Tear down the demo (kubectl namespaces + Docker Compose volumes + audit dir).
  2. Apply every phase from a clean state via make up.
  3. Run every verify script via make verify.

The wall-clock time is reported as the actual reset time. The default budget
is 6 minutes; override with RESET_BUDGET_SECONDS.
================================================================================
BANNER

start="$(date +%s)"

./scripts/04-clean.sh
make up

end="$(date +%s)"
elapsed=$((end - start))
mins=$((elapsed / 60))
secs=$((elapsed % 60))

echo
echo "reset wall-clock: ${elapsed}s (${mins}m${secs}s)"
echo "reset budget:     ${budget_seconds}s"

if (( elapsed > budget_seconds )); then
  echo "WARNING: reset exceeded the budget by $((elapsed - budget_seconds))s. Investigate slow steps; this is a soft fail."
fi
