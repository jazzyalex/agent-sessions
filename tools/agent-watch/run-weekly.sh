#!/usr/bin/env bash
# The weekly agent-format drift scan, wrapped for launchd.
#
# Two things this wrapper exists for:
#   1. agent_watch.py resolves its config, the support matrix, and report_root
#      as paths relative to CWD, so it must run from the repo root.
#   2. GitHub's unauthenticated API rate limit is low enough to fail an
#      unattended run across nine agents. A token is resolved at run time from
#      the gh CLI rather than baked into the plist, so no secret is written to
#      disk.
#
# The token is exported into agent_watch.py's own process only. It reaches the
# GitHub API through a 0600 curl config file (never process arguments), and
# agent_watch.py strips GITHUB_TOKEN/GH_TOKEN from every command it spawns, so
# no monitored agent CLI inherits it. See scripts/agent_watch.py `_child_env`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
cd "$REPO_ROOT"

if [ -z "${GITHUB_TOKEN:-}" ] && [ -z "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  token="$(gh auth token 2>/dev/null || true)"
  [ -n "$token" ] && export GITHUB_TOKEN="$token"
fi

echo "=== agent-watch weekly $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
# Weekly mode exits 0 even when it finds drift — severity lives in the report,
# not the exit status. Don't add `|| exit 1` expecting launchd to flag anything.
exec ./scripts/agent_watch.py --mode weekly "$@"
