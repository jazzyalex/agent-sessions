#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint for repo-local skills discovery.
# Canonical implementation lives under .agents/skills/review-skill/scripts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CANONICAL_SCRIPT="${REPO_ROOT}/.agents/skills/review-skill/scripts/codex_review_fix_loop.sh"

if [[ ! -f "$CANONICAL_SCRIPT" ]]; then
  echo "error: missing canonical script at $CANONICAL_SCRIPT" >&2
  exit 1
fi

exec "$CANONICAL_SCRIPT" "$@"
