#!/usr/bin/env bash
# Public-repo guard: fails if tracked (or staged) content looks like a secret,
# a personal/internal reference, or a file type that should never be committed.
#
#   scripts/check-secrets.sh            scan all tracked files (CI)
#   scripts/check-secrets.sh --staged   scan staged files (pre-commit hook)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

mode=tracked
[[ "${1:-}" == "--staged" ]] && mode=staged
self="scripts/check-secrets.sh"
failed=0

fail() { echo "✖ $1" >&2; failed=1; }

if [[ $mode == staged ]]; then
  files=$(git diff --cached --name-only --diff-filter=ACMR)
  grep_src=(--cached)
else
  files=$(git ls-files)
  grep_src=()
fi
[[ -z "$files" ]] && exit 0

# scan DESCRIPTION REGEX [ALLOW_REGEX] — ALLOW_REGEX filters out acceptable hits.
scan() {
  local desc=$1 re=$2 allow=${3:-}
  local hits
  hits=$(git grep -nIiE ${grep_src[@]+"${grep_src[@]}"} -e "$re" -- . ":(exclude)$self")
  local rc=$?
  if [[ $rc -gt 1 ]]; then fail "Scan error while checking: $desc"; return; fi
  [[ -n "$allow" && -n "$hits" ]] && hits=$(echo "$hits" | grep -viE "$allow" || true)
  if [[ -n "$hits" ]]; then
    fail "$desc"
    echo "$hits" | sed 's/^/    /' | cut -c1-200 >&2
  fi
}

# Credentials
scan "GitHub token"            'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
scan "OpenAI/Anthropic key"    'sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}'
scan "AWS access key"          'AKIA[0-9A-Z]{16}'
scan "Google API key"          'AIza[0-9A-Za-z_-]{35}'
scan "Slack token"             'xox[abprs]-[A-Za-z0-9-]{10,}'
scan "Private key"             '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan "Hardcoded secret"        '(api[_-]?key|secret|token|password)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_./+=-]{16,}["'"'"']'

# Personal / internal references
scan "Personal home path"      '/Users/[A-Za-z0-9._-]+/'
scan "Internal package feed"   'visualstudio\.com|dev\.azure\.com|packagefeedproxy|pkgs\.dev\.azure'
scan "Email address (use example.com or a GitHub noreply address)" \
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  '@users\.noreply\.github\.com|@example\.(com|org)|git@github\.com|@github/|@[0-9]+\.[0-9]+'

# Lockfile must resolve only from the public npm registry
for lock in $(echo "$files" | grep -E '(^|/)package-lock\.json$'); do
  content=$( [[ $mode == staged ]] && git show ":$lock" || cat "$lock" )
  bad=$(echo "$content" | grep -E '"resolved"' | grep -v 'https://registry.npmjs.org/' | head -5)
  [[ -n "$bad" ]] && { fail "$lock resolves packages outside registry.npmjs.org"; echo "$bad" | sed 's/^/    /' >&2; }
done

# Forbidden file types
bad_files=$(echo "$files" | grep -E '(^|/)\.env(\..*)?$|\.(pem|p12|key|cer|mobileprovision|keychain)$|(^|/)\.npmrc$' || true)
[[ -n "$bad_files" ]] && { fail "Forbidden file type"; echo "$bad_files" | sed 's/^/    /' >&2; }

# Commit identity must not expose a personal/work email
if [[ $mode == staged ]]; then
  email=$(git config user.email || true)
  [[ "$email" == *@users.noreply.github.com ]] || fail "git user.email must be a GitHub noreply address (currently: ${email:-unset})"
fi

if [[ $failed -ne 0 ]]; then
  echo "Public repo guard failed — remove the content above (see AGENTS.md)." >&2
  exit 1
fi
echo "✓ No secrets or personal references found ($mode)."
