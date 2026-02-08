#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") --app <AppName> [--preset testing|marketing|hero] [--x N --y N --width N --height N]

Examples:
  $(basename "$0") --app "AgentSessions" --preset testing
  $(basename "$0") --app "AgentSessions" --x 120 --y 100 --width 1600 --height 1000
USAGE
}

app=""
preset="testing"
x=""
y=""
width=""
height=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    --preset) preset="${2:-}"; shift 2 ;;
    --x) x="${2:-}"; shift 2 ;;
    --y) y="${2:-}"; shift 2 ;;
    --width) width="${2:-}"; shift 2 ;;
    --height) height="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$app" ]]; then
  echo "--app is required" >&2
  usage
  exit 1
fi

if [[ -z "$x" || -z "$y" || -z "$width" || -z "$height" ]]; then
  case "$preset" in
    testing)
      x=100; y=80; width=1360; height=900
      ;;
    marketing)
      x=120; y=90; width=1554; height=1020
      ;;
    hero)
      x=80; y=60; width=1728; height=1117
      ;;
    *)
      echo "Unsupported preset: $preset" >&2
      exit 1
      ;;
  esac
fi

open -a "$app"
osascript -e "tell application \"$app\" to activate" >/dev/null
sleep 0.25

osascript - "$app" "$x" "$y" "$width" "$height" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  set xPos to (item 2 of argv) as integer
  set yPos to (item 3 of argv) as integer
  set w to (item 4 of argv) as integer
  set h to (item 5 of argv) as integer

  tell application "System Events"
    if not (exists process appName) then error "Process not found: " & appName
    tell process appName
      set frontmost to true
      if (count of windows) = 0 then error "No windows for app: " & appName
      set position of window 1 to {xPos, yPos}
      set size of window 1 to {w, h}
    end tell
  end tell
end run
APPLESCRIPT

echo "Window preset applied: app=$app x=$x y=$y width=$width height=$height"
