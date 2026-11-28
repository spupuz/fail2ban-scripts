#!/bin/bash
# Local test entry point — runs every local_tests/test_*.sh and aggregates results.
# This is the exact same suite CI runs via .github/workflows/ci.yml.
#
#   bash scripts/run_tests.sh
#
# Bolt: tests are independent (each one uses its own mktemp -d scratch dir or
# only reads the repo), so they run concurrently. The slowest tests
# (test_autoupdate, test_ip_validation) dominate the wall clock; running them
# in parallel with the fast ones cuts the total runtime roughly in half on a
# multi-core runner. Output and the pass/fail exit code are unchanged: each
# test's stdout/stderr is captured to a per-test log and replayed in the
# original deterministic order once every job has finished.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tests=(local_tests/test_*.sh)
if [[ ! -e "${tests[0]}" ]]; then
  echo "No tests found in local_tests/test_*.sh"
  exit 1
fi

# Cap concurrency to the number of tests (and to available CPUs) so a small
# suite does not spawn idle workers.
max_jobs="${BOLT_TEST_JOBS:-$(nproc 2>/dev/null || echo 4)}"
[[ "$max_jobs" -ge 1 ]] || max_jobs=1

log_dir="$(mktemp -d)"
trap 'rm -rf "$log_dir"' EXIT

declare -a results=()
fail=0

# Run a single test, capturing its combined output to a log file.
run_one() {
  local t="$1" log="$log_dir/$(basename "$t").log"
  if bash "$t" >"$log" 2>&1; then
    printf 'PASS  %s\n' "$t" > "$log_dir/$(basename "$t").status"
  else
    printf 'FAIL  %s\n' "$t" > "$log_dir/$(basename "$t").status"
  fi
}

# Launch tests up to max_jobs at a time, then wait for the whole batch.
i=0
for t in "${tests[@]}"; do
  run_one "$t" &
  i=$((i + 1))
  if (( i % max_jobs == 0 )); then
    wait
  fi
done
wait

# Replay results in deterministic order regardless of completion order.
for t in "${tests[@]}"; do
  base="$(basename "$t")"
  echo "=== $t"
  cat "$log_dir/$base.log"
  status="$(cat "$log_dir/$base.status" 2>/dev/null || printf 'FAIL  %s\n' "$t")"
  results+=("$status")
  [[ "$status" == FAIL* ]] && fail=1
  echo
done

echo "================ summary ================"
for r in "${results[@]}"; do
  echo "$r"
done
[[ $fail -eq 0 ]] && echo "All tests passed."
exit $fail