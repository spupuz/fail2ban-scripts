# Fail2ban Scripts

Helper scripts for fail2ban on Proxmox/LXC hosts: Telegram ban/unban
notifications, ignore-host whitelisting, log/backup rotation, version
checking/auto-update, and secret redaction for safe deployment.

## Scripts

| Script | Purpose | Key behaviour |
|---|---|---|
| `scripts/fail2ban-telegram.sh` | Send formatted Telegram ban/unban/start/stop notifications | Validates IPv4/IPv6, reverse DNS + geo lookup concurrently, HTML-escapes user input |
| `scripts/ignorehost.sh` | Whitelist IPs belonging to allowed domains/hosts | Concurrent DNS lookups, sends Telegram ignore notifications |
| `scripts/log_rotate.sh` | Rotate/delete old or large log and backup files | Scans data dir root only (`-maxdepth 1`), dry-run mode, respects `LOG_ROTATE_ENABLED` |
| `scripts/version_check.sh` | Check GitHub releases and auto-update scripts | Throttled once per interval, lock-guarded, installs into the live data dir |
| `scripts/deploy.sh` | Render + deploy scripts/config into a fail2ban data directory | Injects secrets from `config.local`, refuses to deploy into a git tree |
| `scripts/redact.sh` | Replace real secrets with placeholder tokens for safe commits | Reads `config.local`, byte-level substitution |
| `scripts/run_tests.sh` | Run the local test suite | Executes `local_tests/*.sh` |

## Configuration

All machine-specific settings live in `config.local` (gitignored, mode `0600`):

- `TELEGRAM_BOT_TOKEN_NOTIFY` / `TELEGRAM_CHAT_ID_NOTIFY` — notify bot
- `TELEGRAM_BOT_TOKEN_IGNOREHOST` / `TELEGRAM_CHAT_ID_IGNOREHOST` — ignore bot
- `FAIL2BAN_UI_CALLBACK_SECRET` — Fail2Ban-UI callback secret
- `AUTO_UPDATE_ENABLED` / `AUTO_UPDATE_CHECK_INTERVAL_HOURS` — auto-update
- `LOG_ROTATE_ENABLED` / `LOG_ROTATE_MAX_AGE` / `LOG_ROTATE_MAX_SIZE` — rotation
- `ALLOWED_DOMAINS` / `ALLOWED_HOSTS` — ignore-host whitelists

Copy `config.local.example` to `config.local` and customize.

## Security

- Never commit real secrets; `config.local` is gitignored.
- Secrets are injected at deploy time by `scripts/deploy.sh`.
- Validate scripts with `bash -n script.sh` before committing.

<!-- changelog below -->
### v0.7.0
- Merge PR #23: Validate IP octet range in fail2ban-telegram (security/sanity)
- Merge PR #22: Add IPv4/IPv6 validation via ipaddress module (security)
- Merge PR #21: Warn about insecure secrets file permissions and cleanup temp files (security)
- Merge PR #19: Bolt: Optimize bash file reading (performance)
- Merge PR #18: IP octet validation (security)
- Merge PR #17: Max age validation (validation)
- Bump VERSION to 0.7.0
- Update changelog with new entry
