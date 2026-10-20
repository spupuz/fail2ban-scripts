---
description: Review working-tree changes, verify them with the local suite (bash scripts/run_tests.sh — syntax, fail2ban config structure, secret/leak scan, deploy-pipeline test, workflow YAML), bump the VERSION file when a release is intended, then commit and push to origin/main with a conventional message and confirm/rewrite the GitHub release created by .github/workflows/release.yml. Use when the user asks to commit and push local changes, or says "push", "commit", "release", "ship it".
---

# Commit & Push (fail2ban-scripts)

**Goal:** Verify local changes are safe before committing, keep `VERSION` correct, commit, push to `origin/main` with a conventional commit message, and confirm the GitHub release created by CI (`.github/workflows/release.yml`) with manually rewritten notes.

> **What this project is:** the custom fail2ban scripts and configuration that get deployed into the live fail2ban **data directory** (its location is host-specific and is never hardcoded here — always pass it explicitly with `scripts/deploy.sh --dest DIR`).
> - `scripts/fail2ban-telegram.sh` (bash) and `scripts/ignorehost*.sh` (**Python**, `#!/usr/bin/env fail2ban-python`, despite the `.sh` extension).
> - `action.d/*.local|conf`, `filter.d/npm-docker.conf`, `jail.d/npm-docker.local`, `jail.local`, `paths-overrides.local` — fail2ban INI files.
> - `scripts/deploy.sh` renders the files into the live fail2ban directory while injecting real secrets from `secrets.env` (gitignored) into `__PLACEHOLDER__` tokens.
> - There is **no** `package.json`, no `tests/` directory, no Node, no Docker, no `requirements.txt`. The only verification entry point is **`bash scripts/run_tests.sh`**. Do NOT run `npm test`, `pytest`, `docker compose`, or anything meant for other repositories.
> - **No host path is hardcoded anywhere** (source, docs, skills, workflows): the live fail2ban data directory must always be passed explicitly as `scripts/deploy.sh --dest DIR`. `scripts/test_no_host_paths.sh` fails the build if one appears.
> - `fail2ban-client` is unavailable in CI — never make the tests depend on a running fail2ban.

## Rules

- Only commit what the user asked for; **never commit secrets**.
- **`secrets.env` must never be tracked, staged or committed** — real Telegram bot tokens, chat IDs and the Fail2Ban-UI callback secret live only there. Source files must keep their `__PLACEHOLDER__` tokens. `scripts/test_secrets.sh` is the gate: if it fails, you leaked a credential.
- **Never stage tooling/memory files**: `secrets.env`, `.opencode/`, `.agents/`, `.kilo/`, `.roo/`, `.omnistate/`, `AGENTS.md`, `tasks-history.json`, `*.bak`, `*.f2bui.bak`, `db/`, `run/`, `.fail2ban-ui-operations/`. `.gitignore` already covers them; if one is staged, stop and `git rm --cached <file>`.
- **`VERSION` (bare `X.Y.Z`) is the release trigger**: pushing a change to `VERSION` makes `.github/workflows/release.yml` tag `vX.Y.Z` and publish the release. Bump it only when a release is actually intended (code/config change), never in docs-only commits.
- Never create the tag/release manually with `gh release create` — CI does it. Only push after the user explicitly asks to commit/push (or invokes this skill).
- Never leave auto-generated release notes as-is — always rewrite them.
- **No remote configured?** This repository may be local-only. Commit normally, then report that the push/release steps are skipped because `origin` is missing — never invent a remote.
- **Deployed copies**: changes here do not affect the running fail2ban until `scripts/deploy.sh --dest DIR --apply` is run (ask the user before deploying).

## Steps

### 1. Inspect the Working Tree

```bash
git status --short
git diff --stat
git log --oneline -10
```

### 2. Review the Diff for Problems

```bash
git diff
```

Verify before committing:

- **No secrets**: no bot tokens (`<digits>:AA...`), chat IDs, callback secrets, passwords or API keys — in any file type. Run the leak scan:
  ```bash
  bash scripts/test_secrets.sh
  ```
  Every credential-looking value must be a `__PLACEHOLDER__`, a `YOUR_...` doc value, or a `$VAR` reference. If a real value appears, **stop** and report.
- **No tooling/memory files staged**: `git ls-files | grep -E "(secrets\.env$|\.bak$|^db/|^run/|\.fail2ban-ui-operations/)"` must be empty.
- **No host-specific paths**: never introduce absolute paths that exist only on
  the authoring machine (the live fail2ban directory is always a runtime
  argument: `scripts/deploy.sh --dest DIR`, `scripts/redact.sh --src DIR`).
  `scripts/test_no_host_paths.sh` is the gate.
