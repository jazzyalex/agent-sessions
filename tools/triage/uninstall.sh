#!/usr/bin/env bash
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.agentsessions.triage.plist"
launchctl bootout "gui/$(id -u)/com.agentsessions.triage" 2>/dev/null || true
rm -f "$PLIST"
echo "Uninstalled com.agentsessions.triage."
