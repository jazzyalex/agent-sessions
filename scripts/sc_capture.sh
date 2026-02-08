#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Repo-level screenshot wrapper for SC skill.

Usage:
  $(basename "$0") <command> [args...]

Commands:
  preset   Apply deterministic window size/position preset
  capture  Capture one screenshot
  suite    Run manifest-driven batch capture
  help     Show this help

Examples:
  $(basename "$0") preset --app "AgentSessions" --preset marketing
  $(basename "$0") capture --app "AgentSessions" --mode testing --output artifacts/screenshots/main.png
  $(basename "$0") suite --manifest skills/sc-skill/references/examples/agent-sessions.tsv --outdir artifacts/screenshots
USAGE
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
skill_dir="$repo_root/skills/sc-skill/scripts"

require_script() {
  local file="$1"
  if [[ ! -x "$file" ]]; then
    echo "Missing executable script: $file" >&2
    echo "Ensure SC skill exists at skills/sc-skill." >&2
    exit 1
  fi
}

cmd="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$cmd" in
  preset)
    target="$skill_dir/sc_window_preset.sh"
    require_script "$target"
    exec "$target" "$@"
    ;;
  capture)
    target="$skill_dir/sc_capture.sh"
    require_script "$target"
    exec "$target" "$@"
    ;;
  suite)
    target="$skill_dir/sc_capture_suite.sh"
    require_script "$target"
    exec "$target" "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac
