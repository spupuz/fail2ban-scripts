#!/bin/bash
# Version check and auto-update for fail2ban-scripts.
#
# Behaviour:
#   - Runs at most once per interval (default 24h, configurable via
#     AUTO_UPDATE_CHECK_INTERVAL_HOURS). The timestamp file .last_update_check is
#     only written after a successful GitHub query.
#   - Skipped entirely when auto-update is disabled (see is_auto_update_disabled).
#   - On a newer GitHub release it downloads the release archive, installs the
#     deployable files and reports the outcome through the Telegram notifier.
#   - The installed VERSION is exposed to the notifier so every Telegram
#     message can show which version is running.
#   - With --dest DIR the installed release is deployed into DIR too. The
#     deployment is self-contained: the secrets are injected here, without
#     calling scripts/deploy.sh, so that an update always works whatever
#     version of the deploy script is currently installed.
#   - The installer discovers scripts/*.sh dynamically from the downloaded
#     release, so a new script added in a release is installed even when the
#     currently running version_check.sh does not list it yet (self-healing).
#
# The updater is meant to run from the directory that holds the deployed files
# (the fail2ban data directory): the telegram/ignore scripts call it with
# --dest <data dir> so that a new release is installed *and* applied without
# any manual step.
#
# Auto-update can be disabled in two ways (first match wins):
#   1. a file named .disable_auto_update exists next to VERSION
#   2. config.local contains AUTO_UPDATE_ENABLED=false
#
# The update refreshes the SCRIPTS only. The configuration files
# (action.d, filter.d, jail.d, jail.local, paths-overrides.local) are never
# touched automatically: jail.local is managed by the Fail2Ban-UI and the
# other ones change the behaviour of the running service. Use --with-config
# to refresh them as well, or run scripts/deploy.sh by hand.
#
# Usage:
#   scripts/version_check.sh            # daily check, may install an update
#   scripts/version_check.sh --force    # ignore the daily throttle
#   scripts/version_check.sh --check    # report only, never install
#   scripts/version_check.sh --quiet    # no output unless something happens
#   scripts/version_check.sh --dest DIR # deploy the update into DIR afterwards
#   scripts/version_check.sh --secrets FILE  # secrets used by the deploy step
#   scripts/version_check.sh --with-config   # refresh the config files too
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
LOCK_DIR="$ROOT_DIR/.update_lock"

QUIET=0
FORCE=0
CHECK_ONLY=0
WITH_CONFIG=0
DEST=""
SECRETS=""
LOCK_HELD=0
RENDER_IN_PLACE=0
UPDATE_FILES=()
RENDER_FILES=()

# Files installed by an update: the scripts only. config.local is never
# touched: it is host specific and never lives in a release.
INSTALLED_FILES=(
  "VERSION"
  "scripts/deploy.sh"
  "scripts/redact.sh"
  "scripts/version_check.sh"
  "scripts/log_rotate.sh"
  "scripts/fail2ban-telegram.sh"
  "scripts/ignorehost.sh"
)

# Configuration files: installed only when --with-config is given.
CONFIG_FILES=(
  "action.d/telegram.local"
  "action.d/iptables-nft.local"
  "action.d/ui-custom-action.conf"
  "filter.d/npm-docker.conf"
  "jail.d/npm-docker.local"
  "jail.local"
  "paths-overrides.local"
)

# Files that consume the secrets: only these are rendered with the secret
# values. The helper scripts (deploy.sh, redact.sh, version_check.sh) are
# templates: they read the secrets from config.local when they run, so they
# are installed exactly as they are and never hold a secret themselves.
SECRET_FILES=(
  "scripts/fail2ban-telegram.sh"
  "scripts/ignorehost.sh"
)

log()  { printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true; }
say()  { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }
warn() { log "WARN $*"; [[ "$QUIET" -eq 1 ]] || printf 'WARN  %s\n' "$*"; }
fail() { printf 'ERROR %s\n' "$*" >&2; log "ERROR $*"; }

usage() {
  sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --check)   CHECK_ONLY=1; shift ;;
    --quiet)   QUIET=1; shift ;;
    --with-config) WITH_CONFIG=1; shift ;;
    --dest)    DEST="${2:?--dest requires a path}"; shift 2 ;;
    --secrets) SECRETS="${2:?--secrets requires a path}"; shift 2 ;;
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

# --- locking ---------------------------------------------------------------

# Only one updater may run at a time. mkdir is atomic, so it is used as the
# lock primitive: the telegram/ignore scripts can trigger the updater while
# another one is still working.
acquire_lock() {
  local attempt now age
  for attempt in 1 2; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      return 0
    fi
    # A lock left behind by a killed process must not block the updater for
    # ever: consider it stale after one hour.
    now="$(date +%s)"
    age="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || printf '%s' "$now")"
    if (( now - age > 3600 )); then
      log "removing stale update lock ($(( now - age )) seconds old)"
      rm -rf "$LOCK_DIR"
      continue
    fi
    return 1
  done
  return 1
}

