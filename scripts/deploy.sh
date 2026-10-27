#!/bin/bash
# Deploy the fail2ban custom scripts/config into a fail2ban data directory,
# injecting the real secrets from config.local into the placeholder tokens.
# The helper scripts (deploy.sh, redact.sh, version_check.sh) are templates:
# they are copied as they are and read the secrets from config.local when they
# run, so they never hold a secret themselves.
# No host path is baked in: the destination must always be given explicitly.
#
# Usage:
#   scripts/deploy.sh --dest DIR                 # dry-run: show what would be written
#   scripts/deploy.sh --dest DIR --apply         # write the files to DIR
#   scripts/deploy.sh --dest DIR --apply --secrets FILE
#   scripts/deploy.sh --dest DIR --secrets FILE  (defaults to ./config.local)
#   scripts/deploy.sh --dest DIR --apply --scripts-only  (scripts only, no config)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST=""
SECRETS="$REPO_ROOT/config.local"
APPLY=0
SCRIPTS_ONLY=0

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dest) DEST="${2:?--dest requires a path}"; shift 2 ;;
    --secrets) SECRETS="${2:?--secrets requires a path}"; shift 2 ;;
    --scripts-only) SCRIPTS_ONLY=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$DEST" ]]; then
  echo "ERROR: --dest DIR is required (target fail2ban data directory)." >&2
  usage 1
fi

# Refuse to inject the secrets into a git checkout: the rendered files would
# carry the real credentials and could be committed by accident.
if [[ -d "$DEST/.git" ]]; then
  echo "ERROR: refusing to deploy into the git working tree $DEST." >&2
  echo "The deployed files contain the real secrets: deploy into the fail2ban data directory." >&2
  exit 1
fi

# Files deployed, mirroring the repository layout (relative to REPO_ROOT).
# The scripts and the configuration are kept apart on purpose: the automatic
# update only refreshes the scripts (--scripts-only), because jail.local is
# managed by the Fail2Ban-UI and the other configuration files change the
# behaviour of the running service.
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

# Files that are templates: they are deployed exactly as they are and never
# receive the secret values. The helper scripts read the secrets from
# config.local when they run, so they never hold a secret themselves. Every
# other file is rendered: it may contain placeholder tokens for the secrets.
TEMPLATE_FILES=(
  "VERSION"
  "scripts/deploy.sh"
  "scripts/redact.sh"
  "scripts/version_check.sh"
  "scripts/log_rotate.sh"
)

is_template() { # $1 = path relative to the repository root
  local rel
  for rel in "${TEMPLATE_FILES[@]}"; do
    [[ "$rel" == "$1" ]] && return 0
  done
  return 1
}

if [[ "$SCRIPTS_ONLY" -eq 1 ]]; then
  FILES=("${SCRIPT_FILES[@]}")
else
  FILES=("${SCRIPT_FILES[@]}" "${CONFIG_FILES[@]}")
fi

if [[ ! -f "$SECRETS" ]]; then
  echo "ERROR: config file not found: $SECRETS" >&2
  echo "Create it with: cp config.local.example config.local && chmod 600 config.local" >&2
  exit 1
fi

# Load secrets (KEY=VALUE lines, '#' comments ignored) without leaking them.
declare -A SECRET_MAP
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  SECRET_MAP["$key"]="$value"
done < "$SECRETS"

# Secrets that must be present in the config file. The placeholder token is
# derived from the key name: the placeholder tokens are never written in this
# file, otherwise deploying it would inject the real secrets into the
# deployed copy of this script.
SECRET_KEYS=(
  TELEGRAM_BOT_TOKEN_NOTIFY
  TELEGRAM_CHAT_ID_NOTIFY
  TELEGRAM_BOT_TOKEN_IGNOREHOST
  TELEGRAM_CHAT_ID_IGNOREHOST
  FAIL2BAN_UI_CALLBACK_SECRET
)

for key in "${SECRET_KEYS[@]}"; do
  ph="__${key}__"
  if [[ -z "${SECRET_MAP[$key]:-}" || "${SECRET_MAP[$key]}" == "$ph" ]]; then
    echo "ERROR: secret '$key' is missing or still a placeholder in $SECRETS" >&2
    exit 1
  fi
done

echo "Repository: $REPO_ROOT"
echo "Destination: $DEST"
echo "Config:      $SECRETS (values masked)"
for key in "${SECRET_KEYS[@]}"; do
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

# Copy the permissions and the owner of a reference file onto a target file.
#
# The mode and the owner are read with stat and applied numerically instead of
# using `chmod --reference` / `chown --reference`: those options are a GNU
# coreutils extension that BusyBox does not support, and the deployment can
# run inside a BusyBox based container.
#
# Best effort: a failure never aborts the deployment.
copy_file_meta() { # $1 = reference file, # $2 = target file
  local ref="$1" target="$2" mode owner
  # Bolt: Batch stat calls into a single invocation to reduce process creation overhead.
  local stat_out
  stat_out="$(stat -c '%a %u:%g' "$ref" 2>/dev/null)" && read -r mode owner <<< "$stat_out"
  [[ -n "$mode" ]] && chmod "$mode" "$target" 2>/dev/null || true
  [[ -n "$owner" ]] && chown "$owner" "$target" 2>/dev/null || true
  return 0
}

# Default permissions for a file that does not exist in the destination yet.
# The deployed scripts must stay executable, the configuration keeps the tight
# modes used by fail2ban.
default_mode() { # $1 = path relative to the destination
  case "$1" in
    scripts/*)                          printf '750' ;;
    action.d/*|filter.d/*|jail.d/*)    printf '640' ;;
    *)                                  printf '644' ;;
  esac
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
  if is_template "$rel"; then
    # Templates are copied as they are: they must never hold a secret.
    cp "$src" "$tmp"
  else
    render_to "$src" "$tmp"
    if grep -q '__[A-Z0-9_]*__' "$tmp"; then
      echo "ERROR: unresolved placeholder in $rel:" >&2
      grep -an '__[A-Z0-9_]*__' "$tmp" >&2
      rm -f "$tmp"
      status=1
      continue
    fi
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$(dirname "$dst")"
    # Preserve the destination's permissions/owner: fail2ban runs these as
    # root with tight modes (scripts are 750, ui action 600).
    if [[ -f "$dst" ]]; then
      copy_file_meta "$dst" "$tmp"
    else
      chmod "$(default_mode "$rel")" "$tmp" 2>/dev/null || true
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
