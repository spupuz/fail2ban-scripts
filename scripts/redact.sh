#!/bin/bash
# Inverse of scripts/deploy.sh: read the LIVE fail2ban files (which contain
# real secrets) and rewrite them with placeholder tokens so they can be
# committed back into this repository safely.
# No host path is baked in: source and destination must be given explicitly.
#
# Usage:
#   scripts/redact.sh --src LIVE_DIR --out STAGING_DIR
#   scripts/redact.sh --src LIVE_DIR --out STAGING_DIR --secrets FILE
#   scripts/redact.sh --src LIVE_DIR --out STAGING_DIR --scripts-only
#   scripts/redact.sh --file some.conf             # prints redacted text to stdout
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=""
OUT=""
FILE=""
SECRETS="$REPO_ROOT/config.local"
SCRIPTS_ONLY=0

# The scripts and the configuration are kept apart on purpose: the automatic
# update only refreshes the scripts, because jail.local is managed by the
# Fail2Ban-UI and the other configuration files change the behaviour of the
# running service.
SCRIPT_FILES=(
  "VERSION"
  "scripts/deploy.sh"
  "scripts/redact.sh"
  "scripts/version_check.sh"
  "scripts/log_rotate.sh"
  "scripts/fail2ban-telegram.sh"
  "scripts/ignorehost.sh"
)

CONFIG_FILES=(
  "action.d/telegram.local"
  "action.d/iptables-nft.local"
  "action.d/ui-custom-action.conf"
  "filter.d/npm-docker.conf"
  "jail.d/npm-docker.local"
  "jail.local"
  "paths-overrides.local"
)

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="${2:?--src requires a path}"; shift 2 ;;
    --out) OUT="${2:?--out requires a path}"; shift 2 ;;
    --file) FILE="${2:?--file requires a path}"; shift 2 ;;
    --secrets) SECRETS="${2:?--secrets requires a path}"; shift 2 ;;
    --scripts-only) SCRIPTS_ONLY=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# The file list depends on --scripts-only: build it once the options are known.
if [[ "$SCRIPTS_ONLY" -eq 1 ]]; then
  FILES=("${SCRIPT_FILES[@]}")
else
  FILES=("${SCRIPT_FILES[@]}" "${CONFIG_FILES[@]}")
fi

if [[ -z "$FILE" && -z "$SRC" ]]; then
  echo "ERROR: --src DIR is required (source fail2ban data directory)." >&2
  usage 1
fi

[[ -f "$SECRETS" ]] || { echo "ERROR: config file not found: $SECRETS" >&2; exit 1; }

redact() { # $1 = source file, $2 = destination file (or "-" for stdout)
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
    if value:
        data = data.replace(value, b'__' + key + b'__')
if dst == '-':
    sys.stdout.buffer.write(data)
else:
    open(dst, 'wb').write(data)
PY
}

if [[ -n "$FILE" ]]; then
  redact "$FILE" -
  exit 0
fi

[[ -n "$OUT" ]] || { echo "ERROR: --out is required (refusing to overwrite in place)" >&2; usage 1; }

status=0
for rel in "${FILES[@]}"; do
  src="$SRC/$rel"
  dst="$OUT/$rel"
  if [[ ! -f "$src" ]]; then
    echo "MISSING source: $src" >&2
    status=1
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  redact "$src" "$dst"
  echo "REDACTED $rel -> $dst"
done

if [[ "$status" -eq 0 ]]; then
  echo
  echo "Done. Review 'git diff' before committing — placeholders only, never real values."
fi
exit "$status"
