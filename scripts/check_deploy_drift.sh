#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CANONICAL_RUNBOOK="docs/deployment.md"
CANONICAL_SKILL=".claude/skills/deploy.md"

fail() {
  echo "ERROR: $*" >&2
  return 1
}

check_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "Missing required file: $path"
}

check_pattern_only_in() {
  local pattern="$1"; shift
  local -a allowed_files=("$@")

  local hits=""
  local -a files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    files+=("$file")
  done < <(
    find docs .claude/skills -type f -name '*.md' -print 2>/dev/null || true
    [[ -f README.md ]] && echo "README.md"
  )

  local file
  for file in "${files[@]}"; do
    if grep -nF -- "$pattern" "$file" >/dev/null 2>&1; then
      hits+="${file}"$'\n'
    fi
  done

  hits="$(printf "%s" "$hits" | sort -u)"

  [[ -n "$hits" ]] || return 0

  local hit
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    hit="${hit#./}"
    local allowed=0
    local f
    for f in "${allowed_files[@]}"; do
      f="${f#./}"
      if [[ "$hit" == "$f" ]]; then
        allowed=1
        break
      fi
    done
    if [[ "$allowed" -ne 1 ]]; then
      fail "Pattern must not drift outside canonical docs: '$pattern' found in $hit"
    fi
  done <<< "$hits"
}

check_pattern_absent_in() {
  local pattern="$1"
  local path="$2"

  if grep -nF -- "$pattern" "$path" >/dev/null 2>&1; then
    fail "Skill doc must stay minimal: '$pattern' found in $path"
  fi
}

main() {
  check_exists "$CANONICAL_RUNBOOK"
  check_exists "$CANONICAL_SKILL"

  # The runbook title/identity should not be duplicated.
  check_pattern_only_in "Agent Sessions Deployment Runbook" "$CANONICAL_RUNBOOK"
  check_pattern_only_in "One-screen cheat sheet" "$CANONICAL_RUNBOOK"
  check_pattern_only_in "Quick Start (Unified Tool)" "$CANONICAL_RUNBOOK"
  check_pattern_only_in "Unified Tool Subcommands" "$CANONICAL_RUNBOOK"
  check_pattern_only_in "Pre-flight Checklist (Mostly Automated Now)" "$CANONICAL_RUNBOOK"
  check_pattern_only_in "Automated Deployment" "$CANONICAL_RUNBOOK"

  # The agent skill should stay an entrypoint, not a second runbook.
  check_pattern_absent_in "Pre-flight Checklist" "$CANONICAL_SKILL"
  check_pattern_absent_in "Automated Deployment" "$CANONICAL_SKILL"
  check_pattern_absent_in "Post-Deployment Verification" "$CANONICAL_SKILL"
  check_pattern_absent_in "## Troubleshooting" "$CANONICAL_SKILL"

  echo "OK: deploy docs are not duplicated"
}

main "$@"
