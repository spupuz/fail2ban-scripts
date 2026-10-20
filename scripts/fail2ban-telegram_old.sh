#!/bin/bash

# Sends text messages using Telegram
# to alert webmaster of banning.

# Require one argument, one of the following
# start
# stop
# ban
# unban
# Optional second argument: Ip for ban/unband


# Display usage information
function show_usage {
  echo "Usage: $0 action <ip>"
  echo "Where action start, stop, ban, unban"
  echo "and IP is optional passed to ban, unban"
  exit
}

# Perform reverse DNS lookup
function reverse_dns_lookup {
  python3 -c "import socket; print(socket.gethostbyaddr('$1')[0])" 2>/dev/null || echo "Not available"
}

# Get geographical location
function get_geo_location {
  python3 -c "import urllib.request, json; data = json.loads(urllib.request.urlopen('https://ipapi.co/$1/json/').read()); print(f'{data[\"city\"]}, {data[\"region\"]}, {data[\"country_name\"]}')" 2>/dev/null || echo "Not available"
}
# Send notification
function send_msg {
  # Secrets are injected at deploy time by scripts/deploy.sh from secrets.env
  apiToken=__TELEGRAM_BOT_TOKEN_IGNOREHOST__
  chatId=__TELEGRAM_CHAT_ID_NOTIFY__
  url="https://api.telegram.org/bot$apiToken/sendMessage"

  if [ -n "$2" ]; then
    reverse_dns=$(reverse_dns_lookup $2)
    geo_location=$(get_geo_location $2)
    message="$1%0AReverse DNS: $reverse_dns%0ALocation: $geo_location"
  else
    message="$1"
  fi

  curl -s -X POST $url -d chat_id=$chatId -d text="$message"
  exit
}

# Check for script arguments
if [ $# -lt 1 ]
then
  show_usage
fi


# Take action depending on argument
if [ "$1" = 'start' ]
then
  msg='Fail2ban+just+started.'
  send_msg $msg
elif [ "$1" = 'stop' ]
then
  msg='Fail2ban+just+stopped.'
  send_msg $msg
elif [ "$1" = 'ban' ]
then
  msg=$([ "$2" != '' ] && echo "Fail2ban+just+banned+$2" || echo 'Fail2ban+just+banned+an+ip.' )
  send_msg "$msg" "$2"
elif [ "$1" = 'unban' ]
then
  msg=$([ "$2" != '' ] && echo "Fail2ban+just+unbanned+$2" || echo "Fail2ban+just+unbanned+an+ip." )
  send_msg "$msg" "$2"  show_usage
fi
