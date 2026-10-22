#!/bin/bash
# Regression test for the BusyBox compatibility of the file installation.
#
# The scripts are installed by scripts/version_check.sh (and by
# scripts/deploy.sh) with a temporary file that is moved into place. The
# permissions and the owner of the file that is replaced must be preserved.
#
# The original implementation used `chmod --reference` / `chown --reference`:
# those options are a GNU coreutils extension and BusyBox does not support
# them. The updater runs inside the fail2ban container, whose image is BusyBox
# based, so the GNU syntax failed there, the error was swallowed by `|| true`
# and the deployed files silently kept the mode of the temporary file (0600
# for the rendered ones) instead of the tight mode of the file they replace
# (0750).
#
# This test emulates BusyBox by putting a chmod/chown stub that rejects the
# --reference option in front of the PATH, and verifies that the permissions
# are still preserved.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-busybox-test.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REAL_CHMOD="$(command -v chmod)"
REAL_CHOWN="$(command -v chown)"
if [[ -z "$REAL_CHMOD" || -z "$REAL_CHOWN" ]]; then
  echo "SKIP chmod/chown not found"
  exit 0
fi

# --- BusyBox-like stubs ----------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/chmod" <<EOF
#!/bin/sh
# BusyBox chmod: no --reference support.
for arg in "\$@"; do
  case "\$arg" in
    --reference*) echo "chmod: unrecognized option: \$arg" >&2; exit 1 ;;
  esac
done
exec "$REAL_CHMOD" "\$@"
EOF

cat > "$STUB_BIN/chown" <<EOF
#!/bin/sh
# BusyBox chown: no --reference support.
for arg in "\$@"; do
  case "\$arg" in
    --reference*) echo "chown: unrecognized option: \$arg" >&2; exit 1 ;;
  esac
done
exec "$REAL_CHOWN" "\$@"
EOF

chmod +x "$STUB_BIN/chmod" "$STUB_BIN/chown"

# The stubs must really reject the GNU syntax, otherwise the test is void.
if "$STUB_BIN/chmod" --reference=/etc/hostname "$STUB_BIN/chmod" 2>/dev/null; then
  echo "FAIL the chmod stub does not emulate BusyBox"
  exit 1
fi

# Extract a bash function (with or without the "function" keyword) so that it
# can be exercised in isolation.
extract_function() { # $1 = file, # $2 = function name
  awk -v fn="$2" '
    !inside && ($0 ~ "^function[ \t]+" fn "[ \t]*\\{" || $0 ~ "^" fn "\\(\\) *\\{") { inside = 1 }
    inside { print }
    inside && /^\}/ { exit }
  ' "$1"
}

# Fake credentials: they look like the real thing but are not usable anywhere.
# The values are kept in variables so that the secret scanner of the
# repository does not flag this file.
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
EOF

# --- 1. install_file keeps the permissions ---------------------------------
eval "$(extract_function scripts/version_check.sh copy_file_meta)"
eval "$(extract_function scripts/version_check.sh install_file)"

SRC_FILE="$TMP/source.sh"
DST_FILE="$TMP/destination.sh"
printf 'new content\n' > "$SRC_FILE"
printf 'old content\n' > "$DST_FILE"
chmod 750 "$DST_FILE"

if ! PATH="$STUB_BIN:$PATH" install_file "$SRC_FILE" "$DST_FILE"; then
  echo "FAIL install_file failed"
  fail=1
fi
if [[ "$(cat "$DST_FILE")" != "new content" ]]; then
  echo "FAIL install_file did not replace the content"
  fail=1
fi
if [[ "$(stat -c '%a' "$DST_FILE")" != "750" ]]; then
  echo "FAIL install_file did not preserve the permissions (got $(stat -c '%a' "$DST_FILE"), want 750) without GNU chmod"
  fail=1
else
  echo "OK   install_file preserves the permissions without GNU chmod"
fi

# --- 2. deploy_file keeps the permissions ----------------------------------
eval "$(extract_function scripts/version_check.sh default_mode)"
eval "$(extract_function scripts/version_check.sh secrets_file)"
eval "$(extract_function scripts/version_check.sh expected_secret_keys)"
eval "$(extract_function scripts/version_check.sh check_rendered)"
eval "$(extract_function scripts/version_check.sh render_file)"
eval "$(extract_function scripts/version_check.sh deploy_file)"

SECRETS="$FAKE_SECRETS"
ROOT_DIR="$ROOT"
RENDER_SRC="$TMP/render.sh"
RENDER_DST="$TMP/rendered.sh"
printf 'TOKEN="__TELEGRAM_BOT_TOKEN_NOTIFY__"\n' > "$RENDER_SRC"
printf 'old\n' > "$RENDER_DST"
chmod 750 "$RENDER_DST"

if ! PATH="$STUB_BIN:$PATH" deploy_file "$RENDER_SRC" "$RENDER_DST"; then
  echo "FAIL deploy_file failed"
  fail=1
fi
if grep -q '__TELEGRAM_BOT_TOKEN_NOTIFY__' "$RENDER_DST"; then
  echo "FAIL deploy_file did not inject the secrets"
  fail=1
fi
if [[ "$(stat -c '%a' "$RENDER_DST")" != "750" ]]; then
  echo "FAIL deploy_file did not preserve the permissions (got $(stat -c '%a' "$RENDER_DST"), want 750) without GNU chmod"
  fail=1
else
  echo "OK   deploy_file preserves the permissions without GNU chmod"
fi

# --- 3. deploy.sh keeps the permissions ------------------------------------
DEPLOY_DEST="$TMP/deploy-dest"
mkdir -p "$DEPLOY_DEST/scripts"
printf 'old\n' > "$DEPLOY_DEST/scripts/fail2ban-telegram.sh"
chmod 750 "$DEPLOY_DEST/scripts/fail2ban-telegram.sh"

if ! PATH="$STUB_BIN:$PATH" bash scripts/deploy.sh --apply --dest "$DEPLOY_DEST" \
      --secrets "$FAKE_SECRETS" --scripts-only >/dev/null 2>&1; then
  echo "FAIL deploy.sh failed"
  fail=1
fi
if [[ "$(stat -c '%a' "$DEPLOY_DEST/scripts/fail2ban-telegram.sh")" != "750" ]]; then
  echo "FAIL deploy.sh did not preserve the permissions (got $(stat -c '%a' "$DEPLOY_DEST/scripts/fail2ban-telegram.sh"), want 750) without GNU chmod"
  fail=1
else
  echo "OK   deploy.sh preserves the permissions without GNU chmod"
fi

# --- 4. the scripts must not rely on the GNU syntax ------------------------
if grep -q -- '--reference=' scripts/version_check.sh scripts/deploy.sh; then
  echo "FAIL the GNU chmod/chown --reference syntax is still used"
  grep -n -- '--reference=' scripts/version_check.sh scripts/deploy.sh
  fail=1
else
  echo "OK   no GNU-only chmod/chown --reference syntax left"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "BusyBox compatibility checks passed."
else
  echo "BusyBox compatibility checks FAILED."
fi
exit "$fail"
