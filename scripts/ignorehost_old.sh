#!/usr/bin/env fail2ban-python
import sys
import re
import socket
import json
import urllib.request
from fail2ban.server.ipdns import DNSUtils, IPAddr

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

def process_args(argv):
    if len(argv) != 2:
       raise ValueError("Please provide a single IP as an argument. Got: %s\n"
                        % (argv[1:]))
    ip = argv[1]

    if not IPAddr(ip).isValid:
       raise ValueError("Argument must be a single valid IP. Got: %s\n"
                        % ip)
    print("Ip received!")

    return ip

def is_allowed_ip(ip):
    for domain in ALLOWED_DOMAINS:
        try:
            allowed_ips = socket.gethostbyname_ex(domain)[2]
            if ip in allowed_ips:
                return domain
        except:
            continue
    return False

def is_allowed_host(ip):
    host = DNSUtils.ipToName(ip)
    if not host:
        return False
    else:
        m = re.match('.\S+(-\d+)(?P<domain>\.\S+)', host)
        if m:
            domain = m.group('domain')
            if domain in ALLOWED_HOSTS:
                return True
    return False

def reverse_dns_lookup(ip):
    try:
        return socket.gethostbyaddr(ip)[0]
    except:
        return "Not available"

def get_geo_location(ip):
    try:
        with urllib.request.urlopen(f"https://ipapi.co/{ip}/json/") as response:
            data = json.loads(response.read())
        return f"{data['city']}, {data['region']}, {data['country_name']}"
    except:
        return "Not available"

def send_telegram_notification(ip, matching_domain, is_domain):
    # Secrets are injected at deploy time by scripts/deploy.sh from secrets.env
    api_token = "__TELEGRAM_BOT_TOKEN_IGNOREHOST__"
    chat_id = "__TELEGRAM_CHAT_ID_IGNOREHOST__"
    url = f"https://api.telegram.org/bot{api_token}/sendMessage"

    reverse_dns = reverse_dns_lookup(ip)
    geo_location = get_geo_location(ip)
    ignore_reason = "Matching Domain" if is_domain else "Matching Host Provider"
    message = f"Ignored IP: {ip}\nIgnore Reason: {ignore_reason}\nMatching Domain/Host: {matching_domain}\nReverse DNS: {reverse_dns}\nLocation: {geo_location}"

    data = {
        "chat_id": chat_id,
        "text": message
    }
    req = urllib.request.Request(url, data=json.dumps(data).encode(), headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req)

if __name__ == '__main__': # pragma: no cover
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
    sys.exit(0 if matching_domain else 1)