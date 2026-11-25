#!/bin/bash

# Sends fancy formatted messages using Telegram
# to alert webmaster of banning with enhanced visual presentation.

# Require one argument, one of the following
# start
# stop
# ban
# unban
# Optional second argument: Ip for ban/unban

# Telegram Bot Credentials
# Secrets are injected at deploy time by scripts/deploy.sh from config.local
API_TOKEN="__TELEGRAM_BOT_TOKEN_NOTIFY__"
CHAT_ID="__TELEGRAM_CHAT_ID_NOTIFY__"
TELEGRAM_URL="https://api.telegram.org/bot${API_TOKEN}/sendMessage"

# Emojis for different actions
EMOJI_START="🚀"
EMOJI_STOP="🛑"
EMOJI_BAN="⛔"
EMOJI_UNBAN="✅"
EMOJI_INFO="ℹ️"
EMOJI_WARNING="⚠️"
EMOJI_ERROR="❌"
EMOJI_LOCATION="📍"
EMOJI_NETWORK="🌐"

# Display usage information
function show_usage {
  echo "Usage: $0 action <ip>"
  echo "Where action start, stop, ban, unban"
  echo "and IP is optional passed to ban, unban"
  exit 1
}

# Validate that $1 is a real IP address using the same strict parser the
# top-level argument check uses (python3 ipaddress). The previous bash regex
# (^[0-9a-fA-F:.]+$) also accepted malformed values such as leading-zero
# octets ("01.2.3.4") and "1.2.3.04", which then reached the DNS resolver and
# the ipapi.co URL — a malformed value must never leave the process.
function is_valid_ip {
  python3 -c "import ipaddress,sys; ipaddress.ip_address(sys.argv[1])" "$1" 2>/dev/null
}

# Perform reverse DNS lookup
function reverse_dns_lookup {
  # Only perform the lookup for a validated IP address to avoid injection.
  if ! is_valid_ip "$1"; then
    echo "Not available"
    return 0
  fi
  # Sentinel: do not resolve (or leak) hostnames for non-public addresses.
  if python3 -c "import ipaddress,sys; a=ipaddress.ip_address(sys.argv[1]); raise SystemExit(0 if (a.is_private or a.is_loopback or a.is_link_local or a.is_reserved or a.is_multicast) else 1)" "$1" 2>/dev/null; then
    echo "Not available"
    return 0
  fi
  python3 -c "import socket, sys; socket.setdefaulttimeout(10); print(socket.gethostbyaddr(sys.argv[1])[0])" "$1" 2>/dev/null || echo "Not available"
}

# Get geographical location
function get_geo_location {
  # Only query the geo API for a validated IP address to avoid SSRF / injection.
  # Use the strict ipaddress parser (rejects leading-zero octets, ports, and
  # any non-IP value) before building the ipapi.co URL.
  if ! is_valid_ip "$1"; then
    echo "Not available"
    return 0
  fi
  # Reject non-public addresses: never query the geo API for private,
  # loopback, link-local, reserved or multicast ranges.
  if python3 -c "import ipaddress,sys; a=ipaddress.ip_address(sys.argv[1]); raise SystemExit(0 if (a.is_private or a.is_loopback or a.is_link_local or a.is_reserved or a.is_multicast) else 1)" "$1" 2>/dev/null; then
    echo "Not available"
    return 0
  fi
  python3 -c "import urllib.request, json, sys; data = json.loads(urllib.request.urlopen('https://ipapi.co/' + sys.argv[1] + '/json/', timeout=10).read()); print(f\"{data.get('city','?')}, {data.get('region','?')}, {data.get('country_name','?')}\") " "$1" 2>/dev/null || echo "Not available"
}

# Get current timestamp
function get_timestamp {
  date '+%Y-%m-%d %H:%M:%S %Z'
}

# Format a duration in seconds into a human-readable string (e.g. "1h 30m", "45m", "30s")
function format_duration {
  local secs="${1:-0}"
  [[ "$secs" =~ ^[0-9]+$ ]] || { echo "$secs"; return; }
  if (( secs >= 3600 )); then
    local h=$((secs / 3600))
    local m=$(((secs % 3600) / 60))
    if (( m > 0 )); then echo "${h}h ${m}m"; else echo "${h}h"; fi
  elif (( secs >= 60 )); then
    local m=$((secs / 60))
    local r=$((secs % 60))
    if (( r > 0 )); then echo "${m}m ${r}s"; else echo "${m}m"; fi
  else
    echo "${secs}s"
  fi
}

# Version of the deployed scripts, shown in every message: it tells which
# release is running (and therefore whether the automatic update has already
# been applied). The file is looked up in the fail2ban data directory and,
# as a fallback, next to the scripts themselves.
function get_scripts_version {
  local version_file=""
  if [[ -n "${FAIL2BAN_DATA_DIR:-}" && -f "$FAIL2BAN_DATA_DIR/VERSION" ]]; then
    version_file="$FAIL2BAN_DATA_DIR/VERSION"
  fi
  if [[ -z "$version_file" ]]; then
    version_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION"
  fi
  local version="unknown"
  if [[ -f "$version_file" ]]; then
    read -r version < "$version_file" 2>/dev/null || true
    version="${version//[[:space:]]/}"
    [[ -n "$version" ]] || version="unknown"
  fi
  printf '%s' "$version"
}

