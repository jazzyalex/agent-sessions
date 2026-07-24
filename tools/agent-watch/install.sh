#!/usr/bin/env bash
# install.sh                       — install the weekly agent-format drift scan
#                                    as a LaunchAgent (Mondays, 09:00 local).
# install.sh --render-only <dest>  — just render the plist (test hook).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.agentsessions.agent-watch"

render() { # dest
  local dest="$1" tmpl="$HERE/$LABEL.plist.template"
  # launchd runs with a bare PATH. agent_watch.py shells out to python3, curl,
  # gh, and every agent CLI it checks — several of which live in ~/.local/bin,
  # /opt/homebrew/bin, or a node prefix that is not on the default PATH. Bake
  # whatever resolves right now into the plist, or the scheduled run reports a
  # missing binary as drift.
  # `|| true` per lookup: most machines are missing at least one agent CLI, and
  # under `set -e` a single miss would abort the render.
  local bindirs
  bindirs="$(for c in python3 curl gh codex claude opencode openclaw hermes copilot cursor pi antigravity; do
               command -v "$c" 2>/dev/null || true
             done | xargs -n1 dirname 2>/dev/null | awk '!seen[$0]++' | paste -sd: -)"
  local pathval="${bindirs:+$bindirs:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  sed -e "s#__RUN_WEEKLY_SH__#$HERE/run-weekly.sh#g" \
      -e "s#__HOME__#$HOME#g" \
      -e "s#__OUT_ROOT__#$HERE/out#g" \
      -e "s#__PATH__#$pathval#g" "$tmpl" > "$dest"
}

if [ "${1:-}" = "--render-only" ]; then render "${2:?dest required}"; exit 0; fi

command -v python3 >/dev/null 2>&1 || { echo "python3 not found — agent_watch.py needs it."; exit 1; }
command -v gh >/dev/null 2>&1 || echo "note: gh not found. The scan still runs, but unauthenticated GitHub API limits may truncate the release watch."
mkdir -p "$HERE/out"

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
render "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Runs Mondays 09:00 local (missed runs fire on the next wake)."
echo "Run it now:      launchctl kickstart -k gui/\$(id -u)/$LABEL"
echo "Latest report:   ls -dt scripts/probe_scan_output/agent_watch/*/report.json | head -1"
echo "launchd log:     $HERE/out/launchd.log"
