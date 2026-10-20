#!/bin/bash
# Version check and auto-update for fail2ban-scripts.
#
# Behaviour:
#   - Runs at most once per day (timestamp file .last_update_check).
#   - Skipped entirely when auto-update is disabled (see is_auto_update_disabled).
#   - On a newer GitHub release it downloads the release archive, installs the
#     deployable files and reports the outcome through the Telegram notifier.
#   - The installed VERSION is exposed to the notifier so every Telegram
#     message can show which version is running.
#
# Auto-update can be disabled in two ways (first match wins):
#   1. a file named .disable_auto_update exists next to VERSION
#   2. config.local contains AUTO_UPDATE_ENABLED=false
#
# Usage:
#   scripts/version_check.sh            # daily check, may install an update
#   scripts/version_check.sh --force    # ignore the daily throttle
#   scripts/version_check.sh --check    # report only, never install
#   scripts/version_check.sh --quiet    # no output unless something happens
set -uo pipefail

REPO_OWNER="${FAIL2BAN_REPO_OWNER:-spupuz}"
REPO_NAME="${FAIL2BAN_REPO_NAME:-fail2ban-scripts}"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
CONFIG_FILE="$ROOT_DIR/config.local"
LAST_CHECK_FILE="$ROOT_DIR/.last_update_check"
DISABLE_FLAG_FILE="$ROOT_DIR/.disable_auto_update"
UPDATE_LOG="$ROOT_DIR/.update_log"
LOG_FILE="$ROOT_DIR/.version_check.log"

QUIET=0
FORCE=0
CHECK_ONLY=0

# Files installed by an update. config.local is never touched: it is host
# specific and never lives in a release.
INSTALLED_FILES=(
  "VERSION"
  "scripts/deploy.sh"
  "scripts/redact.sh"
  "scripts/version_check.sh"
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

log()  { printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true; }
say()  { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }
warn() { [[ "$QUIET" -eq 1 ]] || printf 'WARN  %s\n' "$*"; }
fail() { printf 'ERROR %s\n' "$*" >&2; log "ERROR $*"; }

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)  FORCE=1; shift ;;
    --check)  CHECK_ONLY=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# --- configuration helpers -------------------------------------------------

# Read a boolean-ish value out of a KEY=VALUE file. Prints the value or empty.
read_setting() { # $1 = file, $2 = key
  local file="$1" key="$2" value=""
  [[ -f "$file" ]] || { printf '%s' ""; return 0; }
  value="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d '=' -f 2- | tr -d '[:space:]')"
  printf '%s' "$value"
}

is_auto_update_disabled() {
  [[ -f "$DISABLE_FLAG_FILE" ]] && return 0

  local value
  value="$(read_setting "$CONFIG_FILE" AUTO_UPDATE_ENABLED)"
  case "${value,,}" in
    false|0|no|off|disabled) return 0 ;;
  esac
  return 1
}

# --- version helpers -------------------------------------------------------

current_version() {
  [[ -f "$VERSION_FILE" ]] || return 1
  tr -d '[:space:]' < "$VERSION_FILE"
}

latest_version() {
  local json tag
  json="$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' \
          "$GITHUB_API/releases/latest" 2>/dev/null)" || return 1
  tag="$(printf '%s' "$json" | grep -m1 '"tag_name"' | cut -d '"' -f 4)" || return 1
  [[ -n "$tag" ]] || return 1
  printf '%s' "${tag#v}"
}

# Returns 0 when $1 (candidate) is strictly newer than $2 (current).
version_is_newer() {
  local candidate="$1" current="$2"
  local -a c cur
  IFS='.' read -r -a c <<< "$candidate"
  IFS='.' read -r -a cur <<< "$current"
  local i
  for i in 0 1 2; do
    local cv="${c[i]:-0}" pv="${cur[i]:-0}"
    if (( 10#$cv > 10#$pv )); then return 0; fi
    if (( 10#$cv < 10#$pv )); then return 1; fi
  done
  return 1
}

# --- update installation ---------------------------------------------------

install_release() { # $1 = version
  local version="$1"
  local tmp archive extracted
  tmp="$(mktemp -d)" || return 1
  archive="$tmp/release.tar.gz"

  if ! curl -fsSL --max-time 60 -o "$archive" \
        "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/v${version}.tar.gz"; then
    rm -rf "$tmp"
    return 1
  fi

  if ! tar -xzf "$archive" -C "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi

  extracted="$(find "$tmp" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n 1)"
  if [[ -z "$extracted" ]]; then
    rm -rf "$tmp"
    return 1
  fi

  local rel
  for rel in "${INSTALLED_FILES[@]}"; do
    if [[ -f "$extracted/$rel" ]]; then
      mkdir -p "$ROOT_DIR/$(dirname "$rel")"
      cp -f "$extracted/$rel" "$ROOT_DIR/$rel" || true
    fi
  done
  chmod +x "$ROOT_DIR/scripts/"*.sh 2>/dev/null || true

  rm -rf "$tmp"
  return 0
}

# --- Telegram notification -------------------------------------------------

# Send a plain text message with the notify bot. Never fails the caller.
telegram_notify() { # $1 = message
  local message="$1" token chat_id payload
  token="$(read_setting "$CONFIG_FILE" TELEGRAM_BOT_TOKEN_NOTIFY)"
  chat_id="$(read_setting "$CONFIG_FILE" TELEGRAM_CHAT_ID_NOTIFY)"
  [[ -n "$token" && -n "$chat_id" ]] || return 0

  payload="$(printf '{"chat_id":"%s","text":"%s","parse_mode":"HTML","disable_web_page_preview":true}' \
             "$chat_id" "${message//\"/\\\"}")"

  curl -fsSL --max-time 20 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
       -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 || true
  return 0
}

# --- main ------------------------------------------------------------------

should_check_today() {
  [[ "$FORCE" -eq 1 ]] && return 0
  [[ -f "$LAST_CHECK_FILE" ]] || return 0
  [[ "$(cat "$LAST_CHECK_FILE" 2>/dev/null)" == "$(date '+%Y-%m-%d')" ]] && return 1
  return 0
}

mark_checked() {
  date '+%Y-%m-%d' > "$LAST_CHECK_FILE" 2>/dev/null || true
}

main() {
  local current latest

  current="$(current_version)" || { fail "VERSION file not found: $VERSION_FILE"; return 1; }
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail "Malformed VERSION: $current"; return 1; }

  if is_auto_update_disabled; then
    log "auto-update disabled by configuration"
    return 0
  fi

  if ! should_check_today; then
    log "already checked today, skipping"
    return 0
  fi
  mark_checked

  latest="$(latest_version)" || { log "could not reach GitHub releases API"; return 0; }
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log "unexpected latest version: $latest"; return 0; }

  if ! version_is_newer "$latest" "$current"; then
    log "up to date (current $current, latest $latest)"
    return 0
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    say "update available: $current -> $latest"
    return 0
  fi

  say "updating fail2ban-scripts: $current -> $latest"
  if ! install_release "$latest"; then
    fail "failed to install release $latest"
    telegram_notify "fail2ban-scripts: update to ${latest} failed (current ${current})."
    return 1
  fi

  {
    printf '=== %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'updated %s -> %s\n' "$current" "$latest"
  } >> "$UPDATE_LOG" 2>/dev/null || true

  say "updated to $latest"
  telegram_notify "🆙 fail2ban-scripts updated: ${current} ➜ ${latest}
The running scripts have been updated automatically. Reload fail2ban to apply: fail2ban-client reload"
  return 0
}

main
