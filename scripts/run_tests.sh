#!/bin/bash
# Local test entry point — runs every scripts/test_*.sh and aggregates results.
# This is the exact same suite CI runs via .github/workflows/ci.yml.
#
#   bash scripts/run_tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tests=(scripts/test_*.sh)
if [[ ! -e "${tests[0]}" ]]; then
  echo "No tests found in scripts/test_*.sh"
  exit 1
fi

fail=0
declare -a results=()
for t in "${tests[@]}"; do
  echo "=== $t"
  if bash "$t"; then
    results+=("PASS  $t")
  else
    results+=("FAIL  $t")
    fail=1
  fi
  echo
done

echo "================ summary ================"
for r in "${results[@]}"; do
  echo "$r"
done
[[ $fail -eq 0 ]] && echo "All tests passed."
exit $fail
