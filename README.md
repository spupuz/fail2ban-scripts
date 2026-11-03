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

### v0.7.0
- Merge PR #23: Validate IP octet range in fail2ban-telegram (security/sanity)
- Merge PR #22: Add IPv4/IPv6 validation via ipaddress module (security)
- Merge PR #21: Warn about insecure secrets file permissions and cleanup temp files (security)
- Merge PR #19: Bolt: Optimize bash file reading (performance)
- Merge PR #18: IP octet validation (security)
- Merge PR #17: Max age validation (validation)
- Bump VERSION to 0.7.0
- Update changelog with new entry