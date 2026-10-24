#!/bin/bash
# Log and backup rotation for fail2ban-scripts.
#
# Removes log and backup files older than a maximum age or larger than a
# maximum size from the fail2ban data directory. Runs detached when triggered
# by the notification scripts (like version_check.sh) or manually.
#
# Settings (read from config.local, overridable via CLI):
#   LOG_ROTATE_ENABLED   — true/false (default: ENABLED when key is absent)
#   LOG_ROTATE_MAX_AGE   — max age in days (default: 7)
#   LOG_ROTATE_MAX_SIZE  — max size in MB (default: 500)
#
# No host path is baked in: --dest DIR defaults to $FAIL2BAN_DATA_DIR or /data.
# Only the data directory root is scanned (-maxdepth 1): scripts/, action.d/,
# filter.d/, jail.d/ and configuration files are never touched.
#
# Files targeted for rotation (in the data directory root only):
#   *.log, .update_log, *.bak, *.tar.gz, *.dump, *.sql
#
# Usage:
#   scripts/log_rotate.sh                          # rotate using config defaults
#   scripts/log_rotate.sh --dest DIR               # target data directory
#   scripts/log_rotate.sh --max-age DAYS           # override max age
#   scripts/log_rotate.sh --max-size MB            # override max size
#   scripts/log_rotate.sh --log-dir DIR            # scan a specific directory
#   scripts/log_rotate.sh --secrets FILE           # config.local path
#   scripts/log_rotate.sh --dry-run                # preview without deleting
#   scripts/log_rotate.sh --quiet                   # silent unless errors
#   scripts/log_rotate.sh --force                   # ignore LOG_ROTATE_ENABLED
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/config.local"

# Defaults (overridden by config.local then by CLI flags)
MAX_AGE=""
MAX_SIZE_MB=""
DEST=""
LOG_DIR=""
SECRETS=""
DRY_RUN=0
QUIET=0
FORCE=0

# --- config helpers -------------------------------------------------------

# Read a value from a KEY=VALUE file. Prints the value or empty.
read_setting() { # $1 = file, $2 = key
  local file="$1" key="$2" value=""
  [[ -f "$file" ]] || { printf '%s' ""; return 0; }
  value="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d '=' -f 2- | tr -d '[:space:]')"
  printf '%s' "$value"
}

# Resolve the config.local path (CLI --secrets overrides, otherwise ROOT_DIR).
config_file() {
  printf '%s' "${SECRETS:-$CONFIG_FILE}"
}

is_log_rotate_disabled() {
  local value
  value="$(read_setting "$(config_file)" LOG_ROTATE_ENABLED)"
  # When the key is missing or empty, rotation is ENABLED by default.
  # Only an explicit false/0/no/off/disabled value disables it.
  case "${value,,}" in
    false|0|no|off|disabled) return 0 ;;
  esac
  return 1
}

# Load defaults from config.local when not overridden by CLI.
load_config_defaults() {
  local cfg
  cfg="$(config_file)"
  [[ -f "$cfg" ]] || return 0
  [[ -n "$MAX_AGE" ]]     || MAX_AGE="$(read_setting "$cfg" LOG_ROTATE_MAX_AGE)"
  [[ -n "$MAX_SIZE_MB" ]] || MAX_SIZE_MB="$(read_setting "$cfg" LOG_ROTATE_MAX_SIZE)"
}

say()  { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }
warn() { [[ "$QUIET" -eq 1 ]] || printf 'WARN  %s\n' "$*" >&2; }
fail() { printf 'ERROR %s\n' "$*" >&2; }

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- argument parsing -----------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-age)   MAX_AGE="${2:?--max-age requires a number}"; shift 2 ;;
    --max-size)  MAX_SIZE_MB="${2:?--max-size requires a number}"; shift 2 ;;
    --dest)      DEST="${2:?--dest requires a path}"; shift 2 ;;
    --log-dir)   LOG_DIR="${2:?--log-dir requires a path}"; shift 2 ;;
    --secrets)   SECRETS="${2:?--secrets requires a path}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --quiet)     QUIET=1; shift ;;
    --force)      FORCE=1; shift ;;
    -h|--help)   usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# --- main ------------------------------------------------------------------

