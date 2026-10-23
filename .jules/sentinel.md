## 2024-05-18 - Missing Timeouts on External API Calls

**Vulnerability:** External network calls (Telegram API, ipapi.co, and DNS lookups) in fail2ban scripts lacked timeouts.
**Learning:** These scripts are executed synchronously by fail2ban. If external services hang, they block the action queue, causing a Denial of Service (DoS) of the security mechanism.
**Prevention:** Always add explicit timeouts to network calls (e.g. `curl --max-time`, `urllib.request.urlopen` with `timeout`, `socket.setdefaulttimeout`) in fail2ban action scripts.
