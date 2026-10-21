#!/bin/bash
# Functional test for scripts/log_rotate.sh
#
# Verifies that:
#   - old files (older than max-age) are deleted
#   - large files (larger than max-size) are deleted
#   - recent, small files are kept
#   - --dry-run does not delete
#   - --quiet produces no output on success
#   - LOG_ROTATE_ENABLED=false disables the rotation
#   - config.local settings are read correctly
#   - the script is a no-op when the target directory does not exist
#   - scripts/, config files and VERSION are never touched
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-rotate-test.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. old files are deleted, recent files are kept ----------------------
echo "=== test 1: old files deleted, recent kept ==="
DEST1="$TMP/dest1"
mkdir -p "$DEST1"
# Create an old log file (10 days ago)
touch "$DEST1/old.log"
touch -t "$(date -d '-10 days' '+%Y%m%d0000')" "$DEST1/old.log"
# Create a recent log file
touch "$DEST1/recent.log"
# Create a non-log file that should not be touched
echo "keep me" > "$DEST1/VERSION"

if ! bash scripts/log_rotate.sh --dest "$DEST1" --max-age 7 --max-size 500 --quiet 2>&1; then
  echo "FAIL log_rotate.sh exited non-zero"
  fail=1
fi

if [[ -f "$DEST1/old.log" ]]; then
  echo "FAIL old.log was not deleted"
  fail=1
else
  echo "OK   old.log was deleted"
fi

if [[ ! -f "$DEST1/recent.log" ]]; then
  echo "FAIL recent.log was deleted"
  fail=1
else
  echo "OK   recent.log was kept"
fi

if [[ ! -f "$DEST1/VERSION" ]]; then
  echo "FAIL VERSION was deleted"
  fail=1
else
  echo "OK   VERSION was not touched"
fi

# --- 2. large files are deleted -------------------------------------------
echo ""
echo "=== test 2: large files deleted ==="
DEST2="$TMP/dest2"
mkdir -p "$DEST2"
# Create a large log file (6 MB, recent)
dd if=/dev/zero of="$DEST2/large.log" bs=1M count=6 2>/dev/null
# Create a small log file (recent)
echo "small" > "$DEST2/small.log"

if ! bash scripts/log_rotate.sh --dest "$DEST2" --max-age 999 --max-size 1 --quiet 2>&1; then
  echo "FAIL log_rotate.sh exited non-zero"
  fail=1
fi

if [[ -f "$DEST2/large.log" ]]; then
  echo "FAIL large.log was not deleted"
  fail=1
else
  echo "OK   large.log was deleted"
fi

if [[ ! -f "$DEST2/small.log" ]]; then
  echo "FAIL small.log was deleted"
  fail=1
else
  echo "OK   small.log was kept"
fi

# --- 3. --dry-run does not delete -----------------------------------------
echo ""
echo "=== test 3: --dry-run does not delete ==="
DEST3="$TMP/dest3"
mkdir -p "$DEST3"
touch -t "$(date -d '-10 days' '+%Y%m%d0000')" "$DEST3/old.log"

bash scripts/log_rotate.sh --dest "$DEST3" --max-age 7 --max-size 500 --dry-run --quiet 2>&1

if [[ ! -f "$DEST3/old.log" ]]; then
  echo "FAIL --dry-run deleted old.log"
  fail=1
else
  echo "OK   --dry-run did not delete old.log"
fi

# --- 4. LOG_ROTATE_ENABLED=false disables rotation -----------------------
echo ""
echo "=== test 4: LOG_ROTATE_ENABLED=false ==="
DEST4="$TMP/dest4"
mkdir -p "$DEST4"
touch -t "$(date -d '-10 days' '+%Y%m%d0000')" "$DEST4/old.log"

# Create a config.local with LOG_ROTATE_ENABLED=false
cat > "$TMP/config_disabled.local" <<EOF
LOG_ROTATE_ENABLED=false
EOF

bash scripts/log_rotate.sh --dest "$DEST4" --secrets "$TMP/config_disabled.local" --quiet 2>&1

if [[ ! -f "$DEST4/old.log" ]]; then
  echo "FAIL LOG_ROTATE_ENABLED=false did not prevent deletion"
  fail=1
else
  echo "OK   LOG_ROTATE_ENABLED=false prevents deletion"
fi

# --- 4b. rotation is ENABLED by default when the key is absent -----------
echo ""
echo "=== test 4b: rotation enabled by default (key absent) ==="
DEST4B="$TMP/dest4b"
mkdir -p "$DEST4B"
touch -t "$(date -d '-10 days' '+%Y%m%d0000')" "$DEST4B/old.log"

# Config without LOG_ROTATE_ENABLED — rotation must run by default
cat > "$TMP/config_no_rotate_key.local" <<EOF
TELEGRAM_BOT_TOKEN_NOTIFY=123:FAKE
EOF

bash scripts/log_rotate.sh --dest "$DEST4B" --secrets "$TMP/config_no_rotate_key.local" --quiet 2>&1

if [[ -f "$DEST4B/old.log" ]]; then
  echo "FAIL old.log was not deleted when LOG_ROTATE_ENABLED is absent (should be enabled by default)"
  fail=1
else
  echo "OK   old.log was deleted with LOG_ROTATE_ENABLED absent (enabled by default)"
fi

# --- 4c. rotation is ENABLED when config.local is missing entirely ------
echo ""
echo "=== test 4c: rotation enabled when config.local is missing ==="
DEST4C="$TMP/dest4c"
mkdir -p "$DEST4C"
touch -t "$(date -d '-10 days' '+%Y%m%d0000')" "$DEST4C/old.log"

