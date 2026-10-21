# fail2ban-scripts

Repository of **custom fail2ban scripts and configuration**.

> No host paths are written in this repository: the **fail2ban data directory**
> must always be specified as an argument (`scripts/deploy.sh --dest DIR`, `scripts/redact.sh --src DIR`).

## Contents

| Path | Description |
|------|-------------|
| `scripts/fail2ban-telegram.sh` | Formatted Telegram notifications for ban/unban (bash, current version) |
| `scripts/ignorehost.sh` | Host lookup for ignorehost whitelist (Python, despite `.sh` extension) |

| `scripts/deploy.sh` | Copies files to the fail2ban data directory **injecting secrets** from `config.local` |
| `scripts/redact.sh` | Inverse operation: from the live directory to the repo, replacing secrets with placeholders |
| `scripts/version_check.sh` | Check for updates and auto-install latest releases from GitHub |
| `action.d/telegram.local` | Override of the `telegram` action |
| `action.d/iptables-nft.local` | Override of the `iptables-nft` action |
| `action.d/ui-custom-action.conf` | Custom action used by Fail2Ban-UI (callback on `127.0.0.1`) |
| `filter.d/npm-docker.conf` | Filter for npm errors in Docker containers |
| `jail.d/npm-docker.local` | Jail for the `npm-docker` filter |
| `jail.local` | Override `[DEFAULT]` managed by the Fail2Ban-UI |
| `paths-overrides.local` | Override of banaction compared to image defaults |
| `config.local.example` | Template for configuration — copy to `config.local` and fill with real values |

## Setup

### 1. Create local configuration

```bash
cp config.local.example config.local
# Edit config.local with your real values:
#   - Telegram bot tokens and chat IDs
#   - Fail2Ban-UI callback secret
#   - ALLOWED_DOMAINS / ALLOWED_HOSTS for ignorehost
#   - AUTO_UPDATE_ENABLED flag
chmod 600 config.local
```

### 2. Deploy to fail2ban

```bash
# Preview (dry run — does not write anything)
scripts/deploy.sh --dest /path/to/fail2ban/data

# Apply (writes files and preserves permissions)
scripts/deploy.sh --dest /path/to/fail2ban/data --apply
fail2ban-client reload
```

`--secrets FILE` allows using an alternative config file (default: `config.local` next to the repo root).

### 3. Test locally

```bash
bash scripts/run_tests.sh
```

## Configuration

All machine-specific settings live in `config.local` (gitignored):

| Setting | Description |
|---------|-------------|
| `TELEGRAM_BOT_TOKEN_NOTIFY` | Telegram bot token for ban/unban notifications |
| `TELEGRAM_CHAT_ID_NOTIFY` | Telegram chat ID for notifications |
| `TELEGRAM_BOT_TOKEN_IGNOREHOST` | Telegram bot token for ignorehost |
| `TELEGRAM_CHAT_ID_IGNOREHOST` | Telegram chat ID for ignorehost |
| `FAIL2BAN_UI_CALLBACK_SECRET` | Fail2Ban-UI callback secret |
| `AUTO_UPDATE_ENABLED` | Enable/disable auto-update from GitHub (`true`/`false`) |
| `ALLOWED_DOMAINS` | Domains whitelisted by ignorehost |
| `ALLOWED_HOSTS` | Host providers whitelisted by ignorehost |

Source files contain only `__PLACEHOLDER__` tokens. Real values are injected at deploy time from `config.local`.

`local_tests/test_secrets.sh` fails the build if a real credential ends up in a git-tracked file.

## Auto-update

`scripts/version_check.sh` checks for newer GitHub releases:

- Runs at most once per day
- Downloads and installs the latest release automatically
- Sends a Telegram notification on update
- Disabled when `AUTO_UPDATE_ENABLED=false` in `config.local`
- Can also be disabled by creating a `.disable_auto_update` file

```bash
# Manual check (report only)
scripts/version_check.sh --check

# Force check now
scripts/version_check.sh --force
```

## Reverse sync (live → repo)

Use `redact.sh` to rewrite live files with placeholders before committing:

```bash
scripts/redact.sh --src /path/to/fail2ban/data --out /path/to/staging
diff -r . /path/to/staging   # review, then commit
```

The deploy → redact round trip is verified byte-for-byte by `local_tests/test_deploy.sh`.

## CI and release

- **`.github/workflows/ci.yml`** — runs `scripts/run_tests.sh` on every push and PR to `main`.
- **`.github/workflows/release.yml`** — when a push changes `VERSION`, creates tag `vX.Y.Z` and publishes the GitHub release. Never create the tag manually.

## Versioning

`VERSION` contains a bare semver (`0.1.0`, no `v`):

- **PATCH** — fix, tweak, docs
- **MINOR** — backward-compatible new features
- **MAJOR** — breaking changes (removed jails, changed behavior)

## Changelog

### v0.1.1

- Remove obsolete historical scripts `scripts/fail2ban-telegram_old.sh` and `scripts/ignorehost_old.sh` and all references.

### v0.1.2

- Merge PR #1: Bolt concurrent network lookups in ignorehost.sh
- Merge PR #2: Sentinel HTML injection fixes and FCrDNS checks
- Bumped VERSION to 0.1.2

### v0.1.0

- Initial import of custom fail2ban scripts and configuration.
- Secrets removed from sources (placeholders + `config.local` gitignored), with `deploy.sh` / `redact.sh` pipeline.
- Local test suite (`scripts/run_tests.sh`), CI and release workflows.
- `version_check.sh` auto-update from GitHub releases.
- `config.local` consolidates all host-specific settings (secrets, domains, flags).