#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root (works even if invoked from subdir)
if command -v git >/dev/null 2>&1; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
else
  REPO_ROOT="$(pwd)"
fi

exec "${REPO_ROOT}/.agents/skills/review-skill/scripts/codex_review_fix_loop.sh" "$@"
