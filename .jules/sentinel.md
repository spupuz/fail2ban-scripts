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

## 2026-10-27 - Command Injection via Fail2ban Tag Interpolation

**Vulnerability:** In `action.d/ui-custom-action.conf`, the attacker-controlled `<fq-hostname>` tag (resolved via reverse DNS) was interpolated directly into the `jq` arguments of the `actionban` and `actionunban` shell commands. This allowed command injection if an attacker configured a malicious PTR record containing shell metacharacters.
**Learning:** Fail2ban action tags (like `<fq-hostname>`) are directly substituted as strings into the action command *before* shell execution. Any unescaped single quotes within the substituted string can break out of shell quoting, leading to critical RCE vulnerabilities.
**Prevention:** Avoid interpolating attacker-controlled tags directly into shell commands. Remove them from the action definition (e.g., replace with safe static values like `'Not checked'`) or resolve them securely within an invoked script.

## 2024-10-29 - Prevent JSON Injection in Fallback Payload Generation
**Vulnerability:** JSON injection vulnerability in `version_check.sh` due to string interpolation in a `printf` fallback for Telegram message formatting.
**Learning:** Even fallback code paths must use safe serialization methods. Simple string replacement (e.g., escaping quotes) fails to account for all JSON syntax requirements (like control characters), allowing malicious payloads to break the JSON structure.
**Prevention:** Never use string interpolation (`printf`, `echo`) to construct structured formats (JSON, XML). Always use dedicated serialization tools like `json.dumps` (Python) or `jq --arg` (Bash) which handle proper encoding natively.
