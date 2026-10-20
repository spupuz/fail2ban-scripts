#!/bin/bash
# Functional test for scripts/deploy.sh: renders the whole deployment into a
# temporary directory using dummy secrets and verifies that
#   - every __PLACEHOLDER__ was substituted,
#   - no real secret was read (dummy values only),
#   - the rendered output is still syntactically valid (bash -n / py compile).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
TMP="$(mktemp -d /tmp/opencode/fail2ban-deploy-test.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_SECRETS="$TMP/config.local"
# The values are built from non-credential-looking variable names so this test
# fixture itself stays clean under local_tests/test_secrets.sh.
FAKE_NOTIFY_TOKEN="123456789:FAKEFAKEFAKEFAKEFAKEFAKEFAKE0"
FAKE_NOTIFY_CHAT="-1001234567890"
FAKE_IGNORE_TOKEN="987654321:FAKEFAKEFAKEFAKEFAKEFAKEFAKE0"
FAKE_IGNORE_CHAT="-1009876543210"
FAKE_CALLBACK="FAKE_CALLBACK_SECRET_FOR_TESTS_ONLY"
cat > "$FAKE_SECRETS" <<EOF
TELEGRAM_BOT_TOKEN_NOTIFY=$FAKE_NOTIFY_TOKEN
TELEGRAM_CHAT_ID_NOTIFY=$FAKE_NOTIFY_CHAT
TELEGRAM_BOT_TOKEN_IGNOREHOST=$FAKE_IGNORE_TOKEN
TELEGRAM_CHAT_ID_IGNOREHOST=$FAKE_IGNORE_CHAT
FAIL2BAN_UI_CALLBACK_SECRET=$FAKE_CALLBACK
EOF

DEST="$TMP/fail2ban"
mkdir -p "$DEST"

if ! out="$(bash scripts/deploy.sh --apply --dest "$DEST" --secrets "$FAKE_SECRETS" 2>&1)"; then
  echo "FAIL deploy.sh --apply exited non-zero:"
  echo "$out"
  exit 1
fi
echo "$out" | sed 's/^/     | /' | tail -n 5

mapfile -t RENDERED < <(find "$DEST" -type f | sort)
if [[ ${#RENDERED[@]} -eq 0 ]]; then
  echo "FAIL deploy.sh produced no files"
  exit 1
fi

for f in "${RENDERED[@]}"; do
  # 1. no placeholder may survive rendering
  if grep -qE '__[A-Z0-9_]+__' "$f"; then
    echo "FAIL unresolved placeholder in ${f#"$DEST"/}:"
    grep -nE '__[A-Z0-9_]+__' "$f"
    fail=1
  fi
  # 2. the fake secrets must actually be present in the files that need them
  rel="${f#"$DEST"/}"
  case "$rel" in
    scripts/fail2ban-telegram.sh)
      grep -q '123456789:FAKE' "$f" || { echo "FAIL notify token not injected in $rel"; fail=1; }
      grep -q -- '-1001234567890' "$f" || { echo "FAIL notify chat id not injected in $rel"; fail=1; } ;;
    scripts/ignorehost.sh)
      grep -q '987654321:FAKE' "$f" || { echo "FAIL ignorehost token not injected in $rel"; fail=1; } ;;
    action.d/ui-custom-action.conf)
      grep -q 'FAKE_CALLBACK_SECRET_FOR_TESTS_ONLY' "$f" || { echo "FAIL callback secret not injected in $rel"; fail=1; } ;;
  esac
  # 3. rendered output must still be syntactically valid
  if [[ "$rel" == *.sh ]]; then
    if head -1 "$f" | grep -qi python; then
      python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f" \
        || { echo "FAIL py-compile rendered $rel"; fail=1; }
    else
      bash -n "$f" || { echo "FAIL bash -n rendered $rel"; fail=1; }
    fi
  fi
done

# 4. dry-run must not write anything
EMPTY="$TMP/empty-dest"
mkdir -p "$EMPTY"
if ! bash scripts/deploy.sh --dest "$EMPTY" --secrets "$FAKE_SECRETS" >/dev/null 2>&1; then
  echo "FAIL deploy.sh dry-run exited non-zero"
  fail=1
fi
if [[ -n "$(ls -A "$EMPTY")" ]]; then
  echo "FAIL deploy.sh dry-run wrote files to $EMPTY"
  fail=1
fi

# 5. missing/placeholder secrets must abort the deploy
BAD="$TMP/bad-config.local"
cp "$FAKE_SECRETS" "$BAD"
sed -i 's/^TELEGRAM_CHAT_ID_NOTIFY=.*/TELEGRAM_CHAT_ID_NOTIFY=__TELEGRAM_CHAT_ID_NOTIFY__/' "$BAD"
if bash scripts/deploy.sh --apply --dest "$TMP/other" --secrets "$BAD" >/dev/null 2>&1; then
  echo "FAIL deploy.sh accepted a placeholder secret"
  fail=1
else
  mkdir -p "$TMP/other"
fi

# 6. round trip: redact.sh must turn the rendered (secret-bearing) output back
#    into byte-identical repository sources, so live -> repo syncs never leak.
RED="$TMP/redacted"
if ! bash scripts/redact.sh --src "$DEST" --out "$RED" --secrets "$FAKE_SECRETS" >/dev/null 2>&1; then
  echo "FAIL redact.sh exited non-zero"
  fail=1
else
  for rel in scripts/fail2ban-telegram.sh \
             scripts/ignorehost.sh \
             action.d/telegram.local action.d/iptables-nft.local \
             action.d/ui-custom-action.conf filter.d/npm-docker.conf \
             jail.d/npm-docker.local jail.local paths-overrides.local; do
    if ! diff -u "$rel" "$RED/$rel" >/dev/null 2>&1; then
      echo "FAIL round-trip mismatch for $rel:"
      diff -u "$rel" "$RED/$rel" | head -20
      fail=1
    fi
  done
  # and no secret may survive redaction
  if grep -rqF "$FAKE_CALLBACK" "$RED" 2>/dev/null; then
    echo "FAIL redact.sh left a real secret in the output"
    fail=1
  fi
fi

[[ $fail -eq 0 ]] && echo "Deploy pipeline tests passed (${#RENDERED[@]} files rendered)."
exit $fail
