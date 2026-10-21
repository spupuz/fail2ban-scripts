#!/bin/bash
# Functional test for the config.local loader used by scripts/ignorehost.sh.
#
# The loader must:
#   - parse the shell-style KEY=VALUE config file WITHOUT executing it: a real
#     Telegram bot token ("123456789:AAE...") is not a valid Python expression,
#     so the previous exec()-based loader raised a SyntaxError and silently
#     disabled the whitelist,
#   - extract the ALLOWED_DOMAINS / ALLOWED_HOSTS list literals,
#   - keep the built-in placeholders when the file is missing or malformed,
#     while reporting the problem on stderr.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-cfg-test.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake credentials: they look like the real thing (a bot token contains a
# colon) but are not usable anywhere.
TOKEN="123456789:FAKEFAKEFAKEFAKEFAKEFAKEFAKE0"
CHAT="-1001234567890"

mkdir -p "$TMP/good/scripts" "$TMP/empty/scripts" "$TMP/broken/scripts"

cat > "$TMP/good/config.local" <<EOF
# host specific configuration
TELEGRAM_BOT_TOKEN_NOTIFY=${TOKEN}
TELEGRAM_CHAT_ID_NOTIFY=${CHAT}
TELEGRAM_BOT_TOKEN_IGNOREHOST=${TOKEN}
TELEGRAM_CHAT_ID_IGNOREHOST=${CHAT}
FAIL2BAN_UI_CALLBACK_SECRET=${TOKEN}
AUTO_UPDATE_ENABLED=true

ALLOWED_DOMAINS = [
    "home.example.org",
    "vpn.example.net",
]

ALLOWED_HOSTS = [
    ".isp.example.it",
]
EOF

cat > "$TMP/broken/config.local" <<EOF
ALLOWED_DOMAINS = [
    "home.example.org",
ALLOWED_HOSTS = "not-a-list"
EOF

python3 - "$TMP" "$ROOT" <<'PY'
import ast
import os
import sys
import types

tmp, root = sys.argv[1], sys.argv[2]
SCRIPT = os.path.join(root, "scripts", "ignorehost.sh")

# --- stub the fail2ban runtime: the script imports fail2ban.server.ipdns,
# --- which is only available inside the fail2ban container.
pkg = types.ModuleType("fail2ban")
server = types.ModuleType("fail2ban.server")
ipdns = types.ModuleType("fail2ban.server.ipdns")


class IPAddr:
    def __init__(self, ip):
        self.isValid = True


ipdns.IPAddr = IPAddr
ipdns.DNSUtils = type("DNSUtils", (), {"ipToName": staticmethod(lambda ip: None)})
server.ipdns = ipdns
pkg.server = server
sys.modules.update(
    {"fail2ban": pkg, "fail2ban.server": server, "fail2ban.server.ipdns": ipdns}
)

failures = []


def check(condition, message):
    if condition:
        print(f"OK   {message}")
    else:
        print(f"FAIL {message}")
        failures.append(message)


def load(config_dir):
    """Execute ignorehost.sh with __file__ inside <config_dir>/scripts."""
    source = open(SCRIPT).read()
    namespace = {
        "__name__": "ignorehost_test",
        "__file__": os.path.join(config_dir, "scripts", "ignorehost.sh"),
    }
    exec(compile(source, SCRIPT, "exec"), namespace)
    return namespace


# --- 1. a complete config file is parsed, secrets included --------------
ns = load(os.path.join(tmp, "good"))
check(
    ns["ALLOWED_DOMAINS"] == ["home.example.org", "vpn.example.net"],
    f"ALLOWED_DOMAINS parsed: {ns['ALLOWED_DOMAINS']}",
)
check(
    ns["ALLOWED_HOSTS"] == [".isp.example.it"],
    f"ALLOWED_HOSTS parsed: {ns['ALLOWED_HOSTS']}",
)
check(
    ns["TELEGRAM_API_TOKEN"].startswith("__"),
    "Telegram token still comes from the deploy-time placeholder",
)

# --- 2. the old exec() based loader really was broken -------------------
# The config file is shell-style, not Python: exec() on it raises.
content = open(os.path.join(tmp, "good", "config.local")).read()
try:
    exec(compile(content, "config.local", "exec"), {})
    check(False, "exec() of config.local raises SyntaxError (as expected)")
except SyntaxError:
    check(True, "exec() of config.local raises SyntaxError (as expected)")

# --- 3. a missing config keeps the built-in placeholders ----------------
ns = load(os.path.join(tmp, "empty"))
check(
    all("placeholder" in d for d in ns["ALLOWED_DOMAINS"]),
    "missing config.local keeps the placeholder domains",
)
check(
    all("placeholder" in h for h in ns["ALLOWED_HOSTS"]),
    "missing config.local keeps the placeholder hosts",
)

# --- 4. a malformed config keeps the built-in placeholders --------------
ns = load(os.path.join(tmp, "broken"))
check(
    all("placeholder" in d for d in ns["ALLOWED_DOMAINS"]),
    "malformed ALLOWED_DOMAINS keeps the placeholder domains",
)
check(
    all("placeholder" in h for h in ns["ALLOWED_HOSTS"]),
    "malformed ALLOWED_HOSTS keeps the placeholder hosts",
)

# --- 5. brackets inside strings do not confuse the parser ---------------
tricky = 'ALLOWED_DOMAINS = [\n    "a]b.example.org",\n    "c.example.org",\n]\n'
src = open(SCRIPT).read()
tree = ast.parse(src)
segments = [
    ast.get_source_segment(src, node)
    for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "_parse_list_assignment"
]
check(len(segments) == 1, "_parse_list_assignment is defined at module level")
helper = {}
exec(
    "import ast as _ast\nimport os as _os\nimport re as _re\nimport sys\n" + segments[0],
    helper,
)
check(
    helper["_parse_list_assignment"](tricky, "ALLOWED_DOMAINS")
    == ["a]b.example.org", "c.example.org"],
    "a bracket inside a string does not break the parser",
)
check(
    helper["_parse_list_assignment"](
        'ALLOWED_HOSTS = [\n    ".x.example.it",\n]\n', "ALLOWED_HOSTS"
    )
    == [".x.example.it"],
    "a well formed list is parsed",
)
check(
    helper["_parse_list_assignment"]("ALLOWED_HOSTS = \"nope\"\n", "ALLOWED_HOSTS")
    is None,
    "a non list value is rejected",
)
check(
    helper["_parse_list_assignment"]("SOMETHING = []\n", "ALLOWED_DOMAINS") is None,
    "an absent key returns None",
)
check(
    helper["_parse_list_assignment"](
        'ALLOWED_DOMAINS = "not-a-list"\nALLOWED_HOSTS = [\n    ".x.example.it",\n]\n',
        "ALLOWED_DOMAINS",
    )
    is None,
    "a non list value does not pick up the list of another key",
)

sys.exit(1 if failures else 0)
PY

if [[ $? -ne 0 ]]; then
  fail=1
fi

[[ $fail -eq 0 ]] && echo "ignorehost config loader checks passed."
exit $fail
