#!/bin/bash
# Regression test: the Telegram bot token must never appear in a curl argument.
#
# The bot token is embedded in the Telegram API URL
# (https://api.telegram.org/bot<TOKEN>/sendMessage). When that URL is passed to
# curl as a positional argument the token is visible in the process table
# (ps / /proc/<pid>/cmdline, world-readable on default Linux) and in any shell
# audit log. Any local user could read the token and hijack the bot.
#
# The fix feeds the URL to curl through a config read from stdin (`-K -`), so
# nothing secret is ever an argv element. This test:
#   1. static guard: no `curl ... "$TELEGRAM_URL"` positional use remains, and
#      the token-bearing URL is only ever written into a curl config block;
#   2. dynamic: runs the real send_msg() with a curl wrapper that records its
#      argv, and asserts the token is absent from that argv while the request is
#      still delivered (the URL reaches the server via the stdin config).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SCRIPT="scripts/fail2ban-telegram.sh"
fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-token-argv.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v curl >/dev/null 2>&1 || { echo "SKIP curl not found"; exit 0; }

# --- 1. static guard --------------------------------------------------------
# The token-bearing URL must not be a positional curl argument. It is only
# allowed inside a `url = "..."` config line (fed via -K -). Comments are
# stripped so prose cannot trip the guard.
awk '
  { line = $0; sub(/^[[:space:]]*#.*$/, "", line) }
  line ~ /curl/ && line ~ /\$TELEGRAM_URL/ {
    printf "FAIL %s:%d passes $TELEGRAM_URL as a curl argument: %s\n", FILENAME, FNR, $0
    bad = 1
  }
  END { exit bad }
' "$SCRIPT" || fail=1

if grep -q -- '-K -' "$SCRIPT"; then
  echo "OK   curl reads its config (with the secret URL) from stdin"
else
  echo "FAIL curl is not fed the URL via -K - (stdin config)"
  fail=1
fi

# --- 2. dynamic: token absent from curl argv, request still delivered -------
# Extract the real send_msg() so the test cannot pass against removed code.
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

TOKEN="123456:AASECRETtokenvalue_zzz999"

# A local HTTP server captures the request path (which carries the token) so we
# can prove the request is still delivered after the fix.
python3 - "$TMP" "$TOKEN" <<'PY' &
import http.server, sys, threading
tmp, token = sys.argv[1], sys.argv[2]
open(tmp + "/port", "w").write("0")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); self.rfile.read(n)
        open(tmp + "/path", "w").write(self.path)
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
open(tmp + "/port", "w").write(str(srv.server_address[1]))
srv.handle_request()
PY
srv_pid=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port" 2>/dev/null)"

# curl wrapper: record argv, then hand off to the real curl. The URL is fed via
# stdin config, so the token must NOT be in the recorded argv.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<WRAP
#!/bin/bash
printf '%s\n' "\$@" > "$TMP/curl_argv.txt"
exec /usr/bin/curl "\$@"
WRAP
chmod +x "$TMP/bin/curl"

(
  set -uo pipefail
  reverse_dns_lookup() { echo "dns"; }
  get_geo_location() { echo "geo"; }
  escape_html() { printf '%s' "$1"; }
  format_message() { printf 'msg'; }
  # shellcheck disable=SC1090
  . "$TMP/send_msg.sh"
  TELEGRAM_URL="http://127.0.0.1:${PORT}/bot${TOKEN}/sendMessage"
  CHAT_ID="__CHAT_ID__"
  export TELEGRAM_URL CHAT_ID
  PATH="$TMP/bin:$PATH"
  export PATH
  send_msg "ban" "203.0.113.7" >/dev/null 2>&1
) 
rc=$?
wait "$srv_pid" 2>/dev/null

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL send_msg returned $rc"
  fail=1
fi

ARGV="$(cat "$TMP/curl_argv.txt" 2>/dev/null)"
if [[ -z "$ARGV" ]]; then
  echo "FAIL curl was never invoked (no argv captured)"
  fail=1
elif grep -qF "$TOKEN" <<<"$ARGV"; then
  echo "FAIL token leaked into curl argv:"
  printf '%s\n' "$ARGV" | sed 's/^/    /'
  fail=1
else
  echo "OK   token absent from curl argv"
fi

SERVER_PATH="$(cat "$TMP/path" 2>/dev/null)"
if grep -qF "$TOKEN" <<<"$SERVER_PATH"; then
  echo "OK   request delivered with token in URL path (no functional regression)"
else
  echo "FAIL request did not reach the server with the token (path='$SERVER_PATH')"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo
  echo "✅ Telegram token argv-leak tests passed."
  exit 0
fi
echo
echo "❌ Telegram token argv-leak tests failed."
exit 1