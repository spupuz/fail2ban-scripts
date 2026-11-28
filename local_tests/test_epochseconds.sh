#!/bin/bash
# Regression test for the EPOCHSECONDS optimization in
# scripts/fail2ban-telegram.sh.
#
# send_msg() used to spawn `date +%s` twice per ban/unban action (once to
# write the ban-start timestamp, once to read "now" when computing the
# duration). Each call forks a subprocess. Under fail2ban's synchronous
# action queue that overhead is paid on every ban/unban.
#
# Bash 5+ exposes EPOCHSECONDS as a built-in integer variable that is
# refreshed on every access, so `date +%s` can be replaced with $EPOCHSECONDS
# with zero behaviour change (second precision is all that is stored).
#
# This test asserts:
#   1. no `date +%s` subprocess call remains in send_msg
#   2. the ban/unban duration is still computed correctly
#   3. the ban-start timestamp file is still written and cleaned up
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SCRIPT="scripts/fail2ban-telegram.sh"
fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-epochseconds.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- extract send_msg from the shipped script ------------------------------
extract_function() { # $1 = file, $2 = function name
  awk -v fn="$2" '
    $0 ~ "^function " fn " \\{" { p = 1 }
    p { print }
    p && /^}$/ { exit }
  ' "$1"
}

extract_function "$SCRIPT" send_msg > "$TMP/send_msg.sh"
if [[ ! -s "$TMP/send_msg.sh" ]]; then
  echo "FAIL could not extract send_msg() from $SCRIPT"
  exit 1
fi

# --- fixtures: curl stub, lookups stubbed for speed ------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
printf '200'
STUB
chmod +x "$TMP/bin/curl"

TELEGRAM_URL="https://example.invalid/sendMessage"
CHAT_ID="__CHAT_ID__"
PATH="$TMP/bin:$PATH"
export TELEGRAM_URL CHAT_ID PATH

echo "=== test 1: no date +%s subprocess call in send_msg ==="
# Strip comments first so prose mentioning 'date +%s' cannot trip the guard.
if awk '{ line=$0; sub(/^[[:space:]]*#.*$/, "", line); print line }' "$TMP/send_msg.sh" | grep -q 'date +%s'; then
  echo "FAIL send_msg still calls 'date +%s' (subprocess per ban/unban)"
  fail=1
else
  echo "  OK"
fi

echo "=== test 2: ban/unban duration still computed correctly ==="
(
  set -uo pipefail

  reverse_dns_lookup() { echo "dns"; }
  get_geo_location() { echo "geo"; }
  escape_html() { printf '%s' "$1"; }
  format_message() {
    # $7 = banned_duration; surface it so the test can read it.
    printf 'banned=%s' "${7:-}"
  }

  # shellcheck disable=SC1090
  . "$TMP/send_msg.sh"

  export FAIL2BAN_DATA_DIR="$TMP/data"
  mkdir -p "$FAIL2BAN_DATA_DIR"

  # format_message runs inside a command-substitution subshell, so its stdout
  # is captured into the message, not propagated. Use a side-channel file.
  : > "$TMP/fmt_out"
  format_message() {
    printf 'banned=%s' "${7:-}" > "$TMP/fmt_out"
    printf 'msg'
  }

  # Simulate a ban that started 120 seconds ago by pre-seeding the store file.
  # The store file name is derived from the IP with non-hex chars replaced.
  store_dir="$FAIL2BAN_DATA_DIR/fail2ban-bantimes"
  mkdir -p "$store_dir"
  printf '%s' "$(( EPOCHSECONDS - 120 ))" > "$store_dir/203.0.113.9"

  send_msg unban "203.0.113.9" >/dev/null 2>&1
  rc=$?
  out="$(cat "$TMP/fmt_out")"
  printf '  send_msg_rc=%s out=%s\n' "$rc" "$out"
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL send_msg unban failed (rc=$rc)"
    exit 1
  fi
  # Duration must be a positive number of seconds (allow 119..121 for timing).
  if [[ "$out" =~ banned=([0-9]+) ]]; then
    dur="${BASH_REMATCH[1]}"
    if (( dur >= 119 && dur <= 121 )); then
      echo "  OK duration=$dur"
    else
      echo "FAIL duration out of range: $dur"
      exit 1
    fi
  else
    echo "FAIL could not parse duration from: $out"
    exit 1
  fi
  # The store file must be cleaned up after unban.
  if [[ -f "$store_dir/203.0.113.9" ]]; then
    echo "FAIL store file not removed after unban"
    exit 1
  fi
  echo "  OK"
) || fail=1

echo "=== test 3: ban action writes the timestamp file ==="
(
  set -uo pipefail

  reverse_dns_lookup() { echo "dns"; }
  get_geo_location() { echo "geo"; }
  escape_html() { printf '%s' "$1"; }
  format_message() { printf 'msg'; }

  # shellcheck disable=SC1090
  . "$TMP/send_msg.sh"

  export FAIL2BAN_DATA_DIR="$TMP/data2"
  mkdir -p "$FAIL2BAN_DATA_DIR"

  send_msg ban "203.0.113.10" >/dev/null 2>&1
  rc=$?
  store_file="$FAIL2BAN_DATA_DIR/fail2ban-bantimes/203.0.113.10"
  printf '  send_msg_rc=%s\n' "$rc"
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL send_msg ban failed (rc=$rc)"
    exit 1
  fi
  if [[ ! -f "$store_file" ]]; then
    echo "FAIL ban did not write the timestamp file"
    exit 1
  fi
  # The stored value must be a plausible epoch (10 digits).
  stored="$(cat "$store_file")"
  if [[ "$stored" =~ ^[0-9]{10}$ ]]; then
    echo "  OK stored=$stored"
  else
    echo "FAIL stored value not a 10-digit epoch: $stored"
    exit 1
  fi
  echo "  OK"
) || fail=1

if [[ "$fail" -eq 0 ]]; then
  echo
  echo "✅ EPOCHSECONDS optimization tests passed."
  exit 0
fi

echo
echo "❌ EPOCHSECONDS optimization tests failed."
exit 1