# Format message with better presentation
function format_message {
  local action="$1"
  local ip="$2"
  local reverse_dns="$3"
  local geo_location="$4"
  local ban_duration="${5:-}"
  local jail="${6:-}"
  local banned_duration="${7:-}"
  
  local timestamp=$(get_timestamp)
  local raw_hostname=$(hostname)
  local scripts_version=$(get_scripts_version)

  # Escape user/host-controlled values to prevent HTML injection
  local safe_hostname=$(escape_html "$raw_hostname")

  case "$action" in
    "start")
      echo -e "<b>${EMOJI_START} Fail2ban Service Started</b>\n\n"\
              "<b>🖥️  Server:</b> ${safe_hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📦 Scripts version:</b> ${scripts_version}\n"\
              "<b>📝 Status:</b> Service has been started successfully"
      ;;
    "stop")
      echo -e "<b>${EMOJI_STOP} Fail2ban Service Stopped</b>\n\n"\
              "<b>🖥️  Server:</b> ${safe_hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📦 Scripts version:</b> ${scripts_version}\n"\
              "<b>📝 Status:</b> Service has been stopped"
      ;;
    "ban")
      local recidivist="No"
      if [[ "${jail,,}" == *recidive* ]]; then recidivist="Yes"; fi
      echo -e "<b>${EMOJI_BAN} IP Address Banned</b>\n\n"\
              "<b>🖥️  Server:</b> ${safe_hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📦 Scripts version:</b> ${scripts_version}\n"\
              "<b>🆔 IP:</b> ${ip}\n"\
              "<b>🌐 Reverse DNS:</b> ${reverse_dns}\n"\
              "<b>📍 Location:</b> ${geo_location}\n"\
              "<b>⏱️ Ban duration:</b> $(format_duration "${ban_duration}")\n"\
              "<b>🔁 Recidivist:</b> ${recidivist}"
      ;;
    "unban")
      echo -e "<b>${EMOJI_UNBAN} IP Address Unbanned</b>\n\n"\
              "<b>🖥️  Server:</b> ${safe_hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📦 Scripts version:</b> ${scripts_version}\n"\
              "<b>🆔 IP:</b> ${ip}\n"\
              "<b>🌐 Reverse DNS:</b> ${reverse_dns}\n"\
              "<b>📍 Location:</b> ${geo_location}\n"\
              "<b>⏱️ Banned for:</b> $(format_duration "${banned_duration}")"
      ;;
  esac
}

# Escape HTML special characters for Telegram's HTML parse_mode
function escape_html {
  local val="$1"
  # Bolt: Use pure Bash string replacement to avoid spawning sed and subshells,
  # significantly improving performance by eliminating process creation overhead.
  val="${val//&/&amp;}"
  val="${val//</&lt;}"
  val="${val//>/&gt;}"
  val="${val//\"/&quot;}"
  printf '%s' "$val"
}

