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

### v0.10.0
- Merge PR #39: ⚡ Bolt: pure POSIX sh UUID generation in UI custom action

### v0.9.2
- Merge PR #38: Bolt: Replace 'cmd && cmd || true' with explicit if (SC2015)

### v0.8.1
- Add comprehensive installation instructions with custom path support and auto-update documentation
- Add `install.sh` with `--dest` parameter for custom installation directory
- Document auto-update workflow with `version_check.sh --dest`

### v0.8.0
- Merge PR #24: Bolt: Replace sub-process pipeline with sed in expected_secret_keys (performance)
- Merge PR #25: Sentinel: Validate IP before geo lookup to prevent SSRF/injection (security)
- Merge PR #26: Sentinel: Guard IPv4 octet validation against IPv6 and non-numeric input (security)
- Merge PR #27: Fix: skip octet validation for IPv6 addresses (security)
- Merge PR #28: Sentinel: Harden IP octet validation against leading zeros and octal interpretation (security)
- Merge PR #29: Forge: Add strict error handling with set -euo pipefail to log_rotate.sh (robustness)
- Merge PR #30: Sentinel: Fix Telegram HTTP status check to use exact code, not substring match (security)

### Installation

#### Quick one-liner

```bash
# Install into /data/fail2ban-scripts (or set FAIL2BAN_DATA_DIR)
curl -sSL https://raw.githubusercontent.com/spupuz/fail2ban-scripts/main/install.sh | bash

# Install into a custom directory
curl -sSL https://raw.githubusercontent.com/spupuz/fail2ban-scripts/main/install.sh | bash -- -d /path/to/fail2ban/data
```

This will:
- Download the latest release
- Copy scripts to `$INSTALL_DIR/scripts/`
- Set executable permissions
- Create `config.local` from the example (if missing)
- **Auto-updates will run against this same directory** via `scripts/version_check.sh --dest $INSTALL_DIR`

#### Manual installation

```bash
# 1. Clone or download the repository
git clone https://github.com/spupuz/fail2ban-scripts.git
cd fail2ban-scripts

# 2. Make scripts executable
chmod +x scripts/*.sh

# 3. Choose your installation directory (this is where auto-updates will look)
#    - Default: /data/fail2ban-scripts
#    - Custom: set FAIL2BAN_DATA_DIR=/path/to/dir or use ./scripts/deploy.sh --dest /path/to/dir
cp config.local.example config.local
chmod 600 config.local
# Edit config.local with your secrets:
#   - TELEGRAM_BOT_TOKEN_NOTIFY, TELEGRAM_CHAT_ID_NOTIFY
#   - TELEGRAM_BOT_TOKEN_IGNOREHOST, TELEGRAM_CHAT_ID_IGNOREHOST
#   - FAIL2BAN_UI_CALLBACK_SECRET
#   - AUTO_UPDATE_ENABLED, LOG_ROTATE_ENABLED, etc.

# 4. Deploy to your chosen fail2ban data directory
./scripts/deploy.sh --apply --dest /path/to/fail2ban/data --secrets ./config.local

# 5. Verify auto-update works
scripts/version_check.sh --dest /path/to/fail2ban/data

# 6. Reload fail2ban
fail2ban-client reload
```

#### Using the install script directly with custom path

```bash
# Using the bundled install script with custom destination
curl -sSL https://raw.githubusercontent.com/spupuz/fail2ban-scripts/main/install.sh | bash -- -d /path/to/your/fail2ban/data

# Or with environment variable
FAIL2BAN_DATA_DIR=/path/to/your/fail2ban/data bash -c "$(curl -sSL https://raw.githubusercontent.com/spupuz/fail2ban-scripts/main/install.sh)"
```

### How auto-updates work

The automatic update process (`scripts/version_check.sh`) operates as follows:

1. **Runs daily** (or when `--force` is used) checking GitHub for newer releases
2. **Downloads** the new release archive and installs scripts into the directory specified with `--dest`
3. **If `--dest` is set** (e.g., the directory where you installed the scripts):
   - Scripts are rendered with secrets and replaced in-place
   - VERSION file is updated
   - Telegram notifications show the new running version
4. **If `--dest` is NOT set**:
   - Only the local VERSION is updated (no file deployment)
   - Use `scripts/deploy.sh --apply --dest <dir>` manually to deploy installed updates

**Recommendation**: Choose your installation directory carefully and always use the same `--dest` path for both installation and auto-updates. This ensures `version_check.sh` and `deploy.sh` operate on the same files.

### Example workflow

```bash
# Initial installation into custom directory
curl -sSL https://raw.githubusercontent.com/spupuz/fail2ban-scripts/main/install.sh | bash -- -d /etc/fail2ban/data

# Later, when a new version is available:
scripts/version_check.sh --dest /etc/fail2ban/data   # installs + deploys new version
# OR
./scripts/deploy.sh --apply --dest /etc/fail2ban/data --secrets /etc/fail2ban/data/config.local  # manual deploy

# To check without deploying
scripts/version_check.sh --check --dest /etc/fail2ban/data
```

### Post-installation

- Check `scripts/fail2ban-telegram.sh start` works to verify Telegram connectivity
- Run `bash scripts/run_tests.sh` to verify all local tests pass
- Configure your fail2ban jail to use the custom actions in `action.d/telegram.local`

### v0.9.1
- Merge PR #37: Sentinel: Fix local privilege escalation via predictable temporary file paths in install.sh (security)
- Merge PR #36: Sentinel: Replace fragile grep -oP release parsing in install.sh with python3 JSON (robustness)
- Merge PR #35: Bolt: Consolidate external binary pipeline into single awk command in version_check.sh (performance)

### v0.9.0
- Merge PR #34: Add script reference table and config docs to README
- Merge PR #33: Parse GitHub releases JSON with python3 for robust parsing
- Merge PR #32: Escape user-controlled domain in Telegram HTML message
- Merge PR #31: Escape user-controlled IP in Telegram HTML message

### v0.7.0
- Merge PR #23: Validate IP octet range in fail2ban-telegram (security/sanity)
- Merge PR #22: Add IPv4/IPv6 validation via ipaddress module (security)
- Merge PR #21: Warn about insecure secrets file permissions and cleanup temp files (security)
- Merge PR #19: Bolt: Optimize bash file reading (performance)
- Merge PR #18: IP octet validation (security)
- Merge PR #17: Max age validation (validation)
- Bump VERSION to 0.7.0
- Update changelog with new entry