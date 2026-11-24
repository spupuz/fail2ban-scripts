#!/bin/bash
# Regression test for the IP validation of scripts/fail2ban-telegram.sh.
#
# The helpers reverse_dns_lookup() and get_geo_location() used to gate the
# value with a loose bash regex (^[0-9a-fA-F:.]+$), which also accepted
# malformed addresses such as leading-zero octets ("01.2.3.4", "1.2.3.04").
# Those values then reached socket.gethostbyaddr() and the ipapi.co URL.
#
# The gate is now the strict python3 ipaddress parser (is_valid_ip), the same
# one the top-level argument check uses. This test asserts that:
#   - malformed values never trigger a DNS lookup or a geo API call,
#   - private / loopback / link-local / reserved / multicast values never do
#     either (no hostname or location leak for internal addresses),
#   - a real public IP still gets both lookups (no functional regression).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-ip-validation.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "SKIP python3 not found"; exit 0; }

# --- stubs: curl/jq succeed, python3 is wrapped to log its arguments -------
mkdir -p "$TMP/bin" "$TMP/py"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/curl"
printf '#!/bin/bash\ncat >/dev/null; printf "{}\\n"\n' > "$TMP/bin/jq"
chmod +x "$TMP/bin/curl" "$TMP/bin/jq"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$POC_LOG"\nexec /usr/bin/python3 "$@"\n' \
  > "$TMP/py/python3"
chmod +x "$TMP/py/python3"

# The functions under test live above the argument-handling section; cut the
# file there so the harness can call send_msg directly.
sed -n '1,281p' scripts/fail2ban-telegram.sh > "$TMP/lib.sh"
cat >> "$TMP/lib.sh" <<'LIB'
# Credentials are irrelevant here: the curl stub swallows the request. Kept as
# placeholders so the repository secret scanner does not flag this file.
API_TOKEN="__TELEGRAM_BOT_TOKEN_NOTIFY__"; CHAT_ID="__TELEGRAM_CHAT_ID_NOTIFY__"
TELEGRAM_URL="https://invalid"
send_msg ban "$POC_IP"
LIB

export PATH="$TMP/py:$TMP/bin:$PATH" POC_LOG="$TMP/log"

run_ip() { # $1 = ip -> sets DNS_CALLS / GEO_CALLS
  : > "$POC_LOG"
  POC_IP="$1" bash "$TMP/lib.sh" >/dev/null 2>&1
  DNS_CALLS="$(grep -c 'gethostbyaddr' "$POC_LOG" 2>/dev/null || true)"
  GEO_CALLS="$(grep -c 'ipapi.co' "$POC_LOG" 2>/dev/null || true)"
}

expect_no_lookup() { # $1 = ip, $2 = label
  run_ip "$1"
  if [[ "$DNS_CALLS" == "0" && "$GEO_CALLS" == "0" ]]; then
    echo "OK   no DNS/geo lookup for $2 ($1)"
  else
    echo "FAIL $2 ($1) reached DNS=$DNS_CALLS geo=$GEO_CALLS"
    fail=1
  fi
}

# --- 1. malformed addresses must not reach the network ---------------------
for ip in 1.2.3.04 01.2.3.4 010.1.1.1 999.999.999.999 1.2.3 1.2.3.4.5 \
          1.2.3.4:80 256.1.1.1 "" "not-an-ip" "1.2.3.4/24"; do
  expect_no_lookup "$ip" "malformed"
done

# --- 2. internal addresses must not be resolved or geo-located ------------
for ip in 10.0.0.1 127.0.0.1 192.168.1.10 172.16.0.1 169.254.1.1 \
          224.0.0.1 ::1 fe80::1 fc00::1 2001:db8::1; do
  expect_no_lookup "$ip" "non-public"
done

# --- 3. a real public IP still gets both lookups (no regression) ----------
run_ip 8.8.8.8
if [[ "$DNS_CALLS" -ge 1 && "$GEO_CALLS" -ge 1 ]]; then
  echo "OK   public IP 8.8.8.8 still resolves and geo-locates"
else
  echo "FAIL public IP 8.8.8.8 did not reach DNS=$DNS_CALLS geo=$GEO_CALLS"
  fail=1
fi

# --- 4. static guard: the loose regex must be gone ------------------------
if grep -q '\[\[ "\$1" =~ \^\[0-9a-fA-F:\]\+\$ \]\]' scripts/fail2ban-telegram.sh; then
  echo "FAIL the loose ^[0-9a-fA-F:.]+$ IP regex is still used"
  fail=1
else
  echo "OK   no loose IPv4/IPv6 regex gate left"
fi

# --- 5. the strict parser is the single source of truth -------------------
if grep -q 'is_valid_ip' scripts/fail2ban-telegram.sh; then
  echo "OK   is_valid_ip helper is used"
else
  echo "FAIL is_valid_ip helper missing"
  fail=1
fi

[[ $fail -eq 0 ]] && echo "IP validation checks passed."
exit $fail