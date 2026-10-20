# fail2ban-scripts

Repository of **custom fail2ban scripts and configuration**.

> No host paths are written in this repository: the **fail2ban data directory**
> must always be specified as an argument (`scripts/deploy.sh --dest DIR`, `scripts/redact.sh --src DIR`).

## Contents

| Path | Description |
|------|-------------|
| `scripts/fail2ban-telegram.sh` | Formatted Telegram notifications for ban/unban (bash, current version) |
| `scripts/ignorehost.sh` | Host lookup for ignorehost whitelist (Python, despite `.sh` extension) |
| `scripts/fail2ban-telegram_old.sh` | Previous version of Telegram script (historical) |
| `scripts/ignorehost_old.sh` | Previous version of ignorehost (historical) |
| `scripts/deploy.sh` | Copies files to the fail2ban data directory **injecting secrets** from `secrets.env` |
| `scripts/redact.sh` | Inverse operation: from the live directory to the repo, replacing secrets with placeholders |
| `scripts/version_check.sh` | Check for updates and auto-install latest releases from GitHub |
| `action.d/telegram.local` | Override of the `telegram` action |
| `action.d/iptables-nft.local` | Override of the `iptables-nft` action |
| `action.d/ui-custom-action.conf` | Custom action used by Fail2Ban-UI (callback on `127.0.0.1`) |
| `filter.d/npm-docker.conf` | Filter for npm errors in Docker containers |
| `jail.d/npm-docker.local` | Jail for the `npm-docker` filter |
| `jail.local` | Override `[DEFAULT]` managed by the Fail2Ban-UI (bantime, banaction, action with callback UI) |
| `paths-overrides.local` | Override of banaction compared to image defaults |
| `secrets.env.example` | Template for secrets — copy to `secrets.env` and fill with real values |

## Setup

### Local Setup

1. **Create secrets file:**
   ```bash
   cp secrets.env.example secrets.env
   # Edit secrets.env with your real secrets
   chmod 600 secrets.env
   ```

2. **Create local config (optional):**
   ```bash
   cp config.local.example config.local
   # Edit config.local with your domains, hosts, and settings
   chmod 600 config.local
   ```

3. **Deploy to fail2ban data directory:**
   ```bash
   scripts/deploy.sh --dest /path/to/fail2ban/data --apply
   ```

### Production Usage

The repository is designed to be deployed to a fail2ban data directory. All scripts and configuration are deployed with real secrets injected from `secrets.env`.

### Testing

Local test scripts are now in the `local_tests/` directory. To run tests:

```bash
bash local_tests/test_syntax.sh
bash local_tests/test_configs.sh
bash local_tests/test_secrets.sh
# etc.
```

### Updates and Auto-Update

The repository includes an automatic update system:

1. **Manual check:** Run `scripts/version_check.sh --check` to see if updates are available
2. **Automatic updates:** Enable with `AUTO_UPDATE_ENABLED=true` in `secrets.env`
3. **Automatic update process:** When a newer version is available, `version_check.sh` downloads and installs the release, updating all deployed scripts and configuration

Update notifications are sent via Telegram if configured.

## Security

- **Secrets:** All real secrets are stored in `secrets.env` (gitignored)
- **Configuration:** Host-specific settings are in `config.local` (gitignored)
- **Secrets file:** The `secrets.env` file should have permissions 600 and should never be committed to Git
- **Test scripts:** Local test scripts are in `local_tests/` and are not part of the repository