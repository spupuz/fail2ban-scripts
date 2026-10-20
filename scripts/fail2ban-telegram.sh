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

# Format message with better presentation
function format_message {
  local action="$1"
  local ip="$2"
  local reverse_dns="$3"
  local geo_location="$4"
  
  local timestamp=$(get_timestamp)
  local hostname=$(hostname)
  
  case "$action" in
    "start")
      echo -e "<b>${EMOJI_START} Fail2ban Service Started</b>\n\n"\
              "<b>🖥️  Server:</b> ${hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📝 Status:</b> Service has been started successfully"
      ;;
    "stop")
      echo -e "<b>${EMOJI_STOP} Fail2ban Service Stopped</b>\n\n"\
              "<b>🖥️  Server:</b> ${hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>📝 Status:</b> Service has been stopped"
      ;;
    "ban")
      echo -e "<b>${EMOJI_BAN} IP Address Banned</b>\n\n"\
              "<b>🖥️  Server:</b> ${hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>🆔 IP:</b> ${ip}\n"\
              "<b>🌐 Reverse DNS:</b> ${reverse_dns}\n"\
              "<b>📍 Location:</b> ${geo_location}"
      ;;
    "unban")
      echo -e "<b>${EMOJI_UNBAN} IP Address Unbanned</b>\n\n"\
              "<b>🖥️  Server:</b> ${hostname}\n"\
              "<b>🕐 Time:</b> ${timestamp}\n"\
              "<b>🆔 IP:</b> ${ip}\n"\
              "<b>🌐 Reverse DNS:</b> ${reverse_dns}\n"\
              "<b>📍 Location:</b> ${geo_location}"
      ;;
  esac
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
  
  # Format the message
  local message=$(format_message "$action" "$ip" "$reverse_dns" "$geo_location")
  
  # Send message via Telegram API with HTML formatting
  local response=$(curl -s -X POST "$TELEGRAM_URL" \
    -d chat_id="$CHAT_ID" \
    -d text="$message" \
    -d parse_mode="HTML" \
    -w "%{http_code}")
  
  # Check if message was sent successfully
  if [[ "$response" != *200 ]]; then
    echo "Error: Failed to send Telegram message. HTTP response code: $response" >&2
    exit 1
  fi
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
case "$1" in
  "start")
    send_msg "start"
    ;;
  "stop")
    send_msg "stop"
    ;;
  "ban")
    if [ -n "$2" ]; then
      send_msg "ban" "$2"
    else
      echo "Error: IP address required for ban action" >&2
      show_usage
    fi
    ;;
  "unban")
    if [ -n "$2" ]; then
      send_msg "unban" "$2"
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

exit 0