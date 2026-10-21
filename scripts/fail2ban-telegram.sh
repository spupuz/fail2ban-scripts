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

# Perform reverse DNS lookup
function reverse_dns_lookup {
  python3 -c "import socket; print(socket.gethostbyaddr('$1')[0])" 2>/dev/null || echo "Not available"
}

# Get geographical location
function get_geo_location {
  python3 -c "import urllib.request, json; data = json.loads(urllib.request.urlopen('https://ipapi.co/$1/json/').read()); print(f'{data[\"city\"]}, {data[\"region\"]}, {data[\"country_name\"]}')" 2>/dev/null || echo "Not available"
}

# Get current timestamp
function get_timestamp {
  date '+%Y-%m-%d %H:%M:%S %Z'
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
    version="$(tr -d '[:space:]' < "$version_file" 2>/dev/null)"
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
  
  local timestamp=$(get_timestamp)
  local hostname=$(hostname)
  local scripts_version=$(get_scripts_version)

  case "$action" in
    "start")
      echo -e "<b>${EMOJI_START} Fail2ban Service Started</b>\n\n"\
              "<b>🖥️  Server:</b> ${hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📦 Scripts version:</b> ${scripts_version}\n"\
              "<b>📝 Status:</b> Service has been started successfully"
      ;;
    "stop")
      echo -e "<b>${EMOJI_STOP} Fail2ban Service Stopped</b>\n\n"\
              "<b>🖥️  Server:</b> ${hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📦 Scripts version:</b> ${scripts_version}\n"\
              "<b>📝 Status:</b> Service has been stopped"
      ;;
    "ban")
      echo -e "<b>${EMOJI_BAN} IP Address Banned</b>\n\n"\
              "<b>🖥️  Server:</b> ${hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📦 Scripts version:</b> ${scripts_version}\n"\
              "<b>🆔 IP:</b> ${ip}\n"\
              "<b>🌐 Reverse DNS:</b> ${reverse_dns}\n"\
              "<b>📍 Location:</b> ${geo_location}"
      ;;
    "unban")
      echo -e "<b>${EMOJI_UNBAN} IP Address Unbanned</b>\n\n"\
              "<b>🖥️  Server:</b> ${hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📦 Scripts version:</b> ${scripts_version}\n"\
              "<b>🆔 IP:</b> ${ip}\n"\
              "<b>🌐 Reverse DNS:</b> ${reverse_dns}\n"\
              "<b>📍 Location:</b> ${geo_location}"
      ;;
  esac
}

# Escape HTML special characters for Telegram's HTML parse_mode
function escape_html {
  echo "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Send notification with enhanced formatting
function send_msg {
  local action="$1"
  local ip="$2"
  
  local reverse_dns="Not checked"
  local geo_location="Not checked"
  
  # Get additional info for ban/unban actions
  if [[ "$action" == "ban" || "$action" == "unban" ]] && [ -n "$ip" ]; then
    reverse_dns=$(reverse_dns_lookup "$ip")
    geo_location=$(get_geo_location "$ip")
  fi
  
  # Escape user-controlled inputs to prevent HTML injection DoS
  local safe_reverse_dns=$(escape_html "$reverse_dns")
  local safe_geo_location=$(escape_html "$geo_location")

  # Format the message
  local message=$(format_message "$action" "$ip" "$safe_reverse_dns" "$safe_geo_location")
  
  # Send message via Telegram API
  local response=$(curl -s -X POST "$TELEGRAM_URL" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="$message" \
    -d parse_mode="HTML" \
    -w "%{http_code}")
  
  # Check if message was sent successfully
  if [[ "$response" != *200 ]]; then
    echo "Error: Failed to send Telegram message. HTTP response code: $response" >&2
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

# Check for script arguments
if [ $# -lt 1 ]; then
  show_usage
fi

# Validate IP address if provided
if [ -n "$2" ]; then
  if ! [[ "$2" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
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
      send_msg "ban" "$2" || status=$?
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

exit "$status"