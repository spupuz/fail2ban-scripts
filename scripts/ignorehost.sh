#!/usr/bin/env fail2ban-python
import sys
import re
import socket
import json
import urllib.request
from fail2ban.server.ipdns import DNSUtils, IPAddr
import datetime

# Allowed domains and hosts
ALLOWED_DOMAINS = [
    "spupuz.duckdns.org",
    "spupuz.mywire.org",
    "behouse.duckdns.org",
    "behouse.mywire.org"
]

ALLOWED_HOSTS = [
    ".retail.pianetafibra.it",
    ".static.eolo.it",
    ".pool-bba.aruba.it",
]

# Emojis for better visual presentation
EMOJI_IGNORE = "🛡️"
EMOJI_DOMAIN = "🌐"
EMOJI_HOST = "🖥️"
EMOJI_LOCATION = "📍"
EMOJI_INFO = "ℹ️"
EMOJI_TIME = "🕐"

# Telegram Configuration
TELEGRAM_API_TOKEN = "736052043:AAEA0A7hUWUWtmeaUdWflrDY6goZMIx1vOQ"
TELEGRAM_CHAT_ID = "-4521079627"

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