#!/bin/bash
# Syntax gate for the whole repository:
#   - *.sh with a bash/sh shebang  -> `bash -n`
#   - *.sh with a python shebang   -> python compile() (ignorehost*.sh are Python,
#     they run under fail2ban-python despite the .sh extension)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mapfile -t FILES < <(git ls-files -co --exclude-standard 2>/dev/null || find . -type f -not -path './.git/*')

sh_files=()
py_files=()
for f in "${FILES[@]}"; do
  [[ -f "$f" && "$f" == *.sh ]] || continue
  if head -1 "$f" | grep -qi 'python'; then
    py_files+=("$f")
  else
    sh_files+=("$f")
  fi
done

fail=0

for f in "${sh_files[@]}"; do
  if bash -n "$f"; then
    echo "OK   bash -n      $f"
  else
    echo "FAIL bash -n      $f"
    fail=1
  fi
done

for f in "${py_files[@]}"; do
  if python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f"; then
    echo "OK   py-compile   $f"
  else
    echo "FAIL py-compile   $f"
    fail=1
  fi
done

if [[ ${#sh_files[@]} -eq 0 && ${#py_files[@]} -eq 0 ]]; then
  echo "FAIL no shell/python files found"
  fail=1
fi

[[ $fail -eq 0 ]] && echo "Syntax checks passed (${#sh_files[@]} bash, ${#py_files[@]} python)."
exit $fail
