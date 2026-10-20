---
name: pr-push
description: Check open GitHub PRs, review them for secrets and fail2ban/host-safety issues, merge them locally on a release branch, run bash scripts/run_tests.sh, bump the VERSION file, push to main and confirm the release created by .github/workflows/release.yml (rewriting its notes). Use when releasing a new version of fail2ban-scripts or merging pending PRs with gh and git.
---

# Release PRs (fail2ban-scripts)

**Goal:** Check open GitHub PRs, merge them onto a release branch, verify the result with the local test suite, bump `VERSION`, publish via `main`, and confirm the CI-created release with rewritten notes.

> **Project shape:** custom fail2ban scripts (`scripts/fail2ban-telegram.sh` is bash, `scripts/ignorehost*.sh` are **Python** despite `.sh`) plus fail2ban `.conf`/`.local` config files, deployed with `scripts/deploy.sh` (secret injection from the gitignored `config.local`; the target directory is always passed explicitly, never hardcoded). There is **no** Node/npm, no `tests/` dir, no Docker, no Python dependencies — the verification entry point is **`bash scripts/run_tests.sh`**, which is exactly what `.github/workflows/ci.yml` runs. Never run commands belonging to other repositories (`npm test`, `pytest`, `docker compose`).

## Rules

- Never merge (or release) a PR that carries a real secret: bot tokens, chat IDs, callback secrets, API keys. `local_tests/test_secrets.sh` is the gate; source files must keep `__PLACEHOLDER__` tokens and `config.local` must stay untracked.
- Never stage `.opencode/`, `.agents/`, `config.local`, `*.bak`, `db/`, `run/`, `.fail2ban-ui-operations/`.
- `VERSION` (bare `X.Y.Z`) drives `.github/workflows/release.yml`: a push touching it tags `vX.Y.Z` and publishes the release. Never create the tag manually with `gh release create`.
- **No `origin` remote or `gh` not authenticated?** This repository may be local-only: report that there are no PRs to merge, and fall back to the `commit-push` flow for whatever is in the working tree — never invent a remote or a PR.
- Never leave auto-generated release notes as-is — always rewrite them.

## Steps

### 1. Check Open PRs

```bash
gh pr list --state open --json number,title,headRefName
```

If there are none, say so and fall back to `commit-push` for the current tree.

### 2. Fetch Remote Branches and Tags

```bash
git fetch origin --tags
```

### 3. Create the Release Branch

```bash
git checkout main
git pull origin main
git checkout -b release/vX.Y.Z     # vX.Y.Z = the version you are about to release
```

### 4. Review Each PR

For every open PR:

```bash
git diff origin/main...origin/<headRefName>
```

Verify the PR is not already in `main` and introduces no problems:

- **No secrets**: no `<digits>:AA...` bot tokens, numeric chat IDs, `X-Callback-Secret` values, passwords or API keys — only `__PLACEHOLDER__` tokens. Otherwise **abort the release**.
- **fail2ban safety** (this runs as root and guards the host):
  - `ignoreip`/`ignorecommand` must not whitelist `0.0.0.0/0`, `::/0`, or fetch/execute remote content;
  - `action`/`actionban` must not flush/replace firewall rules with `none`, download-and-run code, or send logs/jails to an unexpected endpoint (only `127.0.0.1:8083` is legitimate for `ui-custom-action.conf`);
  - jails must not be disabled (`enabled = false`), `bantime`/`maxretry` weakened, or `norestored`/`banaction` changed without explicit user intent;
  - script changes must not add persistence (cron/systemd), reverse shells, `eval`/obfuscated payloads, `chmod 777`, `rm -rf` outside the change's own scope, or writes to `/etc/cron*`, `/etc/systemd`, `/etc/profile`.
  - If anything is ambiguous, **stop and ask** before merging.
- **No debug leftovers** (`set -x`, stray `echo`, new `TODO`/`FIXME`) and no accidental deletion of jails/filters/actions.
- Ignore version bumps, `.github/` and tooling-only changes when judging intent.

### 5. Merge in Order

```bash
git merge origin/<headRefName> --no-edit
```

### 6. Run Verification

```bash
bash scripts/run_tests.sh
```

Runs `test_syntax.sh`, `test_configs.sh`, `test_secrets.sh`, `test_deploy.sh`, `test_no_host_paths.sh`, `test_skill_sync.sh`, `test_yaml.sh`. **If anything fails, abort the release, report, and do not push.**

### 7. Determine the Next Version

```bash
cat VERSION   # current bare X.Y.Z
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
```

SemVer: breaking change → MAJOR, new feature → MINOR, fix/tweak/docs → PATCH.

### 8. Bump VERSION

```bash
echo "X.Y.Z" > VERSION    # only place VERSION changes — during a release
```

Add a `### vX.Y.Z` entry to the `## Changelog` section in `README.md`.

### 9. Commit on the Release Branch

```bash
git add -A
git status --short     # confirm no config.local / tooling files staged
git commit -m "vX.Y.Z: merge PRs #A-B, summary

- Merge PR #A: short description
- Merge PR #B: short description"
```

### 10. Merge to Main

```bash
git checkout main
git merge release/vX.Y.Z --no-edit
git branch -d release/vX.Y.Z
git status --short     # anything lingering → commit it before pushing
```

### 11. Push

```bash
git remote get-url origin >/dev/null 2>&1 || { echo "No origin remote — release kept local."; exit 0; }
git push origin main
```

The push that changes `VERSION` triggers `.github/workflows/release.yml` (tag `vX.Y.Z` + release) after `ci.yml` is green.

### 12. Confirm and Rewrite the Release Notes

```bash
gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
gh release view "vX.Y.Z"
gh release edit "vX.Y.Z" --notes "## What's Changed

### <summary: Security / Feature / Bugfix / Docs>

- <bullet points, one per merged PR>

**Full Changelog**: https://github.com/spupuz/fail2ban-scripts/compare/vPREV...vX.Y.Z"
```

If `gh` or the workflow is unavailable, report the tag so the release can be finalized manually — do not block.

### 13. Report

"Released vX.Y.Z with N PRs merged" — confirm `VERSION` matches the tag, list the verification result (`scripts/run_tests.sh`), and state that the release notes were rewritten.
