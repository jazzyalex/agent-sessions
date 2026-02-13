#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint for repo-local skills discovery.
# Canonical implementation lives under .agents/skills/review-skill/scripts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
exec "${REPO_ROOT}/.agents/skills/review-skill/scripts/codex_review_fix_loop.sh" "$@"
