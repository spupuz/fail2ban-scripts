#!/bin/bash
# Functional test for the automatic update chain.
#
# The chain is:
#   scripts/fail2ban-telegram.sh (ban/unban notification)  \
#   scripts/ignorehost.sh        (ignore notification)      >-- trigger
#   scripts/version_check.sh  --dest <data dir>  -> install release and deploy
#   it (the secrets are injected by the updater itself) into the data dir.
#
# This test verifies, without touching the network:
#   - both notification scripts trigger the updater, detached, when
#     FAIL2BAN_DATA_DIR points to the deployed data directory,
#   - the trigger is a no-op when the variable is unset or the updater is
#     missing,
#   - the updater honours AUTO_UPDATE_ENABLED and the daily throttle,
#   - the deploy step injects the secrets into the scripts that consume them
#     and leaves the helper scripts as templates (they never hold a secret),
#   - the configuration files are only deployed with --with-config,
#   - files are replaced atomically, keeping their permissions,
#   - deploy.sh refuses to inject the secrets into a git checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-autoupdate-test.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake credentials: they look like the real thing but are not usable anywhere.
FAKE_NOTIFY_TOKEN="123456789:FAKEFAKEFAKEFAKEFAKEFAKEFAKE0"
FAKE_NOTIFY_CHAT="-1001234567890"
FAKE_IGNORE_TOKEN="987654321:FAKEFAKEFAKEFAKEFAKEFAKEFAKE0"
FAKE_IGNORE_CHAT="-1009876543210"
FAKE_CALLBACK="FAKE_CALLBACK_SECRET_FOR_TESTS_ONLY"

FAKE_SECRETS="$TMP/config.local"
cat > "$FAKE_SECRETS" <<EOF
TELEGRAM_BOT_TOKEN_NOTIFY=$FAKE_NOTIFY_TOKEN
TELEGRAM_CHAT_ID_NOTIFY=$FAKE_NOTIFY_CHAT
TELEGRAM_BOT_TOKEN_IGNOREHOST=$FAKE_IGNORE_TOKEN
TELEGRAM_CHAT_ID_IGNOREHOST=$FAKE_IGNORE_CHAT
FAIL2BAN_UI_CALLBACK_SECRET=$FAKE_CALLBACK
AUTO_UPDATE_ENABLED=true
EOF

# Extract a bash function (with or without the "function" keyword) so that it
# can be exercised in isolation.
extract_function() { # $1 = file, $2 = function name
  awk -v fn="$2" '
    !inside && ($0 ~ "^function[ \t]+" fn "[ \t]*\\{" || $0 ~ "^" fn "\\(\\) *\\{") { inside = 1 }
    inside { print }
    inside && /^\}/ { exit }
  ' "$1"
}

