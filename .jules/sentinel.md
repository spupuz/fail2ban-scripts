## 2024-05-18 - Missing Timeouts on External API Calls

**Vulnerability:** External network calls (Telegram API, ipapi.co, and DNS lookups) in fail2ban scripts lacked timeouts.
**Learning:** These scripts are executed synchronously by fail2ban. If external services hang, they block the action queue, causing a Denial of Service (DoS) of the security mechanism.
**Prevention:** Always add explicit timeouts to network calls (e.g. `curl --max-time`, `urllib.request.urlopen` with `timeout`, `socket.setdefaulttimeout`) in fail2ban action scripts.

## 2026-10-24 - Command Injection via Bash Arithmetic Evaluation

**Vulnerability:** Bash arithmetic contexts (e.g. `$(( var ))`) evaluate unquoted variables as arithmetic expressions, which can execute embedded command substitutions (e.g., `a[$(malicious_command)]`). In `scripts/log_rotate.sh`, user-controlled values `MAX_AGE` and `MAX_SIZE_MB` were evaluated directly, allowing command injection.
**Learning:** Bash's arithmetic expansion is dangerous with untrusted input because it performs recursive evaluation of strings as code, even without explicit `eval`.
**Prevention:** Always validate that shell variables contain only numeric digits (e.g. using `[[ "$var" =~ ^[0-9]+$ ]]`) *before* using them in arithmetic contexts `$(( ... ))` or `(( ... ))`.