# Send notification with enhanced formatting
function send_msg {
  local action="$1"
  local ip="$2"
  local ban_duration="${3:-}"
  local jail="${4:-}"

  local banned_duration=""
  # Storage for ban start timestamps
  local data_dir="${FAIL2BAN_DATA_DIR:-/tmp}"
  local store_dir="$data_dir/fail2ban-bantimes"
  mkdir -p "$store_dir" 2>/dev/null || true
  local store_file="$store_dir/${ip//[^0-9a-fA-F.:]/_}"

  if [[ "$action" == "ban" ]]; then
    date +%s > "$store_file" 2>/dev/null || true
  fi
  if [[ "$action" == "unban" && -f "$store_file" ]]; then
    local start now elapsed
    read -r start < "$store_file" 2>/dev/null || true
    now=$(date +%s)
    if [[ "$start" =~ ^[0-9]+$ ]]; then
      elapsed=$((now - start))
      banned_duration="${elapsed}"
    fi
    rm -f "$store_file" 2>/dev/null || true
  fi

  local reverse_dns="Not checked"
  local geo_location="Not checked"
  
  # Get additional info for ban/unban actions
  if [[ "$action" == "ban" || "$action" == "unban" ]] && [ -n "$ip" ]; then
    # Bolt: Execute DNS lookup and GeoIP requests concurrently using background jobs
    # to avoid sequential blocking, reducing execution latency.
    local dns_tmp geo_tmp
    dns_tmp=$(mktemp)
    geo_tmp=$(mktemp)
    # Sentinel: the temp files are removed explicitly below, before this
    # function returns. A `trap ... RETURN` here would NOT be scoped to this
    # function: bash keeps it installed and fires it again when the *caller*
    # returns (and when any later callee returns). By then dns_tmp/geo_tmp are
    # out of scope, so the second firing runs `rm -f "" ""` under `set -u` and
    # aborts the caller just as it returns a value.

    reverse_dns_lookup "$ip" > "$dns_tmp" &
    local dns_pid=$!

    get_geo_location "$ip" > "$geo_tmp" &
    local geo_pid=$!

    wait $dns_pid
    wait $geo_pid

    # Bolt: Replace $(cat ...) with $(<...) to avoid spawning a subshell process
    reverse_dns=$(<"$dns_tmp")
    [[ -n "$reverse_dns" ]] || reverse_dns="Not available"

    geo_location=$(<"$geo_tmp")
    [[ -n "$geo_location" ]] || geo_location="Not available"

    rm -f "$dns_tmp" "$geo_tmp"
  fi
  
  # Escape user-controlled inputs to prevent HTML injection in Telegram message
  local safe_ip=$(escape_html "$ip")
  local safe_reverse_dns=$(escape_html "$reverse_dns")
  local safe_geo_location=$(escape_html "$geo_location")

  # Format the message
  local message=$(format_message "$action" "$safe_ip" "$safe_reverse_dns" "$safe_geo_location" "$ban_duration" "$jail" "$banned_duration")
  
  # Send message via Telegram API
  # Bolt: Enforce a timeout to prevent Fail2Ban from blocking indefinitely
  # Sentinel: capture HTTP status separately from body so the success check
  # cannot be fooled by a "200" substring inside the response body.
  local body_file http_code curl_rc
  body_file=$(mktemp)
  # Sentinel: the temp body file is removed explicitly below, after curl
  # returns. A `trap ... RETURN` here would leak and fire again when the
  # caller returns, breaking it under `set -u` (see top of send_msg).
  http_code=$(curl --max-time 10 -s -X POST "$TELEGRAM_URL" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="$message" \
    -d parse_mode="HTML" \
    -o "$body_file" \
    -w "%{http_code}")
  curl_rc=$?
  rm -f "$body_file"

  # Check if message was sent successfully
  if [[ $curl_rc -ne 0 || "$http_code" != "200" ]]; then
    echo "Error: Failed to send Telegram message. curl_rc=$curl_rc HTTP response code: $http_code" >&2
    return 1
  fi
  return 0
}

# Trigger the automatic update of the deployed scripts.
#
# The updater (scripts/version_check.sh) is started detached: it must never
# delay the notification nor keep the output pipe open (fail2ban waits for
# the output of the action). It is a no-op when:
#   - FAIL2BAN_DATA_DIR is not set (the scripts are not running inside the
#     deployed fail2ban data directory),
#   - the updater is missing,
#   - the auto-update is disabled or was already performed today.
function trigger_auto_update {
  local data_dir="${FAIL2BAN_DATA_DIR:-}"
  local updater
  [[ -n "$data_dir" ]] || return 0
  updater="$data_dir/scripts/version_check.sh"
  [[ -f "$updater" && -x "$updater" ]] || return 0
  nohup "$updater" --dest "$data_dir" --quiet >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# Trigger the automatic log/backup rotation in the data directory.
#
# The rotator (scripts/log_rotate.sh) is started detached: it must never
# delay the notification nor keep the output pipe open. It is a no-op when:
#   - FAIL2BAN_DATA_DIR is not set (the scripts are not running inside the
#     deployed fail2ban data directory),
#   - the rotator is missing,
#   - the rotation is disabled (LOG_ROTATE_ENABLED=false in config.local).
function trigger_log_rotate {
  local data_dir="${FAIL2BAN_DATA_DIR:-}"
  local rotator
  [[ -n "$data_dir" ]] || return 0
  rotator="$data_dir/scripts/log_rotate.sh"
  [[ -f "$rotator" && -x "$rotator" ]] || return 0
  nohup "$rotator" --dest "$data_dir" --quiet >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# Check for script arguments
if [ $# -lt 1 ]; then
  show_usage
fi

# Validate IP address if provided (supports IPv4 and IPv6)
if [ -n "$2" ]; then
  if ! is_valid_ip "$2"; then
    echo "Error: Invalid IP address format" >&2
    exit 1
  fi
fi

# Take action depending on argument
status=0
case "$1" in
  "start")
    send_msg "start" || status=$?
    ;;
  "stop")
    send_msg "stop" || status=$?
    ;;
  "ban")
    if [ -n "$2" ]; then
      send_msg "ban" "$2" "$3" "$4" || status=$?
    else
      echo "Error: IP address required for ban action" >&2
      show_usage
    fi
    ;;
  "unban")
    if [ -n "$2" ]; then
      send_msg "unban" "$2" || status=$?
    else
      echo "Error: IP address required for unban action" >&2
      show_usage
    fi
    ;;
  *)
    echo "Error: Invalid action. Must be one of: start, stop, ban, unban" >&2
    show_usage
    ;;
esac

# Give the updater the chance to pull a newer release of the deployed scripts
# (no-op when the auto-update is disabled or already checked today).
trigger_auto_update

# Rotate old/large log and backup files in the data directory
# (no-op when FAIL2BAN_DATA_DIR is unset or the rotator is missing).
trigger_log_rotate

exit "$status"