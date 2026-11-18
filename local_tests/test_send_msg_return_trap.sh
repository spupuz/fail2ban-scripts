#!/bin/bash
# Regression test for the RETURN trap leaked by send_msg() in
# scripts/fail2ban-telegram.sh.
#
# send_msg() created two temporary files and installed a cleanup trap with
# `trap 'rm -f "$dns_tmp" "$geo_tmp"' RETURN`. A RETURN trap installed inside a
# function is not scoped to that function: once set it also fires when the
# CALLER returns, and when any function the caller invokes later returns.
#
# fail2ban calls the script as `fail2ban-telegram.sh ban <ip>`, i.e. send_msg()
# returns into the top-level `case` and the shell then exits, so in production
# the damage was bounded. But the trap is a live landmine for every other
# caller: the second firing runs with dns_tmp/geo_tmp unset, and under
# `set -u` that aborts the caller at the exact moment it returns a value.
#
# The fix removes the RETURN trap and deletes both files explicitly before
# send_msg() returns. This test extracts the real function from the shipped
# script, runs it with `set -Eeuo pipefail` inside a caller that has a local of
# its own, and asserts:
#   1. the temp files are gone after send_msg() returns
#   2. the caller's own locals survive (no stray trap firing)
#   3. the caller's return value is still 0
#   4. no RETURN trap remains installed
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SCRIPT="scripts/fail2ban-telegram.sh"
fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-return-trap-test.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- extract the real function under test ----------------------------------
# Extracted instead of re-implemented so the test cannot pass against code that
# no longer exists in the script.
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

# --- fixtures ---------------------------------------------------------------
# curl is stubbed so the test never touches the network and the HTTP status is
# deterministic. reverse_dns_lookup/get_geo_location are stubbed for speed.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
# Emit a 200 status and swallow the body, like the real curl flags do.
printf '200'
STUB
chmod +x "$TMP/bin/curl"

# TELEGRAM_URL is set to a non-secret dummy so the test never touches the
# network. CHAT_ID is deliberately a __PLACEHOLDER__ value: this repo's secret
# scanner rejects literal values assigned to credential-like names, and
# __NAME__ is the placeholder form it explicitly allows.
TELEGRAM_URL="https://example.invalid/sendMessage"
CHAT_ID="__CHAT_ID__"
PATH="$TMP/bin:$PATH"
export TELEGRAM_URL CHAT_ID PATH

echo "=== test 1: send_msg() leaves no RETURN trap and preserves caller locals ==="
(
  set -Eeuo pipefail

  reverse_dns_lookup() { echo "dns"; }
  get_geo_location() { echo "geo"; }
  escape_html() { printf '%s' "$1"; }
  format_message() { printf 'msg'; }

  # shellcheck disable=SC1090  # extracted at runtime from the script under test
  . "$TMP/send_msg.sh"

  caller() {
    local caller_marker="caller-alive"
    if ! send_msg "ban" "203.0.113.7"; then
      echo "  send_msg reported failure"
      return 1
    fi
    # A stray RETURN trap fires here, before the lines below run, with dns_tmp
    # and geo_tmp already out of scope. Under `set -u` that aborts the caller,
    # so reaching the marker at all is the assertion.
    printf '  caller_reached_marker=%s\n' "$caller_marker"
    return 0
  }

  caller
  rc=$?
  printf '  caller_rc=%s\n' "$rc"
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL caller aborted (rc=$rc) — the RETURN trap fired outside send_msg"
    exit 1
  fi
  if [[ "$(trap -p RETURN)" != "" ]]; then
    echo "FAIL a RETURN trap is still installed after send_msg: $(trap -p RETURN)"
    exit 1
  fi
  echo "  OK"
) || fail=1

echo "=== test 2: temp files are removed exactly once ==="
# send_msg must not leave the per-call temp files behind. Counted with a wrapper
# around mktemp so a missing cleanup cannot hide.
(
  set -uo pipefail

  reverse_dns_lookup() { echo "dns"; }
  get_geo_location() { echo "geo"; }
  escape_html() { printf '%s' "$1"; }
  format_message() { printf 'msg'; }
  # shellcheck disable=SC1090
  . "$TMP/send_msg.sh"

  created="$TMP/created"
  : > "$created"

  mktemp() {
    local f
    f="$(command mktemp "$TMP/tmp.XXXXXX")" || return 1
    printf '%s\n' "$f" >> "$created"
    printf '%s' "$f"
  }

  send_msg "ban" "203.0.113.8" >/dev/null 2>&1
  rc=$?
  leftover=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -e "$f" ]]; then
      echo "  leftover temp file: $f"
      leftover=1
    fi
  done < "$created"

  printf '  send_msg_rc=%s leftover=%s\n' "$rc" "$leftover"
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL send_msg failed (rc=$rc)"
    exit 1
  fi
  if [[ "$leftover" -ne 0 ]]; then
    echo "FAIL send_msg left a temp file behind"
    exit 1
  fi
  echo "  OK"
) || fail=1

echo "=== test 3: static guard — no RETURN trap may be installed inside a function ==="
# `trap ... RETURN` is not scoped to the function that installs it; a plain
# `rm -f` before returning is the correct pattern. Comments are stripped first
# so prose about the trap cannot trip the guard.
awk '
  { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
  line ~ /trap .* RETURN/ {
    printf "FAIL %s:%d installs a RETURN trap: %s\n", FILENAME, FNR, $0
    bad = 1
  }
  END { exit bad }
' "$SCRIPT" || fail=1

if [[ "$fail" -eq 0 ]]; then
  echo
  echo "✅ send_msg() return-trap tests passed."
  exit 0
fi

echo
echo "❌ send_msg() return-trap tests failed."
exit 1