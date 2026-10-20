#!/bin/bash
# Fail if a host-specific absolute path leaks into a tracked file.
#
# The repository must stay portable: the live fail2ban data directory is always
# passed explicitly (`scripts/deploy.sh --dest DIR`, `scripts/redact.sh --src DIR`)
# and never baked into the sources, docs, skills or workflows.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mapfile -t FILES < <(git ls-files -co --exclude-standard 2>/dev/null || find . -type f -not -path './.git/*')
FILTERED=()
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] && FILTERED+=("$f")
done
FILES=("${FILTERED[@]}")

# Patterns that indicate a machine-specific location. Every host path is
# rejected unconditionally — including the examples in the docs.
# Names are assembled at runtime so this script never matches itself.
PATTERNS=('/zfs''files' 'Docker''Config' '/m''nt/' '/s''rv/' '/ho''me/[A-Za-z0-9._-]+/' '/Us''ers/[A-Za-z0-9._-]+/' '[A-Za-z]:\\\\')

fail=0
for pattern in "${PATTERNS[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    echo "FAIL [host-path] $hit"
    fail=1
  done < <(grep -rnoE "$pattern" -- "${FILES[@]}" 2>/dev/null || true)
done

if [[ $fail -eq 0 ]]; then
  echo "No host-specific paths found (${#FILES[@]} files checked)."
fi
exit $fail
