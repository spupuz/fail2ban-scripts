#!/bin/bash
# Keep the agent-facing copies of the skills in sync:
#   .agents/skills/<name>/SKILL.md  (frontmatter: name + description)
#   .opencode/commands/<name>.md    (frontmatter: description only, same body)
# Fails when a copy is missing or the bodies diverge.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKILLS=(commit-push pr-push)
fail=0

for name in "${SKILLS[@]}"; do
  skill=".agents/skills/$name/SKILL.md"
  command=".opencode/commands/$name.md"

  if [[ ! -f "$skill" ]]; then
    echo "FAIL missing $skill"
    fail=1
    continue
  fi
  if [[ ! -f "$command" ]]; then
    echo "FAIL missing $command"
    fail=1
    continue
  fi

  skill_name="$(sed -n 's/^name: *//p' "$skill" | head -1)"
  skill_desc="$(sed -n 's/^description: *//p' "$skill" | head -1)"
  cmd_desc="$(sed -n 's/^description: *//p' "$command" | head -1)"

  [[ "$skill_name" == "$name" ]] || { echo "FAIL $skill frontmatter name is '$skill_name', expected '$name'"; fail=1; }
  [[ -n "$skill_desc" ]] || { echo "FAIL $skill has no description"; fail=1; }
  [[ "$skill_desc" == "$cmd_desc" ]] || { echo "FAIL $command description differs from $skill"; fail=1; }

  # Body = everything after the second '---' line of the frontmatter.
  if ! diff -q <(tail -n +5 "$skill") <(tail -n +4 "$command") >/dev/null; then
    echo "FAIL body of $command differs from $skill:"
    diff -u <(tail -n +5 "$skill") <(tail -n +4 "$command") | head -20
    fail=1
    continue
  fi

  # The command frontmatter must use the same shape as the skill frontmatter.
  if [[ "$(sed -n '1p' "$skill")" != "---" || "$(sed -n '4p' "$skill")" != "---" ]]; then
    echo "FAIL $skill frontmatter is not a 3-line block (name/description/---)"
    fail=1
    continue
  fi
  if [[ "$(sed -n '1p' "$command")" != "---" || "$(sed -n '3p' "$command")" != "---" ]]; then
    echo "FAIL $command frontmatter is not a 2-line block (description/---)"
    fail=1
    continue
  fi

  echo "OK   $name in sync ($skill <-> $command)"
done

[[ $fail -eq 0 ]] && echo "Skill/command sync checks passed."
exit $fail