- **No debug leftovers**: no new `set -x`, ad-hoc `echo` debugging, or new `TODO`/`FIXME` in the scripts (pre-existing markers are fine).
- **No deleted functionality**: jails, filters, actions or options removed must be confirmed intentional (removing a jail stops its protection — treat as a breaking change).
- **fail2ban-specific red flags** — STOP and ask the user if the diff does any of these:
  - turns `ignoreip`/`ignorecommand` into something that whitelists broadly (e.g. `0.0.0.0/0`, `::/0`) or shells out to network fetches;
  - changes `action`/`actionban` to run downloaded code (`curl | sh`) or to disable banning (`iptables`/`nft` flush, `banaction = none` without explanation);
  - loosens `bantime = -1`→`0`, `maxretry` to huge values, or `enabled = false` on the protecting jails without explicit user intent;
  - modifies `ui-custom-action.conf` to POST data to a host other than `127.0.0.1:8083`.
- **Host-harmful operations** — refuse to commit if new/modified code contains: `rm -rf /`, `mkfs`, `dd if=`, fork bombs, `curl | sh` / `wget | bash`, reverse shells (`/dev/tcp/`, `nc -e`), `chmod 777`, `sudo` in non-interactive contexts, `systemctl stop|reboot|shutdown`, writes to `/etc/cron*`, `/etc/systemd`, `/etc/profile`, `sysctl -w`, or exfiltration (`tar|zip|scp|rsync` to external hosts).
- **Malicious-code review**: read the full diff line by line (it will run as root on the fail2ban host). Refuse anything that exfiltrates data, steals secrets, executes remote code, adds persistence (cron/systemd/autostart), obfuscates payloads (`eval`, base64 blobs), hardcodes credentials, or disables security controls. If a signal is ambiguous, **do not commit** — ask.
- **Code style**: `command -v` not `which`; quote variables; `[[ ]]` not `[ ]`; `#!/bin/bash` for shell, keep the existing Python style in `ignorehost*.sh`; keep `.conf`/`.local` files byte-identical to the live files except for intended changes (CRLF line endings in `iptables-nft.local`, `npm-docker.conf`, `npm-docker.local` are original — do not "fix" them).

### 3. Run Verification

All must pass before committing (this is exactly what CI runs):

```bash
bash scripts/run_tests.sh
```

It executes, in order: `scripts/test_syntax.sh`, `test_configs.sh`, `test_secrets.sh`, `test_deploy.sh`, `test_no_host_paths.sh`, `test_skill_sync.sh`, `test_yaml.sh`.

If any step fails: fix it, re-run, and only then continue — **never commit or push a failing tree**.

### 4. Bump the Version (only when releasing)

```bash
cat VERSION   # bare X.Y.Z, e.g. 0.1.0
```

SemVer: breaking change → MAJOR, new feature → MINOR, fix/tweak/docs → PATCH.

```bash
NEW_VERSION="0.1.1"   # ← decide manually per the rules above
echo "$NEW_VERSION" > VERSION
```

Add a `### vX.Y.Z` entry to the `## Changelog` section of `README.md` describing the change. **Do not bump** for docs/tooling-only commits that must not cut a release (leaving `VERSION` untouched means CI creates no release).

### 5. Stage and Commit

```bash
git add -A
git status --short   # re-confirm no secrets.env / .opencode / .agents staged
git commit -m "feat: ..."   # conventional: feat|fix|docs|chore|ci|test|security|refactor
```

Split unrelated concerns into separate commits. Match the terse single-line style of `git log --oneline -10`.

### 6. Push

```bash
git remote get-url origin >/dev/null 2>&1 || { echo "No origin remote — local commit only."; exit 0; }
git push origin main
```

A push that changed `VERSION` triggers the release workflow; any other push runs only CI (`.github/workflows/ci.yml`).

### 7. Confirm the GitHub Release & Rewrite the Notes

Only when `VERSION` was bumped:

```bash
gh run list --workflow=release.yml --limit 1 --json databaseId,status
gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status

gh release view "vX.Y.Z"
gh release edit "vX.Y.Z" --notes "## What's Changed

### <summary: Security / Bugfix / Feature / Docs>

- <bullet points>

**Full Changelog**: https://github.com/spupuz/fail2ban-scripts/compare/vPREV...vX.Y.Z"
```

- If `gh` is unavailable or the workflow failed, **do not block the report** — state the tag/`VERSION` so the release can be finalized manually.

### 8. Report

Report: the commit hash, whether `VERSION` was bumped (`vX.Y.Z`), the verification result (`scripts/run_tests.sh` pass/fail), the change summary, the release URL (or why there is none), and whether the notes were rewritten.