release_lock() {
  [[ "$LOCK_HELD" -eq 1 ]] && rm -rf "$LOCK_DIR"
  LOCK_HELD=0
  return 0
}

trap release_lock EXIT

# --- version helpers -------------------------------------------------------

current_version() {
  [[ -f "$VERSION_FILE" ]] || return 1
  tr -d '[:space:]' < "$VERSION_FILE"
}

latest_version() {
  local json tag url
  json="$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' \
          "$GITHUB_API/releases/latest" 2>/dev/null)" || json=""
  tag="$(printf '%s' "$json" | grep -m1 '"tag_name"' | cut -d '"' -f 4)" || tag=""
  if [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "${tag#v}"
    return 0
  fi
  # Fallback: the API is rate limited (60 requests per hour and IP), the
  # releases page redirects to the latest tag and is not rate limited.
  url="$(curl -fsSL --max-time 15 -o /dev/null -w '%{url_effective}' \
         "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest" 2>/dev/null)" || return 1
  tag="${url##*/}"
  [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
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

# Default permissions for a file that does not exist yet. The deployed
# scripts must stay executable, the configuration keeps the tight modes used
# by fail2ban.
default_mode() { # $1 = destination path
  case "$1" in
    */scripts/*)                            printf '750' ;;
    */action.d/*|*/filter.d/*|*/jail.d/*)   printf '640' ;;
    *)                                      printf '644' ;;
  esac
}

# Replace a file atomically: a script that is running right now (for example
# the telegram notifier that triggered this update) keeps its own inode and is
# not corrupted by the replacement.
install_file() { # $1 = source file, # $2 = destination file
  local src="$1" dst="$2" tmp
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 1
  tmp="$(mktemp "$(dirname "$dst")/.install.XXXXXX" 2>/dev/null)" || return 1
  if ! cp "$src" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -f "$dst" ]]; then
    # Keep the permissions/owner of the file that is being replaced (fail2ban
    # runs these as root with tight modes).
    chmod --reference="$dst" "$tmp" 2>/dev/null || true
    chown --reference="$dst" "$tmp" 2>/dev/null || true
  else
    chmod "$(default_mode "$dst")" "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
  return 0
}

# Render a file, injecting the secrets into the placeholder tokens. The
# substitution is done at byte level, so tokens with special characters stay
# safe.
render_file() { # $1 = source file, $2 = destination file, $3 = secrets file
  python3 - "$1" "$2" "$3" <<'PY'
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

# The secrets file used to render the deployed files.
secrets_file() {
  printf '%s' "${SECRETS:-$ROOT_DIR/config.local}"
}

# True when the file consumes the secrets and must be rendered.
is_rendered() { # $1 = path relative to the installation root
  local rel
  for rel in "${RENDER_FILES[@]}"; do
    [[ "$rel" == "$1" ]] && return 0
  done
  return 1
}

# The keys that must be resolved in a rendered file: the ones configured in
# the secrets file plus the ones documented by the repository
# (config.local.example). A key that is documented but not configured means a
# missing secret, and the deployment must stop instead of writing a broken
# file.
expected_secret_keys() {
  local file
  for file in "$(secrets_file)" "$ROOT_DIR/config.local.example"; do
    [[ -f "$file" ]] || continue
    grep -Eo '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null \
      | tr -d ' =' | sort -u
  done
}

# Check a rendered file: no secret placeholder may be left in it.
check_rendered() { # $1 = file
  local file="$1" key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if grep -q -- "__${key}__" "$file"; then
      fail "unresolved placeholder __${key}__ in $file (missing secret?)"
      return 1
    fi
  done < <(expected_secret_keys)
  # Any other leftover token is only reported: it can be a documentation
  # placeholder (a word between double underscores) inside a comment.
  local leftover
  leftover="$(grep -oE '__[A-Z0-9_]+__' "$file" 2>/dev/null | sort -u | tr '\n' ' ')"
  [[ -n "$leftover" ]] && warn "leftover placeholder(s) in $file: $leftover"
  return 0
}

# Copy a file into the destination, injecting the secrets. The file is
# written atomically and keeps the permissions of the file it replaces.
# This is deliberately self-contained (it does not call scripts/deploy.sh):
# an update must work whatever version of the deploy script is installed.
deploy_file() { # $1 = source file, $2 = destination file
  local src="$1" dst="$2" tmp secrets
  secrets="$(secrets_file)"
  if [[ ! -f "$secrets" ]]; then
    fail "config file not found: $secrets"
    return 1
  fi
  mkdir -p "$(dirname "$dst")"
  tmp="$(mktemp "$(dirname "$dst")/.deploy.XXXXXX" 2>/dev/null)" || return 1
  if ! render_file "$src" "$tmp" "$secrets"; then
    rm -f "$tmp"
    fail "could not render $src"
    return 1
  fi
  if ! check_rendered "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ -f "$dst" ]]; then
    chmod --reference="$dst" "$tmp" 2>/dev/null || true
    chown --reference="$dst" "$tmp" 2>/dev/null || true
  else
    chmod "$(default_mode "$dst")" "$tmp" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
  return 0
}

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
  for rel in "${UPDATE_FILES[@]}"; do
    if [[ -f "$extracted/$rel" ]]; then
      mkdir -p "$ROOT_DIR/$(dirname "$rel")"
      if [[ "$RENDER_IN_PLACE" -eq 1 ]] && is_rendered "$rel"; then
        # The installation root is the live directory: the secrets are
        # injected right away, the deployed files must never be left with the
        # placeholder tokens.
        if ! deploy_file "$extracted/$rel" "$ROOT_DIR/$rel"; then
          rm -rf "$tmp"
          return 1
        fi
      else
        install_file "$extracted/$rel" "$ROOT_DIR/$rel" || warn "could not install $rel"
      fi
    fi
  done

  # Also install any scripts/*.sh present in the release but not listed in
  # UPDATE_FILES: a new script added in this release may not be known to the
  # currently running version_check.sh (which may be older). This makes the
  # updater self-healing without requiring a manual deploy for new scripts.
  local extra rel2 found
  while IFS= read -r -d '' extra; do
    rel2="scripts/$(basename "$extra")"
    found=0
    for rel in "${UPDATE_FILES[@]}"; do
      [[ "$rel" == "$rel2" ]] && found=1 && break
    done
    [[ "$found" -eq 0 ]] || continue
    mkdir -p "$ROOT_DIR/scripts"
    if [[ "$RENDER_IN_PLACE" -eq 1 ]] && is_rendered "$rel2"; then
      if ! deploy_file "$extra" "$ROOT_DIR/$rel2"; then
        rm -rf "$tmp"
        return 1
      fi
    else
      install_file "$extra" "$ROOT_DIR/$rel2" || warn "could not install $rel2"
    fi
  done < <(find "$extracted/scripts" -maxdepth 1 -name '*.sh' -print0 2>/dev/null)

  chmod +x "$ROOT_DIR/scripts/"*.sh 2>/dev/null || true

  rm -rf "$tmp"
  return 0
}

# --- deployment ------------------------------------------------------------

# Deploy the installed release into the live fail2ban directory. When the
# installation root is the live directory itself the files have already been
# rendered in place, otherwise they are copied from the installation root
# into the destination: the files that consume the secrets are rendered, the
# templates are copied as they are.
deploy_release() { # $1 = destination directory
  local dest="$1" rel

  if [[ "$RENDER_IN_PLACE" -eq 0 ]]; then
    for rel in "${UPDATE_FILES[@]}"; do
      if [[ -f "$ROOT_DIR/$rel" ]]; then
        if is_rendered "$rel"; then
          if ! deploy_file "$ROOT_DIR/$rel" "$dest/$rel"; then
            fail "could not deploy $rel into $dest"
            return 1
          fi
        else
          if ! install_file "$ROOT_DIR/$rel" "$dest/$rel"; then
            fail "could not deploy $rel into $dest"
            return 1
          fi
        fi
      fi
    done

    # Also deploy any scripts/*.sh present in ROOT_DIR but not listed in
    # UPDATE_FILES (same self-healing rationale as install_release).
    local extra rel2 found
    while IFS= read -r -d '' extra; do
      rel2="scripts/$(basename "$extra")"
      found=0
      for rel in "${UPDATE_FILES[@]}"; do
        [[ "$rel" == "$rel2" ]] && found=1 && break
      done
      [[ "$found" -eq 0 ]] || continue
      if is_rendered "$rel2"; then
        if ! deploy_file "$extra" "$dest/$rel2"; then
          fail "could not deploy $rel2 into $dest"
          return 1
        fi
      else
        if ! install_file "$extra" "$dest/$rel2"; then
          fail "could not deploy $rel2 into $dest"
          return 1
        fi
      fi
    done < <(find "$ROOT_DIR/scripts" -maxdepth 1 -name '*.sh' -print0 2>/dev/null)
  fi

  # fail2ban only needs a reload when its configuration changed
  if [[ "$WITH_CONFIG" -eq 1 ]]; then
    reload_fail2ban
  fi
  return 0
}

# Reload fail2ban so the new configuration takes effect. Best effort: the
# updater also runs on hosts where fail2ban is not installed.
reload_fail2ban() {
  command -v fail2ban-client >/dev/null 2>&1 || return 0
  if ! fail2ban-client reload >> "$UPDATE_LOG" 2>&1; then
    log "fail2ban-client reload failed"
    return 1
  fi
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

# --- throttle helpers ------------------------------------------------------

check_interval_seconds() {
  local hours value
  value="$(read_setting "$CONFIG_FILE" AUTO_UPDATE_CHECK_INTERVAL_HOURS)"
  if [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 ]]; then
    hours="$value"
  else
    hours=24
  fi
  printf '%s' $(( hours * 3600 ))
}

last_check_epoch() {
  local raw ts
  [[ -f "$LAST_CHECK_FILE" ]] || { printf '%s' 0; return 0; }
  raw="$(tr -d '[:space:]' < "$LAST_CHECK_FILE" 2>/dev/null)"
  if [[ "$raw" =~ ^[0-9]{10}$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  if [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    # Backward compatibility: treat a calendar-day stamp as checked at
    # start of that day in the local timezone.
    ts="$(date -d "$raw 00:00:00" +%s 2>/dev/null || printf '%s' 0)"
    printf '%s' "$ts"
    return 0
  fi
  printf '%s' 0
}

should_check_now() {
  [[ "$FORCE" -eq 1 ]] && return 0
  local last now interval
  last="$(last_check_epoch)"
  (( last == 0 )) && return 0
  now="$(date +%s)"
  interval="$(check_interval_seconds)"
  (( now - last >= interval )) && return 0
  return 1
}

mark_checked() {
  date +%s > "$LAST_CHECK_FILE" 2>/dev/null || true
}

should_check_today() {
  # Kept for backward compatibility with older code/tests.
  should_check_now
}

# --- main ------------------------------------------------------------------

main() {
  local current latest

  current="$(current_version)" || { fail "VERSION file not found: $VERSION_FILE"; return 1; }
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail "Malformed VERSION: $current"; return 1; }

  if is_auto_update_disabled; then
    log "auto-update disabled by configuration"
    return 0
  fi

  if ! should_check_now; then
    log "already checked recently, skipping"
    return 0
  fi

  if ! acquire_lock; then
    log "another update is already running, skipping"
    return 0
  fi

  latest="$(latest_version)" || { log "could not reach GitHub releases API"; release_lock; return 0; }
  mark_checked
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
  log "updating fail2ban-scripts: $current -> $latest"

  # Files installed by this update: the scripts, plus the configuration only
  # when it was explicitly requested.
  UPDATE_FILES=("${INSTALLED_FILES[@]}")
  RENDER_FILES=("${SECRET_FILES[@]}")
  if [[ "$WITH_CONFIG" -eq 1 ]]; then
    UPDATE_FILES+=("${CONFIG_FILES[@]}")
    RENDER_FILES+=("${CONFIG_FILES[@]}")
  fi

  # When the destination is the installation root itself (the deployed
  # scripts), the files are rendered in place: the live files must never be
  # left with the placeholder tokens.
  RENDER_IN_PLACE=0
  if [[ -n "$DEST" ]]; then
    local dest_abs
    dest_abs="$(cd "$DEST" 2>/dev/null && pwd)" || dest_abs="$DEST"
    [[ "$dest_abs" == "$ROOT_DIR" ]] && RENDER_IN_PLACE=1
  fi

  if ! install_release "$latest"; then
    fail "failed to install release $latest"
    telegram_notify "fail2ban-scripts: update to ${latest} failed (current ${current})."
    return 1
  fi

  if [[ -n "$DEST" ]] && ! deploy_release "$DEST"; then
    fail "failed to deploy the update into $DEST"
    telegram_notify "fail2ban-scripts: update to ${latest} was installed but the deploy into ${DEST} failed. Run scripts/deploy.sh --apply --dest ${DEST} manually."
    return 1
  fi

  {
    printf '=== %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'updated %s -> %s\n' "$current" "$latest"
  } >> "$UPDATE_LOG" 2>/dev/null || true

  say "updated to $latest"
  if [[ -n "$DEST" ]]; then
    if [[ "$WITH_CONFIG" -eq 1 ]]; then
      telegram_notify "🆙 fail2ban-scripts updated: ${current} ➜ ${latest}
The scripts and the configuration have been updated automatically and fail2ban has been reloaded."
    else
      telegram_notify "🆙 fail2ban-scripts updated: ${current} ➜ ${latest}
The running scripts have been updated automatically. The configuration files were not touched."
    fi
  else
    telegram_notify "🆙 fail2ban-scripts updated: ${current} ➜ ${latest}
The running scripts have been updated automatically. Reload fail2ban to apply: fail2ban-client reload"
  fi
  return 0
}

main
