#!/bin/bash
# Structural validation of the fail2ban configuration files and of the
# repo -> /etc/fail2ban cross references.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
ok()   { echo "OK   $1"; }
bad()  { echo "FAIL $1"; fail=1; }

CONFIGS=(
  jail.local
  paths-overrides.local
  action.d/telegram.local
  action.d/iptables-nft.local
  action.d/ui-custom-action.conf
  filter.d/npm-docker.conf
  jail.d/npm-docker.local
)

REQUIRED_FILES=(
  scripts/fail2ban-telegram.sh
  scripts/ignorehost.sh
  action.d/telegram.local
  action.d/iptables-nft.local
  action.d/ui-custom-action.conf
  filter.d/npm-docker.conf
  jail.d/npm-docker.local
  jail.local
  paths-overrides.local
  VERSION
  config.local.example
)

# --- 1. required files present -------------------------------------------
for f in "${REQUIRED_FILES[@]}"; do
  [[ -f "$f" ]] && ok "exists  $f" || bad "missing $f"
done

# --- 2. every config must have at least one INI section header ------------
for f in "${CONFIGS[@]}"; do
  [[ -f "$f" ]] || continue
  if grep -qE '^\[[A-Za-z0-9_.:-]+\][[:space:]]*$' "$f"; then
    ok "section $f"
  else
    bad "section $f has no [Section] header"
  fi
done

# --- 3. line endings: fail2ban tolerates CRLF (some shipped files use it),
#       so this is informational only, never a failure ---------------------
for f in "${CONFIGS[@]}"; do
  [[ -f "$f" ]] || continue
  if grep -q $'\r' "$f"; then
    echo "WARN CRLF line endings in $f (upstream original also has CRLF)"
  fi
done

# --- 4. filter must define failregex with <HOST> --------------------------
FILTER=filter.d/npm-docker.conf
if [[ -f "$FILTER" ]]; then
  if grep -qE '^[[:space:]]*failregex[[:space:]]*=' "$FILTER"; then
    ok "failregex defined in $FILTER"
    if grep -E '^[[:space:]]*failregex[[:space:]]*=' "$FILTER" | grep -q '<HOST>'; then
      ok "failregex uses <HOST> in $FILTER"
    else
      bad "failregex must match <HOST> in $FILTER"
    fi
  else
    bad "failregex missing in $FILTER"
  fi
fi

# --- 5. every failregex must be a compilable Python regex -----------------
while IFS= read -r rx; do
  [[ -z "$rx" ]] && continue
  if python3 - "$rx" <<'PY'
import re, sys
rx = sys.argv[1]
for tag in ("<HOST>", "<ADDR>", "<IP4>", "<IP6>"):
    rx = rx.replace(tag, r"\d+\.\d+\.\d+\.\d+")
re.compile(rx)
PY
  then
    ok "failregex compiles: ${rx:0:50}"
  else
    bad "failregex does not compile: $rx"
    fail=1
  fi
done < <(sed -nE 's/^[[:space:]]*failregex[[:space:]]*=[[:space:]]*(.*)$/\1/p' "${CONFIGS[@]}")

# --- 6. cross references: /etc/fail2ban/scripts/<file> must exist in repo --
while IFS= read -r ref; do
  name="$(basename "$ref")"
  if [[ -f "scripts/$name" ]]; then
    ok "ref $ref -> scripts/$name"
  else
    bad "ref $ref has no scripts/$name in the repository"
  fi
done < <(grep -rhoE '/etc/fail2ban/scripts/[A-Za-z0-9_.-]+' "${CONFIGS[@]}" | sort -u)

# --- 7. runtime scripts must be executable --------------------------------
for f in scripts/fail2ban-telegram.sh scripts/ignorehost.sh; do
  [[ -f "$f" ]] || continue
  if [[ -x "$f" ]]; then
    ok "executable $f"
  else
    bad "not executable $f (fail2ban runs it directly)"
  fi
done

# --- 8. secrets placeholders present where required -----------------------
declare -A EXPECTED_PLACEHOLDER=(
  [scripts/fail2ban-telegram.sh]=__TELEGRAM_BOT_TOKEN_NOTIFY__
  [scripts/ignorehost.sh]=__TELEGRAM_BOT_TOKEN_IGNOREHOST__
  [scripts/ignorehost_old.sh]=__TELEGRAM_BOT_TOKEN_IGNOREHOST__
  [action.d/ui-custom-action.conf]=__FAIL2BAN_UI_CALLBACK_SECRET__
)
for f in "${!EXPECTED_PLACEHOLDER[@]}"; do
  ph="${EXPECTED_PLACEHOLDER[$f]}"
  [[ -f "$f" ]] || continue
  if grep -qF "$ph" "$f"; then
    ok "placeholder $ph in $f"
  else
    bad "placeholder $ph missing in $f (secret re-hardcoded?)"
  fi
done

# --- 9. VERSION must be semver --------------------------------------------
if [[ -f VERSION ]] && grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' VERSION; then
  ok "VERSION is semver: $(tr -d '[:space:]' < VERSION)"
else
  bad "VERSION must contain a bare X.Y.Z version"
fi

[[ $fail -eq 0 ]] && echo "Config checks passed."
exit $fail
