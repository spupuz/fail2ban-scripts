# fail2ban-scripts

Repository of **custom fail2ban scripts and configuration**.

> No host paths are written in this repository: the **fail2ban data directory**
> must always be specified as an argument (`scripts/deploy.sh --dest DIR`, `scripts/redact.sh --src DIR`).

## Contents

| Path | Description |
|------|-------------|
| `scripts/fail2ban-telegram.sh` | Formatted Telegram notifications for ban/unban (bash, current version). Shows the version of the running scripts |
| `scripts/ignorehost.sh` | Host lookup for ignorehost whitelist (Python, despite `.sh` extension). Shows the version of the running scripts |

| `scripts/deploy.sh` | Copies files to the fail2ban data directory **injecting secrets** from `config.local` (`--scripts-only` to skip the configuration) |
| `scripts/redact.sh` | Inverse operation: from the live directory to the repo, replacing secrets with placeholders |
| `scripts/version_check.sh` | Check for updates and auto-install latest releases from GitHub (scripts only, self-contained) |
| `scripts/log_rotate.sh` | Rotate logs and backups: removes files older than `LOG_ROTATE_MAX_AGE` days or larger than `LOG_ROTATE_MAX_SIZE` MB. Triggered automatically by the notification scripts |
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

`--scripts-only` deploys only the scripts and leaves the configuration of
the running fail2ban untouched (this is what the
[automatic update](#auto-update) does).

Inside the container the deployed scripts also need to know where the data
directory is, to be able to update themselves: set the environment variable
`FAIL2BAN_DATA_DIR=/data` (see [Auto-update](#auto-update)).

`scripts/ignorehost.sh` additionally reads the whitelist (`ALLOWED_DOMAINS` /
`ALLOWED_HOSTS`) **at runtime** from `config.local` placed one directory above
the deployed scripts — i.e. `<dest>/config.local` for `<dest>/scripts/ignorehost.sh`.
Copy the same `config.local` into the fail2ban data directory, otherwise the
script keeps its built-in placeholder whitelist and every whitelisted address
gets banned (a warning is printed in the fail2ban log).

> The configuration file is **parsed, never executed**: it is a shell-style
> `KEY=VALUE` file and real values (a Telegram bot token contains a colon)
> are not valid Python expressions.

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
| `AUTO_UPDATE_CHECK_INTERVAL_HOURS` | Minimum interval between update checks in hours (default: 24) |
| `LOG_ROTATE_ENABLED` | Enable/disable automatic log/backup rotation (`true`/`false`) |
| `LOG_ROTATE_MAX_AGE` | Maximum age in days for log/backup files (default: 7) |
| `LOG_ROTATE_MAX_SIZE` | Maximum size in MB for log/backup files (default: 500) |
| `ALLOWED_DOMAINS` | Domains whitelisted by ignorehost (read at runtime from `<dest>/config.local`) |
| `ALLOWED_HOSTS` | Host providers whitelisted by ignorehost (read at runtime from `<dest>/config.local`) |

Source files contain only `__PLACEHOLDER__` tokens. Real values are injected at deploy time from `config.local`.

### Templates and rendered files

Not every deployed file needs the secrets, and a file that reads `config.local`
at runtime must never receive the secrets at install time:

| File | Deployed as | Why |
|------|-------------|-----|
| `scripts/fail2ban-telegram.sh` | **rendered** | the bot token, the chat ID and the UI secret are injected |
| `scripts/ignorehost.sh` | **rendered** | same |
| `action.d/*`, `filter.d/*`, `jail.d/*`, `jail.local`, `paths-overrides.local` | **rendered** | they reference the bot token and the UI secret |
| `scripts/deploy.sh`, `scripts/redact.sh`, `scripts/version_check.sh`, `scripts/log_rotate.sh` | **template** | installed verbatim: they read `config.local` when they run, so they never hold a secret |
| `VERSION` | **template** | installed verbatim |

The helpers stay secret-free, therefore the automatic update can replace them
without touching `config.local`, and the placeholder check of the updater
cannot be fooled by a token that looks like a secret.

`local_tests/test_secrets.sh` fails the build if a real credential ends up in a git-tracked file.

## Auto-update

The deployed scripts update themselves: **the ban/unban/ignore Telegram
scripts trigger the update check**, so there is nothing to schedule.

```
fail2ban ──► scripts/fail2ban-telegram.sh   (ban/unban notification)
          └► scripts/ignorehost.sh          (ignore notification)
                └► scripts/version_check.sh --dest <data dir> --quiet
                      ├─ check the GitHub release (at most once per interval)
                      ├─ install the new scripts (atomic replace)
                      ├─ render + install the scripts into <data dir>
                      │  (self-contained: the secrets are injected by the
                      │   updater itself, deploy.sh is not called)
                      └─ Telegram notification
```

- Runs **at most once per interval** (default 24h, configurable via
  `AUTO_UPDATE_CHECK_INTERVAL_HOURS`; timestamp file `.last_update_check`)
- Disabled when `AUTO_UPDATE_ENABLED=false` in `config.local`
- Can also be disabled by creating a `.disable_auto_update` file
- Sends a Telegram notification when an update is installed
- Never breaks a ban/unban/ignore: the check runs detached (it never delays
  the notification and never keeps the output pipe open) and every error is
  written to `.version_check.log` / `.update_log` in the data directory

The updater is **self-contained**: it injects the secrets itself instead of
calling `scripts/deploy.sh`. The deployed `deploy.sh` comes from the release
that is currently installed, which may be older than the updater and would not
understand the new flags — rendering the secrets in the updater removes that
dependency, so an update always works.

### Telegram messages

Every message sent by `fail2ban-telegram.sh` and `ignorehost.sh` shows the
version of the scripts that produced it:

```
📦 Scripts version: 0.3.0
```

The version is read from `$FAIL2BAN_DATA_DIR/VERSION` (the live install) and
falls back to the `VERSION` file next to the scripts. It tells which release is
running and therefore whether an automatic update has already been applied.

The update notification is only sent when something actually happened:

| Situation | Notification |
|-----------|--------------|
| Up to date | none — the check is silent |
| Update installed | `🆙 fail2ban-scripts updated: 0.2.0 ➜ 0.3.0` + what was (not) touched |
| Install failed | `fail2ban-scripts: update to 0.3.0 failed (current 0.2.0).` |
| Deploy into the data dir failed | `… was installed but the deploy into <dir> failed. Run scripts/deploy.sh --apply --dest <dir> manually.` |

### Only the scripts are updated

An automatic update **never touches the configuration files**
(`action.d/*`, `filter.d/*`, `jail.d/*`, `jail.local`,
`paths-overrides.local`):

- `jail.local` is managed by the Fail2Ban-UI — an automatic update would
  silently revert the settings changed in the UI;
- the other files change the behaviour of the running service (bantime,
  actions, jails) and must be reviewed before being applied.

The update therefore only replaces `scripts/fail2ban-telegram.sh`,
`scripts/ignorehost.sh` and the helper scripts (`deploy.sh`, `redact.sh`,
`version_check.sh`) plus the `VERSION` file. The configuration is refreshed
only on demand:

```bash
# deploy everything (scripts + configuration)
scripts/deploy.sh --apply --dest /path/to/fail2ban/data

# deploy only the scripts (what the automatic update does)
scripts/deploy.sh --apply --dest /path/to/fail2ban/data --scripts-only

# let the automatic update refresh the configuration as well
scripts/version_check.sh --with-config
```

`scripts/redact.sh` accepts the same `--scripts-only` flag, so the live →
repo sync can be limited to the scripts too.

A scripts-only update does **not** reload fail2ban: the configuration did not
change, so the running jails stay untouched.

### Requirements

The trigger must know where the deployed files live: the scripts read the
`FAIL2BAN_DATA_DIR` environment variable and do nothing when it is not set.
In the official fail2ban image the data directory is `/data`:

```yaml
environment:
  - FAIL2BAN_DATA_DIR=/data
```

The updater also needs `config.local` in that directory (secrets and the
`AUTO_UPDATE_ENABLED` flag) and `scripts/version_check.sh` must be deployed
there, so deploy the scripts at least once:

```bash
scripts/deploy.sh --apply --dest /path/to/fail2ban/data --scripts-only
```

### Manual usage

```bash
# Manual check (report only)
scripts/version_check.sh --check

# Force check now
scripts/version_check.sh --force

# Check and deploy into the live directory (scripts only)
scripts/version_check.sh --dest /path/to/fail2ban/data

# Use another secrets file (default: <data dir>/config.local)
scripts/version_check.sh --dest /path/to/fail2ban/data --secrets /path/to/config.local
```

> When `version_check.sh` runs from a repository checkout it refreshes the
> checkout itself. Use `--dest DIR` to also deploy the result into a live
> fail2ban data directory, exactly like the trigger does inside the
> container.

## Reverse sync (live → repo)

Use `redact.sh` to rewrite live files with placeholders before committing:

```bash
scripts/redact.sh --src /path/to/fail2ban/data --out /path/to/staging
diff -r . /path/to/staging   # review, then commit
```

The deploy → redact round trip is verified byte-for-byte by `local_tests/test_deploy.sh`.

## Log and backup rotation

The deployed scripts and configuration can generate log files and backups
that may grow indefinitely. The rotation runs **automatically**: the ban/unban
and ignore notification scripts (`scripts/fail2ban-telegram.sh`,
`scripts/ignorehost.sh`) trigger `scripts/log_rotate.sh` after every
notification, detached, when `FAIL2BAN_DATA_DIR` is set — exactly like the
[auto-update](#auto-update). Nothing to schedule.

```
fail2ban ──► scripts/fail2ban-telegram.sh   (ban/unban notification)
           └► scripts/ignorehost.sh          (ignore notification)
                 └► scripts/log_rotate.sh --dest <data dir> --quiet
                       ├─ read LOG_ROTATE_* from config.local
                       ├─ scan <data dir> for *.log, *.bak, *.tar.gz, *.dump, *.sql
                       └─ delete files older than max age OR larger than max size
```

| Setting | Default | Description |
|---------|---------|-------------|
| `LOG_ROTATE_ENABLED` | `true` (enabled when key is absent) | Enable/disable rotation |
| `LOG_ROTATE_MAX_AGE` | `7` | Maximum age in days (older files are deleted) |
| `LOG_ROTATE_MAX_SIZE` | `500` | Maximum size in MB (larger files are deleted) |

Settings are read from `config.local` and can be overridden via CLI flags.
Rotation is **enabled by default**: when `LOG_ROTATE_ENABLED` is missing or
set to anything other than `false`/`0`/`no`/`off`/`disabled`, the rotation runs.

**Only the data directory root is scanned** (`-maxdepth 1`): `scripts/`,
`action.d/`, `filter.d/`, `jail.d/`, `config.local`, `VERSION` and
configuration files are never touched.

### Manual usage

```bash
# Rotate using config.local defaults (max-age: 7 days, max-size: 500 MB)
scripts/log_rotate.sh --dest /path/to/fail2ban/data

# Custom maximum age and size
scripts/log_rotate.sh --dest /path/to/fail2ban/data --max-age 30 --max-size 100

# Scan a specific subdirectory within the data dir
scripts/log_rotate.sh --dest /path/to/fail2ban/data --log-dir /path/to/fail2ban/data/logs

# Dry-run: show what would be deleted without deleting
scripts/log_rotate.sh --dest /path/to/fail2ban/data --dry-run
```

| Option | Description |
|--------|-------------|
| `--dest DIR` | Target fail2ban data directory (defaults to `$FAIL2BAN_DATA_DIR` or `/data`) |
| `--max-age DAYS` | Override `LOG_ROTATE_MAX_AGE` (default: 7) |
| `--max-size MB` | Override `LOG_ROTATE_MAX_SIZE` (default: 500) |
| `--log-dir DIR` | Scan a specific directory instead of the data directory root |
| `--secrets FILE` | Use an alternative config.local |
| `--dry-run` | Show what would be deleted without deleting |
| `--quiet` | No output unless errors occur |
| `--force` | Ignore `LOG_ROTATE_ENABLED` |

Files are removed if they are **older than the max age OR larger than the max
size**. The rotation is idempotent and safe to run concurrently (deleting a
non-existent file is not an error).

## CI and release

- **`.github/workflows/ci.yml`** — runs `scripts/run_tests.sh` on every push and PR to `main`.
- **`.github/workflows/release.yml`** — when a push changes `VERSION`, creates tag `vX.Y.Z` and publishes the GitHub release. Never create the tag manually.

## Versioning

`VERSION` contains a bare semver (`0.1.0`, no `v`):

- **PATCH** — fix, tweak, docs
- **MINOR** — backward-compatible new features
- **MAJOR** — breaking changes (removed jails, changed behavior)

## Changelog

### v0.4.5

- **Security**: added explicit timeouts (10 s) to all external network calls —
  Telegram API, GeoIP (`ipapi.co`) and reverse DNS lookups — in both
  `fail2ban-telegram.sh` and `ignorehost.sh`, so a hanging external service
  can no longer block the fail2ban action queue (DoS) (PR #4).
- Feature: DNS and GeoIP lookups in `fail2ban-telegram.sh` now run concurrently
  as background jobs with `wait`, reducing ban-notification latency (PR #5).

### v0.4.4

- **Fix**: the updater and the deploy script no longer rely on the GNU-only
  `chmod --reference` / `chown --reference` options. The scripts are installed
  from inside the fail2ban container, whose image is BusyBox based: the GNU
  syntax failed there, the error was swallowed by `|| true`, and the deployed
  files silently kept the mode of the temporary file (0600 for the rendered
  ones) instead of the tight mode (0750) of the file they replace. The mode
  and the owner are now read with `stat` and applied numerically, which works
  with both GNU coreutils and BusyBox.
- **Fix**: the installer uses `chmod u+x` instead of `chmod +x`: the latter
  also added the execute bit to the group and to the others, widening the
  tight modes of the deployed scripts.
- New `local_tests/test_busybox_compat.sh`: it emulates BusyBox with a
  `chmod`/`chown` stub that rejects `--reference` and verifies that the
  permissions are preserved by `install_file`, `deploy_file` and
  `scripts/deploy.sh`.

### v0.4.3

- **Performance**: `scripts/ignorehost.sh` now runs reverse DNS and GeoIP
  lookups concurrently using a `ThreadPoolExecutor` (PR #3), reducing
  notification latency by eliminating sequential blocking on network I/O.

### v0.4.2

- **Version bump**: ensures all deployments pick up the v0.4.1 throttle
  fix. A deployment that was manually updated to v0.4.1 with the previous
  code would not auto-update to v0.4.1 (same version, `version_is_newer`
  returns false); bumping to v0.4.2 makes the auto-update trigger.

### v0.4.1

- **Fix**: the automatic updater no longer "burns" the daily check before a new GitHub release exists. The timestamp in `.last_update_check` is only written after a successful release query, and failures to reach the API no longer mark the day as checked (so the next notification will retry).
- **Feature**: configurable check interval via `AUTO_UPDATE_CHECK_INTERVAL_HOURS` in `config.local` (default: 24). The throttle file now stores a Unix timestamp for compatibility; legacy `YYYY-MM-DD` values are still accepted.

### v0.4.0

- **Feature**: automatic log and backup rotation. The ban/unban and ignore
  notification scripts (`scripts/fail2ban-telegram.sh`, `scripts/ignorehost.sh`)
  now trigger `scripts/log_rotate.sh` after every notification, detached, when
  `FAIL2BAN_DATA_DIR` is set — exactly like the auto-update. Nothing to
  schedule.
- `scripts/log_rotate.sh` removes log/backup files older than
  `LOG_ROTATE_MAX_AGE` days (default: 7) or larger than `LOG_ROTATE_MAX_SIZE`
  MB (default: 500). Only the data directory root is scanned (`-maxdepth 1`):
  scripts, configuration files, `config.local` and `VERSION` are never
  touched. The rotation is idempotent and safe to run concurrently.
- New `LOG_ROTATE_ENABLED`, `LOG_ROTATE_MAX_AGE`, `LOG_ROTATE_MAX_SIZE`
  settings in `config.local`. CLI flags (`--max-age`, `--max-size`,
  `--log-dir`, `--secrets`, `--dry-run`, `--quiet`, `--force`) override the
  config file.
- `scripts/log_rotate.sh` is deployed as a **template** (verbatim, never
  holding a secret): it reads `config.local` at runtime, like `deploy.sh`,
  `redact.sh` and `version_check.sh`.

### v0.3.0

- **Feature**: the deployed scripts update themselves. The ban/unban/ignore
  Telegram scripts (`scripts/fail2ban-telegram.sh`, `scripts/ignorehost.sh`)
  trigger `scripts/version_check.sh` after every notification, when the
  auto-update is enabled. The check is detached (it never delays the
  notification) and runs at most once per day.
- **The automatic update only refreshes the scripts**: the configuration
  files (`action.d/*`, `filter.d/*`, `jail.d/*`, `jail.local`,
  `paths-overrides.local`) are never touched automatically, because
  `jail.local` is managed by the Fail2Ban-UI and the others change the
  behaviour of the running service. New `--scripts-only` flag on
  `scripts/deploy.sh` / `scripts/redact.sh` and `--with-config` flag on
  `scripts/version_check.sh` for the explicit cases.
- The updater is **self-contained**: it injects the secrets itself instead of
  calling `scripts/deploy.sh`, whose installed version comes from the release
  and may be too old for the new flags. The helpers (`deploy.sh`,
  `redact.sh`, `version_check.sh`) and `VERSION` are deployed as **templates**
  (verbatim, never holding a secret); only `fail2ban-telegram.sh` and
  `ignorehost.sh` are rendered with the secrets.
- **Every Telegram message now shows the version of the running scripts**
  (`📦 Scripts version: 0.3.0`), read from `$FAIL2BAN_DATA_DIR/VERSION` with
  a fallback to the `VERSION` file next to the scripts. The update
  notification reports the version transition (`0.2.0 ➜ 0.3.0`) and is only
  sent when an update is actually installed — an up-to-date check stays
  silent.
- The updater installs the release atomically (a running script keeps its
  inode), keeps the permissions of the replaced files and uses a lock so
  that two checks never run at the same time.
- The updater falls back to the GitHub releases page when the API is rate
  limited, and reloads fail2ban only when the configuration changed.
- `scripts/deploy.sh` refuses to deploy into a git working tree: the
  rendered files contain the real secrets and could be committed.
- New `local_tests/test_autoupdate.sh` covering the whole chain (trigger,
  throttle, enable flag, deploy, atomic replace, git working tree guard,
  version displayed in the notifications).

### v0.2.1

- **Fix**: `scripts/ignorehost.sh` no longer `exec()`s `config.local`. The file
  is shell-style `KEY=VALUE`, and a real Telegram bot token (`123456789:AAE…`)
  is not a valid Python expression: the loader raised a `SyntaxError` and the
  whitelist silently fell back to the built-in placeholders, i.e. every
  whitelisted address got banned. The two list literals are now parsed with
  `ast.literal_eval` (no code execution).
- New `local_tests/test_ignorehost_config.sh` covering the loader (real
  credential in the config, missing file, malformed list, brackets in strings).
- Documented that `config.local` must also be present in the deployed fail2ban
  data directory and that the auto-update is **not** scheduled by default.

### v0.1.1

- Remove obsolete historical scripts `scripts/fail2ban-telegram_old.sh` and `scripts/ignorehost_old.sh` and all references.

### v0.1.2

- Merge PR #1: Bolt concurrent network lookups in ignorehost.sh
- Merge PR #2: Sentinel HTML injection fixes and FCrDNS checks
- Bumped VERSION to 0.1.2

### v0.2.0

- Merge 2 PRs: concurrent network lookups, HTML escaping + FCrDNS checks

### v0.1.0

- Initial import of custom fail2ban scripts and configuration.
- Secrets removed from sources (placeholders + `config.local` gitignored), with `deploy.sh` / `redact.sh` pipeline.
- Local test suite (`scripts/run_tests.sh`), CI and release workflows.
- `version_check.sh` auto-update from GitHub releases.
- `config.local` consolidates all host-specific settings (secrets, domains, flags).