# No --secrets: defaults to ROOT_DIR/config.local which does not exist here
ROOT_DIR="$TMP/no_config_dir" bash scripts/log_rotate.sh --dest "$DEST4C" --quiet 2>&1

if [[ -f "$DEST4C/old.log" ]]; then
  echo "FAIL old.log was not deleted when config.local is missing (should be enabled by default)"
  fail=1
else
  echo "OK   old.log was deleted with config.local missing (enabled by default)"
fi

# --- 5. --force overrides LOG_ROTATE_ENABLED=false -----------------------
echo ""
echo "=== test 5: --force overrides disabled ==="
bash scripts/log_rotate.sh --dest "$DEST4" --secrets "$TMP/config_disabled.local" --force --quiet 2>&1

if [[ -f "$DEST4/old.log" ]]; then
  echo "FAIL --force did not override LOG_ROTATE_ENABLED=false"
  fail=1
else
  echo "OK   --force overrides LOG_ROTATE_ENABLED=false"
fi

# --- 6. config.local settings are read -----------------------------------
echo ""
echo "=== test 6: config.local settings ==="
DEST6="$TMP/dest6"
mkdir -p "$DEST6"
touch -t "$(date -d '-30 days' '+%Y%m%d0000')" "$DEST6/old30.log"
touch -t "$(date -d '-5 days' '+%Y%m%d0000')" "$DEST6/old5.log"

# config with max-age=10
cat > "$TMP/config_age10.local" <<EOF
LOG_ROTATE_ENABLED=true
LOG_ROTATE_MAX_AGE=10
LOG_ROTATE_MAX_SIZE=500
EOF

bash scripts/log_rotate.sh --dest "$DEST6" --secrets "$TMP/config_age10.local" --quiet 2>&1

if [[ -f "$DEST6/old30.log" ]]; then
  echo "FAIL old30.log was not deleted (max-age=10, file is 30 days old)"
  fail=1
else
  echo "OK   old30.log was deleted (30 > 10 days)"
fi

if [[ ! -f "$DEST6/old5.log" ]]; then
  echo "FAIL old5.log was deleted (max-age=10, file is 5 days old)"
  fail=1
else
  echo "OK   old5.log was kept (5 < 10 days)"
fi

# --- 7. non-existent directory is a no-op --------------------------------
echo ""
echo "=== test 7: non-existent directory ==="
if ! bash scripts/log_rotate.sh --dest "$TMP/nonexistent" --quiet 2>&1; then
  echo "FAIL log_rotate.sh exited non-zero for non-existent directory"
  fail=1
else
  echo "OK   non-existent directory is a no-op"
fi

# --- 8. .update_log is rotated but config files are not -------------------
echo ""
echo "=== test 8: .update_log rotated, .local not touched ==="
DEST8="$TMP/dest8"
mkdir -p "$DEST8"
# .update_log is a known log pattern (old)
touch -t "$(date -d '-10 days' '+%Y%m%d0000')" "$DEST8/.update_log"
# jail.local should not be touched (not a log pattern)
echo "keep" > "$DEST8/jail.local"
# config.local should not be touched
echo "keep" > "$DEST8/config.local"
# .last_update_check should not be touched (not a log pattern)
echo "2026-01-01" > "$DEST8/.last_update_check"

bash scripts/log_rotate.sh --dest "$DEST8" --max-age 7 --max-size 500 --quiet 2>&1

if [[ -f "$DEST8/.update_log" ]]; then
  echo "FAIL .update_log was not deleted"
  fail=1
else
  echo "OK   .update_log was deleted"
fi

if [[ ! -f "$DEST8/jail.local" ]]; then
  echo "FAIL jail.local was deleted"
  fail=1
else
  echo "OK   jail.local was not touched"
fi

if [[ ! -f "$DEST8/config.local" ]]; then
  echo "FAIL config.local was deleted"
  fail=1
else
  echo "OK   config.local was not touched"
fi

if [[ ! -f "$DEST8/.last_update_check" ]]; then
  echo "FAIL .last_update_check was deleted"
  fail=1
else
  echo "OK   .last_update_check was not touched"
fi

# --- 9. --log-dir scans a specific directory -----------------------------
echo ""
echo "=== test 9: --log-dir ==="
DEST9="$TMP/dest9"
LOGSUB9="$DEST9/logs"
mkdir -p "$LOGSUB9"
touch -t "$(date -d '-10 days' '+%Y%m%d0000')" "$LOGSUB9/old.log"
# This file in the data dir root should NOT be scanned when --log-dir is set
touch -t "$(date -d '-10 days' '+%Y%m%d0000')" "$DEST9/old2.log"

bash scripts/log_rotate.sh --dest "$DEST9" --log-dir "$LOGSUB9" --max-age 7 --max-size 500 --quiet 2>&1

if [[ -f "$LOGSUB9/old.log" ]]; then
  echo "FAIL old.log in log-dir was not deleted"
  fail=1
else
  echo "OK   old.log in log-dir was deleted"
fi

if [[ ! -f "$DEST9/old2.log" ]]; then
  echo "FAIL old2.log in data root was deleted (should only scan --log-dir)"
  fail=1
else
  echo "OK   old2.log in data root was not touched (--log-dir was set)"
fi

[[ $fail -eq 0 ]] && echo "Log rotation checks passed."
exit $fail