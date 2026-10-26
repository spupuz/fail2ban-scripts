## 2024-05-18 - Missing Timeouts on External API Calls

**Vulnerability:** External network calls (Telegram API, ipapi.co, and DNS lookups) in fail2ban scripts lacked timeouts.
**Learning:** These scripts are executed synchronously by fail2ban. If external services hang, they block the action queue, causing a Denial of Service (DoS) of the security mechanism.
**Prevention:** Always add explicit timeouts to network calls (e.g. `curl --max-time`, `urllib.request.urlopen` with `timeout`, `socket.setdefaulttimeout`) in fail2ban action scripts.

## 2026-10-24 - Command Injection via Bash Arithmetic Evaluation

**Vulnerability:** Bash arithmetic contexts (e.g. `$(( var ))`) evaluate unquoted variables as arithmetic expressions, which can execute embedded command substitutions (e.g., `a[$(malicious_command)]`). In `scripts/log_rotate.sh`, user-controlled values `MAX_AGE` and `MAX_SIZE_MB` were evaluated directly, allowing command injection.
**Learning:** Bash's arithmetic expansion is dangerous with untrusted input because it performs recursive evaluation of strings as code, even without explicit `eval`.
**Prevention:** Always validate that shell variables contain only numeric digits (e.g. using `[[ "$var" =~ ^[0-9]+$ ]]`) *before* using them in arithmetic contexts `$(( ... ))` or `(( ... ))`.

## 2026-10-26 - Bash string interpolation code/JSON injection
**Vulnerability:** Bash variables were interpolated directly into executable strings (`python3 -c "print('$1')"`) or structured formats (JSON templates using `printf`), exposing the application to code execution or JSON injection vulnerabilities if the variables contained quotes or unescaped control characters like newlines.
**Learning:** String interpolation of variables in contexts where they will be evaluated as code or syntax structures bypasses validation and can lead to injection attacks. In the JSON case, newlines broke the JSON format, causing silent failures.
**Prevention:** Never use string interpolation (e.g., `'$var'`) to pass arguments to scripts or data structures. Instead, use parameter arrays (like `sys.argv[1]` in Python and passing the bash argument as a script parameter `"$1"`) or libraries specifically designed to encode the data format securely (like `json.dumps()` in Python instead of `printf` for JSON).