# Wait for a file to become non empty (the trigger runs in the background).
wait_for_file() { # $1 = file, $2 = max seconds
  local deadline=$(( SECONDS + ${2:-5} ))
  while (( SECONDS < deadline )); do
    [[ -s "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}

# --- fake updater used as scripts/version_check.sh in the data directory ---
DATA_DIR="$TMP/data"
mkdir -p "$DATA_DIR/scripts"
TRIGGER_LOG="$TMP/trigger.log"
export TRIGGER_LOG
cat > "$DATA_DIR/scripts/version_check.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TRIGGER_LOG"
EOF
chmod +x "$DATA_DIR/scripts/version_check.sh"

# --- 1. the telegram notifier triggers the updater ------------------------
TELEGRAM_TRIGGER="$(extract_function scripts/fail2ban-telegram.sh trigger_auto_update)"
if [[ -z "$TELEGRAM_TRIGGER" ]]; then
  echo "FAIL trigger_auto_update not found in scripts/fail2ban-telegram.sh"
  fail=1
else
  rm -f "$TRIGGER_LOG"
  FAIL2BAN_DATA_DIR="$DATA_DIR" bash -c "$TELEGRAM_TRIGGER
trigger_auto_update" || { echo "FAIL the telegram trigger returned an error"; fail=1; }
  if ! wait_for_file "$TRIGGER_LOG" 5; then
    echo "FAIL the telegram notifier did not trigger the updater"
    fail=1
  else
    echo "OK   the telegram notifier triggers the updater: $(cat "$TRIGGER_LOG")"
    if ! grep -q -- "--dest $DATA_DIR" "$TRIGGER_LOG"; then
      echo "FAIL the updater was not called with --dest $DATA_DIR"
      fail=1
    fi
    if ! grep -q -- "--quiet" "$TRIGGER_LOG"; then
      echo "FAIL the updater was not called with --quiet"
      fail=1
    fi
  fi

  # 1b. without FAIL2BAN_DATA_DIR nothing must be started
  rm -f "$TRIGGER_LOG"
  env -u FAIL2BAN_DATA_DIR bash -c "$TELEGRAM_TRIGGER
trigger_auto_update" || { echo "FAIL the telegram trigger returned an error"; fail=1; }
  sleep 0.5
  if [[ -s "$TRIGGER_LOG" ]]; then
    echo "FAIL the telegram notifier triggered the updater without FAIL2BAN_DATA_DIR"
    fail=1
  else
    echo "OK   the telegram notifier does nothing without FAIL2BAN_DATA_DIR"
  fi

  # 1c. a missing updater must not break the notification
  rm -f "$TRIGGER_LOG"
  EMPTY_DIR="$TMP/empty-data"
  mkdir -p "$EMPTY_DIR/scripts"
  FAIL2BAN_DATA_DIR="$EMPTY_DIR" bash -c "$TELEGRAM_TRIGGER
trigger_auto_update" || { echo "FAIL the telegram trigger returned an error"; fail=1; }
  sleep 0.5
  if [[ -s "$TRIGGER_LOG" ]]; then
    echo "FAIL the telegram notifier started a missing updater"
    fail=1
  else
    echo "OK   the telegram notifier ignores a missing updater"
  fi
fi

# --- 2. the ignorehost script triggers the updater ------------------------
if python3 - "$DATA_DIR" "$TRIGGER_LOG" "$ROOT" <<'PY'
import ast
import os
import subprocess
import sys

data_dir, trigger_log, root = sys.argv[1], sys.argv[2], sys.argv[3]
script = os.path.join(root, "scripts", "ignorehost.sh")
source = open(script).read()
tree = ast.parse(source)
segments = [
    ast.get_source_segment(source, node)
    for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "trigger_auto_update"
]
if len(segments) != 1:
    print("FAIL trigger_auto_update is not defined at module level in ignorehost.sh")
    sys.exit(1)

namespace = {"_os": os, "_subprocess": subprocess, "sys": sys}
exec(segments[0], namespace)

# with FAIL2BAN_DATA_DIR the updater must be started
os.environ["FAIL2BAN_DATA_DIR"] = data_dir
os.environ["TRIGGER_LOG"] = trigger_log
namespace["trigger_auto_update"]()

deadline = 0
while deadline < 50 and not (os.path.exists(trigger_log) and os.path.getsize(trigger_log) > 0):
    import time
    time.sleep(0.1)
    deadline += 1
if not (os.path.exists(trigger_log) and os.path.getsize(trigger_log) > 0):
    print("FAIL the ignorehost script did not trigger the updater")
    sys.exit(1)
print("OK   the ignorehost script triggers the updater: " + open(trigger_log).read().strip())

# without FAIL2BAN_DATA_DIR nothing must be started
os.unlink(trigger_log)
del os.environ["FAIL2BAN_DATA_DIR"]
namespace["trigger_auto_update"]()
import time
time.sleep(0.5)
if os.path.exists(trigger_log) and os.path.getsize(trigger_log) > 0:
    print("FAIL the ignorehost script triggered the updater without FAIL2BAN_DATA_DIR")
    sys.exit(1)
print("OK   the ignorehost script does nothing without FAIL2BAN_DATA_DIR")
PY
then
  :
else
  fail=1
fi

# --- 3. the updater honours the enable flag and the daily throttle --------
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
CURL_LOG="$TMP/curl.log"
export CURL_LOG
cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
url=""
for arg in "$@"; do
  case "$arg" in
    http*) url="$arg" ;;
  esac
done
if [[ " $* " == *" -w "* ]]; then
  printf 'https://github.com/%s/releases/tag/v%s' "$url" "${FAKE_LATEST_VERSION:-0.0.1}"
  exit 0
fi
printf '{"tag_name": "v%s"}' "${FAKE_LATEST_VERSION:-0.0.1}"
EOF
chmod +x "$FAKE_BIN/curl"

UPD_ROOT="$TMP/updater"
mkdir -p "$UPD_ROOT/scripts"
cp scripts/version_check.sh "$UPD_ROOT/scripts/version_check.sh"
printf '0.0.1\n' > "$UPD_ROOT/VERSION"
cp "$FAKE_SECRETS" "$UPD_ROOT/config.local"

rm -f "$CURL_LOG"
if ! FAKE_LATEST_VERSION=0.0.1 PATH="$FAKE_BIN:$PATH" \
     bash "$UPD_ROOT/scripts/version_check.sh" --quiet >/dev/null 2>&1; then
  echo "FAIL version_check.sh exited non-zero"
  fail=1
fi
if [[ ! -s "$CURL_LOG" ]]; then
  echo "FAIL version_check.sh did not check for a new release"
  fail=1
else
  echo "OK   version_check.sh checks for a new release"
fi
if [[ ! -f "$UPD_ROOT/.last_update_check" ]]; then
  echo "FAIL version_check.sh did not record the check"
  fail=1
fi

# the second run of the same day must not check again
CHECKS_BEFORE="$(wc -l < "$CURL_LOG")"
FAKE_LATEST_VERSION=0.0.1 PATH="$FAKE_BIN:$PATH" \
  bash "$UPD_ROOT/scripts/version_check.sh" --quiet >/dev/null 2>&1
CHECKS_AFTER="$(wc -l < "$CURL_LOG")"
if [[ "$CHECKS_BEFORE" != "$CHECKS_AFTER" ]]; then
  echo "FAIL version_check.sh checked twice on the same day"
  fail=1
else
  echo "OK   version_check.sh runs at most once per day"
fi

# AUTO_UPDATE_ENABLED=false must disable the check entirely
sed -i 's/^AUTO_UPDATE_ENABLED=.*/AUTO_UPDATE_ENABLED=false/' "$UPD_ROOT/config.local"
rm -f "$UPD_ROOT/.last_update_check"
CHECKS_BEFORE="$(wc -l < "$CURL_LOG")"
PATH="$FAKE_BIN:$PATH" bash "$UPD_ROOT/scripts/version_check.sh" --quiet >/dev/null 2>&1
CHECKS_AFTER="$(wc -l < "$CURL_LOG")"
if [[ "$CHECKS_BEFORE" != "$CHECKS_AFTER" ]]; then
  echo "FAIL version_check.sh checked the release with AUTO_UPDATE_ENABLED=false"
  fail=1
else
  echo "OK   AUTO_UPDATE_ENABLED=false disables the check"
fi

# --- 4. the deploy step injects the secrets and reloads fail2ban ----------
cat > "$FAKE_BIN/fail2ban-client" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$RELOAD_LOG"
EOF
chmod +x "$FAKE_BIN/fail2ban-client"
RELOAD_LOG="$TMP/reload.log"
export RELOAD_LOG

LIVE_DIR="$TMP/live"
mkdir -p "$LIVE_DIR"
for fn in deploy_release reload_fail2ban deploy_file render_file secrets_file \
          default_mode install_file is_rendered expected_secret_keys check_rendered; do
  eval "$(extract_function scripts/version_check.sh "$fn")"
done
ROOT_DIR="$ROOT"
SECRETS="$FAKE_SECRETS"
UPDATE_LOG="$TMP/update.log"
WITH_CONFIG=0
RENDER_IN_PLACE=0
UPDATE_FILES=(
  VERSION
  scripts/deploy.sh scripts/redact.sh scripts/version_check.sh
  scripts/fail2ban-telegram.sh scripts/ignorehost.sh
)
RENDER_FILES=("scripts/fail2ban-telegram.sh" "scripts/ignorehost.sh")
# stubs for the helpers used by the extracted functions
log() { :; }
warn() { :; }
fail() { echo "ERROR $*" >&2; }
if ! PATH="$FAKE_BIN:$PATH" deploy_release "$LIVE_DIR" >/dev/null 2>&1; then
  echo "FAIL deploy_release failed"
  fail=1
fi
if [[ ! -f "$LIVE_DIR/scripts/fail2ban-telegram.sh" ]]; then
  echo "FAIL deploy_release did not deploy the scripts"
  fail=1
elif ! grep -q "$FAKE_NOTIFY_TOKEN" "$LIVE_DIR/scripts/fail2ban-telegram.sh"; then
  echo "FAIL deploy_release did not inject the secrets"
  fail=1
else
  echo "OK   deploy_release injects the secrets into the deployed scripts"
fi

# 4a. the helper scripts are templates: they must never hold a secret
if grep -q "$FAKE_NOTIFY_TOKEN" "$LIVE_DIR/scripts/deploy.sh" 2>/dev/null \
   || grep -q "$FAKE_NOTIFY_TOKEN" "$LIVE_DIR/scripts/version_check.sh" 2>/dev/null; then
  echo "FAIL deploy_release injected a secret into a helper script"
  fail=1
else
  echo "OK   deploy_release keeps the helper scripts free of secrets"
fi

# 4b. only the scripts are deployed: the configuration files of the running
#     fail2ban are never touched by an automatic update
if [[ -e "$LIVE_DIR/action.d" || -e "$LIVE_DIR/jail.local" || -e "$LIVE_DIR/jail.d" ]]; then
  echo "FAIL deploy_release deployed configuration files"
  fail=1
else
  echo "OK   deploy_release leaves the configuration files alone"
fi

# 4c. no reload is needed when only the scripts changed
if [[ -s "$RELOAD_LOG" ]]; then
  echo "FAIL deploy_release reloaded fail2ban without touching the configuration"
  fail=1
else
  echo "OK   deploy_release does not reload fail2ban for a scripts only update"
fi

# 4d. with --with-config the configuration is deployed and fail2ban reloaded
WITH_CONFIG=1
UPDATE_FILES+=(action.d/telegram.local action.d/ui-custom-action.conf filter.d/npm-docker.conf jail.local)
RENDER_FILES+=(action.d/telegram.local action.d/ui-custom-action.conf filter.d/npm-docker.conf jail.local)
if ! PATH="$FAKE_BIN:$PATH" deploy_release "$LIVE_DIR" >/dev/null 2>&1; then
  echo "FAIL deploy_release --with-config failed"
  fail=1
fi
if [[ ! -f "$LIVE_DIR/jail.local" ]] || [[ ! -f "$LIVE_DIR/action.d/telegram.local" ]]; then
  echo "FAIL deploy_release --with-config did not deploy the configuration"
  fail=1
else
  echo "OK   deploy_release --with-config deploys the configuration files"
fi
if ! grep -q "$FAKE_CALLBACK" "$LIVE_DIR/action.d/ui-custom-action.conf" 2>/dev/null; then
  echo "FAIL deploy_release --with-config did not inject the secrets in the configuration"
  fail=1
else
  echo "OK   deploy_release --with-config injects the secrets in the configuration"
fi
if [[ ! -s "$RELOAD_LOG" ]] || ! grep -q reload "$RELOAD_LOG"; then
  echo "FAIL deploy_release --with-config did not reload fail2ban"
  fail=1
else
  echo "OK   deploy_release --with-config reloads fail2ban"
fi
WITH_CONFIG=0

# 4e. deploy_file injects the secrets and keeps the permissions
RENDERED="$TMP/rendered/scripts"
mkdir -p "$RENDERED"
printf 'TOKEN=__TELEGRAM_BOT_TOKEN_NOTIFY__\n' > "$TMP/placeholder.sh"
if ! deploy_file "$TMP/placeholder.sh" "$RENDERED/placeholder.sh" >/dev/null 2>&1; then
  echo "FAIL deploy_file failed"
  fail=1
fi
if ! grep -q "$FAKE_NOTIFY_TOKEN" "$RENDERED/placeholder.sh"; then
  echo "FAIL deploy_file did not inject the secret"
  fail=1
else
  echo "OK   deploy_file injects the secrets"
fi
# a missing secret must abort the deployment: the key is documented by the
# repository (config.local.example) but not configured
PARTIAL_SECRETS="$TMP/partial-config.local"
grep -v '^FAIL2BAN_UI_CALLBACK_SECRET=' "$FAKE_SECRETS" > "$PARTIAL_SECRETS"
printf 'SECRET=__FAIL2BAN_UI_CALLBACK_SECRET__\n' > "$TMP/unresolved.sh"
if SECRETS="$PARTIAL_SECRETS" deploy_file "$TMP/unresolved.sh" "$RENDERED/unresolved.sh" >/dev/null 2>&1; then
  echo "FAIL deploy_file accepted an unresolved placeholder"
  fail=1
elif [[ -e "$RENDERED/unresolved.sh" ]]; then
  echo "FAIL deploy_file wrote a file with an unresolved placeholder"
  fail=1
else
  echo "OK   deploy_file refuses to write a file with an unresolved placeholder"
fi

# --- 5. files are replaced atomically, keeping their permissions ----------
eval "$(extract_function scripts/version_check.sh install_file)"
SRC_FILE="$TMP/source.sh"
DST_FILE="$TMP/destination.sh"
printf 'new content\n' > "$SRC_FILE"
printf 'old content\n' > "$DST_FILE"
chmod 750 "$DST_FILE"
if ! install_file "$SRC_FILE" "$DST_FILE"; then
  echo "FAIL install_file failed"
  fail=1
fi
if [[ "$(cat "$DST_FILE")" != "new content" ]]; then
  echo "FAIL install_file did not replace the content"
  fail=1
fi
if [[ "$(stat -c '%a' "$DST_FILE")" != "750" ]]; then
  echo "FAIL install_file did not preserve the permissions"
  fail=1
else
  echo "OK   install_file replaces the file keeping its permissions"
fi

# --- 6. deploy.sh refuses to inject the secrets into a git checkout -------
GIT_DEST="$TMP/git-dest"
mkdir -p "$GIT_DEST/.git"
if bash scripts/deploy.sh --apply --dest "$GIT_DEST" --secrets "$FAKE_SECRETS" >/dev/null 2>&1; then
  echo "FAIL deploy.sh accepted a git working tree as destination"
  fail=1
else
  echo "OK   deploy.sh refuses to deploy into a git working tree"
fi

# --- 7. the Telegram messages show the running version ----------------------
# Every notification tells which release of the scripts is running, so it is
# always visible whether the automatic update has been applied.
VERSION_LINE="$(FAIL2BAN_DATA_DIR="$ROOT" bash -c '
  source <(sed -n "/^function get_scripts_version/,/^}/p" scripts/fail2ban-telegram.sh)
  get_scripts_version
')"
if [[ "$VERSION_LINE" != "$(tr -d '[:space:]' < VERSION)" ]]; then
  echo "FAIL the telegram script does not report the running version (got '$VERSION_LINE')"
  fail=1
else
  echo "OK   the telegram script reports the running version ($VERSION_LINE)"
fi

if ! grep -q 'Scripts version' scripts/fail2ban-telegram.sh; then
  echo "FAIL the telegram message does not contain the scripts version"
  fail=1
else
  echo "OK   the telegram message contains the scripts version"
fi

# the message built by the script must contain the version (the send is
# captured with a fake curl, nothing is sent for real)
MSG_DIR="$TMP/msg"
mkdir -p "$MSG_DIR"
cat > "$MSG_DIR/curl" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  if [[ "${next:-0}" == "1" ]]; then printf '%s' "$arg" > "$CURL_CAPTURE"; next=0; continue; fi
  [[ "$arg" == "--data-urlencode" ]] && next=1
done
printf '200'
EOF
chmod +x "$MSG_DIR/curl"
CURL_CAPTURE="$TMP/message.txt" PATH="$MSG_DIR:$PATH" \
  bash scripts/fail2ban-telegram.sh ban 203.0.113.5 >/dev/null 2>&1
if ! grep -q "Scripts version:</b> $(tr -d '[:space:]' < VERSION)" "$TMP/message.txt" 2>/dev/null; then
  echo "FAIL the telegram message does not show the running version"
  fail=1
else
  echo "OK   the telegram message shows the running version"
fi

if python3 - "$ROOT" <<'PY'
import ast
import os
import sys

root = sys.argv[1]
source = open(os.path.join(root, "scripts", "ignorehost.sh")).read()
tree = ast.parse(source)
segments = [
    ast.get_source_segment(source, node)
    for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "get_scripts_version"
]
if len(segments) != 1:
    print("FAIL get_scripts_version is not defined at module level in ignorehost.sh")
    sys.exit(1)

namespace = {
    "_os": os,
    "_SCRIPT_DIR": os.path.dirname(os.path.dirname(os.path.abspath(
        os.path.join(root, "scripts", "ignorehost.sh")))),
}
exec(segments[0], namespace)

expected = open(os.path.join(root, "VERSION")).read().strip()
if namespace["get_scripts_version"]() != expected:
    print("FAIL the ignorehost script does not report the running version")
    sys.exit(1)
print("OK   the ignorehost script reports the running version (" + expected + ")")
PY
then
  :
else
  fail=1
fi

if ! grep -q 'Scripts version' scripts/ignorehost.sh; then
  echo "FAIL the ignorehost message does not contain the scripts version"
  fail=1
else
  echo "OK   the ignorehost message contains the scripts version"
fi

[[ $fail -eq 0 ]] && echo "Auto-update chain checks passed."
exit $fail
