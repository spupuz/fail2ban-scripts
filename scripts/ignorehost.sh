#!/usr/bin/env fail2ban-python
import sys
import re
import socket
import json
import urllib.request
import html
import concurrent.futures
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
# This file contains host-specific settings that must not be committed to GitHub.
#
# The file is shell-style KEY=VALUE, NOT Python: values such as Telegram bot
# tokens ("123456789:AAE...") are not valid Python expressions, so it must
# never be exec'd. Only the two whitelists are read here — the Telegram
# credentials are injected at deploy time by scripts/deploy.sh.
import ast as _ast
import os as _os
import re as _re
import subprocess as _subprocess

# Directory that holds the scripts (the parent of this file): the VERSION
# file of the deployed release lives there.
_SCRIPT_DIR = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))

def _parse_list_assignment(content, name):
    """Return the list literal assigned to `name` in a KEY=VALUE file.

    The literal is located with a bracket matching scan (so nested lists and
    brackets inside strings are handled) and parsed with ast.literal_eval,
    which never executes code. Returns None when the key is missing or when
    the value is not a valid list.
    """
    match = _re.search(r'^[ \t]*' + name + r'[ \t]*=[ \t]*', content, _re.M)
    if not match:
        return None
    # The value must start with '[': looking for the next bracket anywhere in
    # the file would pick up the list of another key.
    if not content.startswith('[', match.end()):
        return None
    start = match.end()
    depth = 0
    quote = None
    escaped = False
    for index in range(start, len(content)):
        char = content[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in '"\'':
            quote = char
        elif char == '[':
            depth += 1
        elif char == ']':
            depth -= 1
            if depth == 0:
                try:
                    value = _ast.literal_eval(content[start:index + 1])
                except (ValueError, SyntaxError):
                    return None
                return value if isinstance(value, list) else None
    return None

def _load_runtime_whitelists(script_path):
    """Load ALLOWED_DOMAINS / ALLOWED_HOSTS from the config.local that sits one
    level above the deployed script (i.e. <fail2ban data dir>/config.local).

    Returns a dict holding only the keys actually found. A missing or
    malformed file is not fatal: the built-in placeholders stay in place and a
    warning is printed, so the failure is visible in the fail2ban log instead
    of silently disabling the whitelist.
    """
    config_path = _os.path.join(_os.path.dirname(_os.path.abspath(script_path)), '..', 'config.local')
    whitelists = {}
    if not _os.path.isfile(config_path):
        print(f"Warning: config.local not found at {config_path}: "
              "using the built-in whitelist placeholders.", file=sys.stderr)
        return whitelists
    try:
        with open(config_path, 'r') as handle:
            content = handle.read()
    except OSError as error:
        print(f"Warning: failed to read {config_path}: {error}", file=sys.stderr)
        return whitelists
    for key in ('ALLOWED_DOMAINS', 'ALLOWED_HOSTS'):
        value = _parse_list_assignment(content, key)
        if value is None:
            print(f"Warning: {key} missing or malformed in {config_path}.", file=sys.stderr)
        else:
            whitelists[key] = value
    return whitelists

_runtime_whitelists = _load_runtime_whitelists(__file__)
ALLOWED_DOMAINS = _runtime_whitelists.get('ALLOWED_DOMAINS', ALLOWED_DOMAINS)
ALLOWED_HOSTS = _runtime_whitelists.get('ALLOWED_HOSTS', ALLOWED_HOSTS)

# Emojis for better visual presentation
EMOJI_IGNORE = "🛡️"
EMOJI_DOMAIN = "🌐"
EMOJI_HOST = "🖥️"
EMOJI_LOCATION = "📍"
EMOJI_INFO = "ℹ️"
EMOJI_TIME = "🕐"

# Telegram Configuration
# Secrets are injected at deploy time by scripts/deploy.sh from config.local
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
            # getaddrinfo supports both IPv4 and IPv6
            # It returns a list of tuples: (family, type, proto, canonname, sockaddr)
            # where sockaddr is a tuple (address, port) for IPv4 or (address, port, flow info, scope id) for IPv6
            addr_info = socket.getaddrinfo(domain, None)
            allowed_ips = [info[4][0] for info in addr_info]
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
                # Forward-Confirmed reverse DNS (FCrDNS) check supporting IPv4 and IPv6
                try:
                    addr_info = socket.getaddrinfo(host, None)
                    resolved_ips = [info[4][0] for info in addr_info]
                    if ip in resolved_ips:
                        return True
                except Exception:
                    pass
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

def get_scripts_version():
    """Version of the deployed scripts, shown in every message.

    It tells which release is running (and therefore whether the automatic
    update has already been applied). The file is looked up in the fail2ban
    data directory and, as a fallback, next to the scripts themselves.
    """
    candidates = []
    data_dir = _os.environ.get('FAIL2BAN_DATA_DIR', '')
    if data_dir:
        candidates.append(_os.path.join(data_dir, 'VERSION'))
    candidates.append(_os.path.join(_SCRIPT_DIR, 'VERSION'))
    for candidate in candidates:
        try:
            with open(candidate, encoding='utf-8') as handle:
                version = handle.read().strip()
            if version:
                return version
        except OSError:
            continue
    return 'unknown'

def format_message(ip, matching_domain, is_domain, reverse_dns, geo_location):
    """Format fancy Telegram message with emojis and better presentation"""
    timestamp = get_timestamp()
    hostname = socket.gethostname()
    scripts_version = get_scripts_version()
    
    ignore_reason = "Matching Domain" if is_domain else "Matching Host Provider"
    reason_emoji = EMOJI_DOMAIN if is_domain else EMOJI_HOST
    
    message = f"<b>{EMOJI_IGNORE} IP Address Ignored</b>\n\n"
    message += f"<b>{EMOJI_INFO} Server:</b> {hostname}\n"
    message += f"<b>{EMOJI_TIME} Time:</b> {timestamp}\n"
    message += f"<b>📦 Scripts version:</b> {scripts_version}\n"
    message += f"<b>🆔 IP:</b> {ip}\n"
    message += f"<b>{reason_emoji} Reason:</b> {ignore_reason}\n"
    message += f"<b>🔗 Matching Domain/Host:</b> {matching_domain}\n"
    message += f"<b>🌐 Reverse DNS:</b> {reverse_dns}\n"
    message += f"<b>{EMOJI_LOCATION} Location:</b> {geo_location}"
    
    return message

def send_telegram_notification(ip, matching_domain, is_domain):
    """Send fancy formatted Telegram notification"""
    url = f"https://api.telegram.org/bot{TELEGRAM_API_TOKEN}/sendMessage"

    # Bolt: Execute DNS lookup and GeoIP requests concurrently to avoid sequential blocking,
    # significantly reducing execution time.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        future_dns = executor.submit(reverse_dns_lookup, ip)
        future_geo = executor.submit(get_geo_location, ip)

        reverse_dns = future_dns.result()
        geo_location = future_geo.result()
    
    # Escape user-controlled inputs to prevent HTML injection DoS
    safe_reverse_dns = html.escape(reverse_dns)
    safe_geo_location = html.escape(geo_location)

    # Format the fancy message
    message = format_message(ip, matching_domain, is_domain, safe_reverse_dns, safe_geo_location)

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

def trigger_auto_update():
    """Trigger the automatic update of the deployed scripts.

    The updater (scripts/version_check.sh) is started detached: it must never
    delay the ignorecommand nor keep the output pipe open (fail2ban waits for
    the output of the command). It is a no-op when:
      - FAIL2BAN_DATA_DIR is not set (the script is not running inside the
        deployed fail2ban data directory),
      - the updater is missing,
      - the auto-update is disabled or was already performed today.
    """
    data_dir = _os.environ.get('FAIL2BAN_DATA_DIR', '')
    if not data_dir:
        return
    updater = _os.path.join(data_dir, 'scripts', 'version_check.sh')
    if not (_os.path.isfile(updater) and _os.access(updater, _os.X_OK)):
        return
    try:
        with open(_os.devnull, 'wb') as devnull:
            _subprocess.Popen([updater, '--dest', data_dir, '--quiet'],
                              stdin=devnull, stdout=devnull, stderr=devnull,
                              start_new_session=True, close_fds=True)
    except OSError as error:
        print(f"Warning: could not start the auto-updater: {error}", file=sys.stderr)

def trigger_log_rotate():
    """Trigger the automatic log/backup rotation in the data directory.

    The rotator (scripts/log_rotate.sh) is started detached: it must never
    delay the ignorecommand nor keep the output pipe open. It is a no-op when:
      - FAIL2BAN_DATA_DIR is not set (the script is not running inside the
        deployed fail2ban data directory),
      - the rotator is missing,
      - the rotation is disabled (LOG_ROTATE_ENABLED=false in config.local).
    """
    data_dir = _os.environ.get('FAIL2BAN_DATA_DIR', '')
    if not data_dir:
        return
    rotator = _os.path.join(data_dir, 'scripts', 'log_rotate.sh')
    if not (_os.path.isfile(rotator) and _os.access(rotator, _os.X_OK)):
        return
    try:
        with open(_os.devnull, 'wb') as devnull:
            _subprocess.Popen([rotator, '--dest', data_dir, '--quiet'],
                              stdin=devnull, stdout=devnull, stderr=devnull,
                              start_new_session=True, close_fds=True)
    except OSError as error:
        print(f"Warning: could not start the log rotator: {error}", file=sys.stderr)

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
    # Give the updater the chance to pull a newer release of the deployed
    # scripts (no-op when the auto-update is disabled or already checked today).
    trigger_auto_update()
    # Rotate old/large log and backup files in the data directory
    # (no-op when FAIL2BAN_DATA_DIR is unset or the rotator is missing).
    trigger_log_rotate()
    sys.exit(0 if matching_domain else 1)