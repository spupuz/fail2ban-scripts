#!/bin/bash
# Secret/leak scan over every file that is NOT gitignored.
#
# Fails when a real-looking credential is committed. Placeholders of the form
# __NAME__ (see secrets.env.example) are always allowed — they are the
# mechanism this repo uses to keep real values out of git history.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mapfile -t FILES < <(git ls-files -co --exclude-standard 2>/dev/null || find . -type f -not -path './.git/*')
# secrets.env is gitignored, but make sure it can never be scanned-and-shipped
FILTERED=()
for f in "${FILES[@]}"; do
  [[ -f "$f" && "$f" != "secrets.env" ]] && FILTERED+=("$f")
done
FILES=("${FILTERED[@]}")

fail=0
report() { # rule, file, line, match
  echo "FAIL [$1] $2:$3 -> $4"
  fail=1
}

is_allowed() { # returns 0 when the matched value is a placeholder/reference
  local v="$1"
  [[ "$v" == __*__ ]] && return 0          # __PLACEHOLDER__
  [[ "$v" == YOUR_* ]] && return 0         # YOUR_TOKEN_HERE style docs
  [[ "$v" == *'$'* ]] && return 0          # ${VAR} / $VAR references
  return 1
}

# --- 1. Telegram bot tokens (digits:AA...) — never a placeholder ----------
while IFS=: read -r file line match; do
  report "telegram-token" "$file" "$line" "$match"
done < <(grep -rnoE '[0-9]{5,12}:AA[A-Za-z0-9_-]{25,}' -- "${FILES[@]}" 2>/dev/null || true)

# --- 2. Credential-like assignments whose value is not a placeholder ------
while IFS=: read -r file line match; do
  value="$(sed -E 's/^[^=:]*[=:][[:space:]]*//' <<<"$match" | tr -d "\"'" | awk '{print $1}')"
  is_allowed "$value" && continue
  report "credential-assignment" "$file" "$line" "$match"
done < <(grep -rnoEi '(api_?token|telegram_[a-z_]*token|chat_?id|client_?secret|callback_?secret|x-callback-secret|api_?key|password|passphrase)[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'[:space:]]{4,}' -- "${FILES[@]}" 2>/dev/null || true)

# --- 3. Long high-entropy blobs (40+ chars, must start with alnum so that
#       plain comment separators of dashes are not flagged) ------------------
while IFS=: read -r file line match; do
  is_allowed "$match" && continue
  report "high-entropy-blob" "$file" "$line" "$match"
done < <(grep -rnoE '[A-Za-z0-9][A-Za-z0-9_-]{39,}' -- "${FILES[@]}" 2>/dev/null || true)

# --- 4. Hardcoded numeric chat IDs ----------------------------------------
while IFS=: read -r file line match; do
  report "hardcoded-chat-id" "$file" "$line" "$match"
done < <(grep -rnoE '(chat_?id|chatId)[^0-9-]{0,4}-?[0-9]{6,12}([^0-9]|$)' -- "${FILES[@]}" 2>/dev/null || true)

# --- 5. private keys -------------------------------------------------------
while IFS=: read -r file line match; do
  report "private-key" "$file" "$line" "$match"
done < <(grep -rnoE 'BEGIN [A-Z ]*PRIVATE KEY' -- "${FILES[@]}" 2>/dev/null || true)

if [[ $fail -eq 0 ]]; then
  echo "Secret scan passed (${#FILES[@]} files checked, no real credentials found)."
fi
exit $fail
