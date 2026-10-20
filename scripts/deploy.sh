#!/bin/bash
# Deploy the fail2ban custom scripts/config into a fail2ban data directory,
# injecting the real secrets from secrets.env into the __PLACEHOLDER__ tokens.
# No host path is baked in: the destination must always be given explicitly.
#
# Usage:
#   scripts/deploy.sh --dest DIR                 # dry-run: show what would be written
#   scripts/deploy.sh --dest DIR --apply         # write the files to DIR
#   scripts/deploy.sh --dest DIR --apply --secrets FILE
#   scripts/deploy.sh --dest DIR --secrets FILE  (defaults to ./secrets.env)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST=""
SECRETS="$REPO_ROOT/secrets.env"
APPLY=0

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dest) DEST="${2:?--dest requires a path}"; shift 2 ;;
    --secrets) SECRETS="${2:?--secrets requires a path}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$DEST" ]]; then
  echo "ERROR: --dest DIR is required (target fail2ban data directory)." >&2
  usage 1
fi

# Files deployed, mirroring the repository layout (relative to REPO_ROOT).
FILES=(
  "scripts/fail2ban-telegram.sh"
  "scripts/fail2ban-telegram_old.sh"
  "scripts/ignorehost.sh"
  "scripts/ignorehost_old.sh"
  "action.d/telegram.local"
  "action.d/iptables-nft.local"
  "action.d/ui-custom-action.conf"
  "filter.d/npm-docker.conf"
  "jail.d/npm-docker.local"
  "jail.local"
  "paths-overrides.local"
)

if [[ ! -f "$SECRETS" ]]; then
  echo "ERROR: secrets file not found: $SECRETS" >&2
  echo "Create it with: cp secrets.env.example secrets.env && chmod 600 secrets.env" >&2
  exit 1
fi

# Load secrets (KEY=VALUE lines, '#' comments ignored) without leaking them.
declare -A SECRET_MAP
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  SECRET_MAP["$key"]="$value"
done < "$SECRETS"

PLACEHOLDERS=(
  __TELEGRAM_BOT_TOKEN_NOTIFY__
  __TELEGRAM_CHAT_ID_NOTIFY__
  __TELEGRAM_BOT_TOKEN_IGNOREHOST__
  __TELEGRAM_CHAT_ID_IGNOREHOST__
  __FAIL2BAN_UI_CALLBACK_SECRET__
)

for ph in "${PLACEHOLDERS[@]}"; do
  key="${ph//__/}"
  if [[ -z "${SECRET_MAP[$key]:-}" || "${SECRET_MAP[$key]}" == "$ph" ]]; then
    echo "ERROR: secret '$key' is missing or still a placeholder in $SECRETS" >&2
    exit 1
  fi
done

echo "Repository: $REPO_ROOT"
echo "Destination: $DEST"
echo "Secrets:     $SECRETS (values masked)"
for ph in "${PLACEHOLDERS[@]}"; do
  key="${ph//__/}"
  printf '  %-32s = %s\n' "$key" "<set, ${#SECRET_MAP[$key]} chars>"
done
echo

# Substitute placeholders with python3, at byte level, so that tokens with
# special characters ('/', '&', …) are safe AND CRLF/no-final-newline files
# stay byte-identical apart from the substitution itself.
render_to() { # $1 = source file, $2 = destination file
  python3 - "$1" "$2" "$SECRETS" <<'PY'
import sys
src, dst, secrets_path = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(src, 'rb').read()
for line in open(secrets_path, 'rb').read().splitlines():
    line = line.strip()
    if not line or line.startswith(b'#') or b'=' not in line:
        continue
    key, value = line.split(b'=', 1)
    key, value = key.strip(), value.strip()
    if key and value:
        data = data.replace(b'__' + key + b'__', value)
open(dst, 'wb').write(data)
PY
}

status=0
for rel in "${FILES[@]}"; do
  src="$REPO_ROOT/$rel"
  dst="$DEST/$rel"
  if [[ ! -f "$src" ]]; then
    echo "MISSING source: $rel" >&2
    status=1
    continue
  fi
  tmp="$(mktemp)"
  render_to "$src" "$tmp"
  if grep -q '__[A-Z0-9_]*__' "$tmp"; then
    echo "ERROR: unresolved placeholder in $rel:" >&2
    grep -an '__[A-Z0-9_]*__' "$tmp" >&2
    rm -f "$tmp"
    status=1
    continue
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$(dirname "$dst")"
    # Preserve the destination's permissions/owner: fail2ban runs these as
    # root with tight modes (scripts are 750, ui action 600).
    if [[ -f "$dst" ]]; then
      chmod --reference="$dst" "$tmp" 2>/dev/null || true
      chown --reference="$dst" "$tmp" 2>/dev/null || true
    fi
    mv -f "$tmp" "$dst"
    echo "WROTE  $dst ($(wc -c < "$dst") bytes)"
  else
    echo "DRY    $dst ($(wc -c < "$tmp") bytes rendered)"
    rm -f "$tmp"
  fi
done

if [[ "$status" -ne 0 ]]; then
  echo "Deploy aborted." >&2
  exit "$status"
fi

if [[ "$APPLY" -eq 1 ]]; then
  echo
  echo "Done. Reload fail2ban to apply: fail2ban-client reload"
else
  echo
  echo "Dry run only — re-run with --apply to write the files."
fi
