#!/usr/bin/env bash
# install.sh            — check deps, verify notifications, run the confinement
#                         gate, install a daily 08:00 LaunchAgent.
# install.sh --render-only <dest>  — just render the plist (test hook).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

render() { # dest
  local dest="$1" tmpl="$HERE/com.agentsessions.triage.plist.template"
  sed -e "s#__TRIAGE_SH__#$HERE/triage.sh#g" \
      -e "s#__HOME__#$HOME#g" \
      -e "s#__OUT_ROOT__#$HERE/out#g" "$tmpl" > "$dest"
}

if [ "${1:-}" = "--render-only" ]; then render "${2:?dest required}"; exit 0; fi

require_cmd jq     || { echo "Install jq first:  brew install jq"; exit 1; }
require_cmd gh     || { echo "Install gh first:  brew install gh   (and: gh auth login)"; exit 1; }
require_cmd claude || { echo "Install the claude CLI first"; exit 1; }
mkdir -p "$HERE/out"

echo "Notification permission check…"
bash "$HERE/lib/notify.sh" "Repo triage" "Install test — if you see this, notifications work."
echo "  (no banner? grant osascript notification permission in System Settings › Notifications)"

echo "Running the agent-confinement gate against the real claude CLI…"
bash "$HERE/tests/test_confinement.sh"

PLIST="$HOME/Library/LaunchAgents/com.agentsessions.triage.plist"
render "$PLIST"
launchctl bootout "gui/$(id -u)/com.agentsessions.triage" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Runs daily 08:00 local."
echo "Review a run:  open \$(ls -dt $HERE/out/*/digest.md | head -1)"
