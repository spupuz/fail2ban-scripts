#!/usr/bin/env fail2ban-python
import sys
import re
import socket
import json
import urllib.request
from fail2ban.server.ipdns import DNSUtils, IPAddr
import datetime

# Allowed domains and hosts
# These are loaded from config.local at runtime.
# If config.local is missing, placeholder values are used.
ALLOWED_DOMAINS = [
    "placeholder.duckdns.org",
    "placeholder.mywire.org"
]

ALLOWED_HOSTS = [
    ".placeholder.isp.it",
    ".placeholder.fiber.it"
]

# Load custom configuration from config.local (gitignored)
# This file contains host-specific settings that must not be committed to GitHub
import os as _os
_config_path = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '..', 'config.local')
if _os.path.isfile(_config_path):
    try:
        _config_globals = {}
        with open(_config_path, 'r') as _f:
            _config_content = _f.read()
        # Execute the config file to load its variables
        exec(compile(_config_content, _config_path, 'exec'), _config_globals)
        if 'ALLOWED_DOMAINS' in _config_globals:
            ALLOWED_DOMAINS = _config_globals['ALLOWED_DOMAINS']
        if 'ALLOWED_HOSTS' in _config_globals:
            ALLOWED_HOSTS = _config_globals['ALLOWED_HOSTS']
    except Exception as _e:
        print(f"Warning: Failed to load config.local: {_e}", file=sys.stderr)

# Emojis for better visual presentation
EMOJI_IGNORE = "🛡️"
EMOJI_DOMAIN = "🌐"
EMOJI_HOST = "🖥️"
EMOJI_LOCATION = "📍"
EMOJI_INFO = "ℹ️"
EMOJI_TIME = "🕐"

# Telegram Configuration
# Secrets are injected at deploy time by scripts/deploy.sh from secrets.env
TELEGRAM_API_TOKEN = "__TELEGRAM_BOT_TOKEN_IGNOREHOST__"
TELEGRAM_CHAT_ID = "__TELEGRAM_CHAT_ID_IGNOREHOST__"

def process_args(argv):
    """Process command line arguments and validate IP address"""
    if len(argv) != 2:
        raise ValueError("Please provide a single IP as an argument. Got: %s\n"
                         % (argv[1:]))
    ip = argv[1]

    if not IPAddr(ip).isValid:
        raise ValueError("Argument must be a single valid IP. Got: %s\n"
                         % ip)
    print("IP received!")

    return ip

def is_allowed_ip(ip):
    """Check if IP belongs to allowed domains"""
    for domain in ALLOWED_DOMAINS:
        try:
            allowed_ips = socket.gethostbyname_ex(domain)[2]
            if ip in allowed_ips:
                return domain
        except:
            continue
    return False

def is_allowed_host(ip):
    """Check if IP belongs to allowed hosts"""
    host = DNSUtils.ipToName(ip)
    if not host:
        return False
    else:
        m = re.match(r'.\S+(-\d+)(?P<domain>\.\S+)', host)
        if m:
            domain = m.group('domain')
            if domain in ALLOWED_HOSTS:
                return True
    return False

def reverse_dns_lookup(ip):
    """Perform reverse DNS lookup"""
    try:
        return socket.gethostbyaddr(ip)[0]
    except:
        return "Not available"

def get_geo_location(ip):
    """Get geographical location of IP"""
    try:
        with urllib.request.urlopen(f"https://ipapi.co/{ip}/json/") as response:
            data = json.loads(response.read())
        return f"{data['city']}, {data['region']}, {data['country_name']}"
    except:
        return "Not available"

def get_timestamp():
    """Get current timestamp"""
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S %Z")

def format_message(ip, matching_domain, is_domain, reverse_dns, geo_location):
    """Format fancy Telegram message with emojis and better presentation"""
    timestamp = get_timestamp()
    hostname = socket.gethostname()
    
    ignore_reason = "Matching Domain" if is_domain else "Matching Host Provider"
    reason_emoji = EMOJI_DOMAIN if is_domain else EMOJI_HOST
    
    message = f"<b>{EMOJI_IGNORE} IP Address Ignored</b>\n\n"
    message += f"<b>{EMOJI_INFO} Server:</b> {hostname}\n"
    message += f"<b>{EMOJI_TIME} Time:</b> {timestamp}\n"
    message += f"<b>🆔 IP:</b> {ip}\n"
    message += f"<b>{reason_emoji} Reason:</b> {ignore_reason}\n"
    message += f"<b>🔗 Matching Domain/Host:</b> {matching_domain}\n"
    message += f"<b>🌐 Reverse DNS:</b> {reverse_dns}\n"
    message += f"<b>{EMOJI_LOCATION} Location:</b> {geo_location}"
    
    return message

def send_telegram_notification(ip, matching_domain, is_domain):
    """Send fancy formatted Telegram notification"""
    url = f"https://api.telegram.org/bot{TELEGRAM_API_TOKEN}/sendMessage"

    reverse_dns = reverse_dns_lookup(ip)
    geo_location = get_geo_location(ip)
    
    # Format the fancy message
    message = format_message(ip, matching_domain, is_domain, reverse_dns, geo_location)

    # Prepare data with HTML parsing
    data = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": message,
        "parse_mode": "HTML"
    }
    
    # Send the request
    try:
        req = urllib.request.Request(
            url, 
            data=json.dumps(data).encode(), 
            headers={"Content-Type": "application/json"}
        )
        response = urllib.request.urlopen(req)
        
        # Check if request was successful
        if response.getcode() != 200:
            print(f"Warning: Telegram API returned status code {response.getcode()}")
            
    except Exception as e:
        print(f"Error sending Telegram notification: {e}")

if __name__ == '__main__':  # pragma: no cover
    try:
        ip = process_args(sys.argv)
        matching_domain = is_allowed_ip(ip)
        if matching_domain:
            send_telegram_notification(ip, matching_domain, True)
        else:
            if is_allowed_host(ip):
                send_telegram_notification(ip, "Allowed Host", False)
                matching_domain = True
    except ValueError as e:
        sys.stderr.write(str(e))
        sys.exit(2)
    sys.exit(0 if matching_domain else 1)