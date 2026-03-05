#!/usr/bin/env bash
set -euo pipefail

GLOBAL_SKILL_ROOT="${CODEX_HOME:-$HOME/.codex}/skills/review-skill"
GLOBAL_SCRIPT="${GLOBAL_SKILL_ROOT}/scripts/codex_review_fix_loop.sh"

if [[ ! -f "${GLOBAL_SCRIPT}" ]]; then
  cat >&2 <<EOF
error: missing global review loop script:
  ${GLOBAL_SCRIPT}

Install or refresh it from:
  /Users/alexm/Repository/Skills/skills/sync_to_global.sh --skill review-skill

Then restart Codex.
EOF
  exit 1
fi

exec "${GLOBAL_SCRIPT}" "$@"