# If the user passed --secrets, use it as the config file for both the
# enabled-check and the default loading.
if [[ -n "$SECRETS" ]]; then
  CONFIG_FILE="$SECRETS"
fi

# Refuse to run when disabled (unless --force).
if [[ "$FORCE" -eq 0 ]] && is_log_rotate_disabled; then
  say "log rotation disabled by configuration"
  exit 0
fi

# Load defaults from config.local when not overridden on the command line.
load_config_defaults

# Apply final defaults.
[[ -n "$MAX_AGE" ]]     || MAX_AGE=7
[[ -n "$MAX_SIZE_MB" ]] || MAX_SIZE_MB=500

# Validate that MAX_AGE and MAX_SIZE_MB are purely numeric to prevent
# command injection in arithmetic contexts like $(( MAX_AGE * 86400 )).
if ! [[ "$MAX_AGE" =~ ^[0-9]+$ ]]; then
  fail "LOG_ROTATE_MAX_AGE must be a positive integer, got '$MAX_AGE'"
  exit 1
fi

if ! [[ "$MAX_SIZE_MB" =~ ^[0-9]+$ ]]; then
  fail "LOG_ROTATE_MAX_SIZE must be a positive integer, got '$MAX_SIZE_MB'"
  exit 1
fi

# Determine the target directory.
if [[ -z "$DEST" ]]; then
  DEST="${FAIL2BAN_DATA_DIR:-/data}"
fi

if [[ -z "$LOG_DIR" ]]; then
  # Default: scan the data directory root itself (-maxdepth 1).
  TARGET_DIR="$DEST"
  MAX_DEPTH=1
else
  TARGET_DIR="$LOG_DIR"
  MAX_DEPTH=1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  say "log directory '$TARGET_DIR' does not exist, nothing to rotate"
  exit 0
fi

# Convert max size to bytes.
MAX_SIZE=$(( MAX_SIZE_MB * 1024 * 1024 ))

# Cutoff timestamp: files older than this are removed.
CUTOFF=$(( $(date +%s) - MAX_AGE * 86400 ))

# Find files to consider: log and backup patterns, top-level only.
declare -a candidates=()
while IFS= read -r -d '' file; do
  candidates+=("$file")
done < <(
  find "$TARGET_DIR" -maxdepth "$MAX_DEPTH" -type f \( \
      -name '*.log' -o -name '.update_log' -o \
      -name '*.bak' -o -name '*.tar.gz' -o \
      -name '*.dump' -o -name '*.sql' \
    \) -print0 2>/dev/null
)

if [[ ${#candidates[@]} -eq 0 ]]; then
  say "no log/backup files found in '$TARGET_DIR'"
  exit 0
fi

say "Rotating logs/backups in '$TARGET_DIR':"
say "  Max age: ${MAX_AGE} days"
say "  Max size: ${MAX_SIZE_MB} MB"
say ""

deleted=0
kept=0
errors=0

for file in "${candidates[@]}"; do
  [[ -f "$file" ]] || continue

  file_age="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
  file_size="$(stat -c %s "$file" 2>/dev/null || echo 0)"

  if [[ "$file_age" -eq 0 ]]; then
    kept=$((kept + 1))
    continue
  fi

  is_old=0
  is_large=0

  (( file_age < CUTOFF )) && is_old=1
  (( file_size > MAX_SIZE )) && is_large=1

  if [[ "$is_old" -eq 1 || "$is_large" -eq 1 ]]; then
    reason=""
    if [[ "$is_old" -eq 1 && "$is_large" -eq 1 ]]; then
      reason="old AND large"
    elif [[ "$is_old" -eq 1 ]]; then
      reason="old"
    else
      reason="large"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "DRY-RUN: would delete ($reason): $file"
      deleted=$((deleted + 1))
    else
      if rm -f "$file" 2>/dev/null; then
        say "DELETED ($reason): $file"
        deleted=$((deleted + 1))
      else
        warn "failed to delete: $file"
        errors=$((errors + 1))
      fi
    fi
  else
    kept=$((kept + 1))
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  say ""
  say "DRY-RUN complete: would delete $deleted, keep $kept, $errors errors"
else
  say ""
  say "Rotation complete: deleted $deleted, kept $kept, $errors errors"
fi

exit 0