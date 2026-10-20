# AGENTS.md — fail2ban-scripts

Guidelines for agents and developers working on this repository.

## What this repository is

Custom **fail2ban** scripts and configuration, deployed into a live fail2ban
**data directory** with `scripts/deploy.sh`.

| Kind | Files | Notes |
|---|---|---|
| Bash | `scripts/fail2ban-telegram.sh`, `scripts/*.sh` | `bash -n` is the syntax gate |
| Python | `scripts/ignorehost.sh` | **Python despite the `.sh` extension** — run under `fail2ban-python`; gate is `python3 -c 'compile(...)'` |
| config | `action.d/*`, `filter.d/*`, `jail.d/*`, `jail.local`, `paths-overrides.local` | fail2ban INI files, executed as root |

`iptables-nft.local`, `npm-docker.conf` and `npm-docker.local` use **CRLF** line
endings (as shipped upstream) — do not "fix" them.

## Hard rules

- **No secrets in git.** Source files carry `__PLACEHOLDER__` tokens only; real
  values live in `config.local` (gitignored). `local_tests/test_secrets.sh` fails the
  build otherwise. If a real credential ever lands in a commit, rotate it.
- **No host-specific paths.** The live fail2ban directory is always passed
  explicitly (`scripts/deploy.sh --dest DIR`, `scripts/redact.sh --src DIR`);
  never hardcode a machine-specific absolute path (the authoring host's storage
  root, a user home, a mount point, a drive letter).
  `scripts/test_no_host_paths.sh` enforces this.

## Anti-patterns (never add these)

- Any absolute path that only exists on the machine that authored the change —
  including as an "example" in docs, skills, comments or default values.
- The authoring machine's directory layout names (storage roots, project
  folders) used as if they were part of this repository's contract —
  `scripts/test_no_host_paths.sh` rejects both.

## Other hard rules

- **Never edit the live files by hand and copy them back raw** — they contain
  secrets. Use `scripts/redact.sh` to bring changes back into the repo.
- **This runs as root on a security-critical service.** Never weaken
  `ignoreip`/`ignorecommand`, `banaction`, `bantime`, `maxretry` or disable a
  jail without explicit user intent; never add `curl | sh`, reverse shells,
  persistence (cron/systemd), `eval`/obfuscated payloads, `chmod 777`, or
  `rm -rf` outside the change's own scope.

## Testing

Single entry point — the same suite CI runs:

```bash
bash scripts/run_tests.sh
```

| Test | Scope |
|---|---|
| `local_tests/test_syntax.sh` | `bash -n` / Python `compile()` for every script |
| `local_tests/test_configs.sh` | INI sections, `failregex` + `<HOST>` + regex compiles, `/etc/fail2ban/scripts/*` cross refs, executable bits, placeholders, semver `VERSION` |
| `local_tests/test_secrets.sh` | leak scan (Telegram tokens, chat IDs, callback secret, high-entropy blobs, private keys) |
| `local_tests/test_deploy.sh` | `deploy.sh` + `redact.sh` round trip with fake secrets, dry-run safety, placeholder-secret rejection |
| `local_tests/test_no_host_paths.sh` | rejects any host-specific absolute path |
| `local_tests/test_skill_sync.sh` | `.agents/skills/*` and `.opencode/commands/*` stay in sync |
| `local_tests/test_yaml.sh` | parses `.github/workflows/*.yml` (PyYAML in CI) |

Requirements: `bash`, `python3`; `pyyaml` for the workflow check (CI installs it).

## Versioning

`VERSION` holds a bare semver (`0.1.0`, no `v`). A push to `main` that changes
`VERSION` makes `.github/workflows/release.yml` tag `vX.Y.Z` and publish the
release — never create the tag by hand. Bump PATCH for fixes/docs, MINOR for
features, MAJOR for breaking changes (removed jail, changed behaviour).

## Commits and releases

Use conventional commits (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `test:`,
`security:`). For committing/pushing and for merging PRs, follow
`.agents/skills/commit-push` and `.agents/skills/pr-push` (also available as
`.opencode/commands/commit-push.md` and `.opencode/commands/pr-push.md`).

## Code style

- `#!/bin/bash` for shell scripts; quote variables; `[[ ]]` over `[ ]`;
  `command -v` instead of `which`.
- Keep the existing log/report style of `scripts/*.sh` (`OK`/`FAIL`/`WARN`
  prefixes, aggregate failures in a `fail` flag, `exit $fail`).
- Keep the Python files consistent with their current structure
  (`fail2ban-python` shebang, only stdlib + `fail2ban` modules).
