#!/bin/bash
# YAML sanity check for .github/workflows/*.yml (skipped when PyYAML is absent;
# CI installs it so the check always runs there).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mapfile -t YAML < <(find .github -name '*.yml' -o -name '*.yaml' 2>/dev/null | sort)
if [[ ${#YAML[@]} -eq 0 ]]; then
  echo "No workflow files found."
  exit 0
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "SKIP PyYAML not available — workflow syntax not verified locally (${#YAML[@]} files)."
  exit 0
fi

fail=0
for f in "${YAML[@]}"; do
  if python3 - "$f" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
assert isinstance(doc, dict) and doc, "empty or non-mapping YAML"
PY
  then
    echo "OK   yaml $f"
  else
    echo "FAIL yaml $f"
    fail=1
  fi
done

[[ $fail -eq 0 ]] && echo "Workflow YAML checks passed (${#YAML[@]} files)."
exit $fail
