#!/usr/bin/env bash
# capture_analytics_screenshot.sh
# Opens the AgentSessions Analytics window and captures a window-only screenshot
# Output: docs/screenshots/analytics-YYYYmmdd-HHMMSS.png (or OUT path)

set -euo pipefail

# Configurable defaults
OUTDIR="${OUTDIR:-$(pwd)/docs/screenshots}"
X_DEFAULT=${X_DEFAULT:-200}
Y_DEFAULT=${Y_DEFAULT:-120}
W_DEFAULT=${W_DEFAULT:-1100}
H_DEFAULT=${H_DEFAULT:-900}

mkdir -p "$OUTDIR"

# Resolve app path from DerivedData, allow override via APP
if [[ -z "${APP:-}" ]]; then
  APP="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/AgentSessions-*/Build/Products/Debug/AgentSessions.app 2>/dev/null | tail -n1 || true)"
fi

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "ERROR: AgentSessions.app not found in DerivedData. Set APP=/path/to/AgentSessions.app" >&2
  exit 2
fi

# Read bundle metadata
PLIST="$APP/Contents/Info.plist"
APP_NAME="$({ /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST" 2>/dev/null || true; } | sed -e 's/^\s\+//' -e 's/\s\+$//')"
[[ -z "$APP_NAME" ]] && APP_NAME="AgentSessions"
BUNDLE_ID="$({ /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true; } | tr -d '\r')"

# Launch
open -a "$APP" || true
sleep 1.0

# AppleScript: activate app, open Analytics, position window, return window ID
WIN_INFO=$(osascript <<OSA
try
  if "${BUNDLE_ID}" is not "" then
    tell application id "${BUNDLE_ID}" to activate
  else
    tell application "${APP_NAME}" to activate
  end if
  delay 0.6
  tell application "System Events"
    set procName to "${APP_NAME}"
    if not (exists process procName) then
      if exists process "Agent Sessions" then set procName to "Agent Sessions"
      if exists process "AgentSessions" then set procName to "AgentSessions"
    end if
    if exists process procName then
      tell process procName
        try
          click menu item "Analytics" of menu "Window" of menu bar 1
        end try
        delay 0.5
        try
          keystroke "k" using {command down}
        end try
        delay 0.8
        set p to {${X_DEFAULT}, ${Y_DEFAULT}}
        set s to {${W_DEFAULT}, ${H_DEFAULT}}
        try
          set position of front window to p
          set size of front window to s
        end try
        delay 0.3
        -- Get window title for matching
        set winTitle to ""
        try
          set winTitle to name of front window
        end try
        set p2 to position of front window
        set s2 to size of front window
        return (item 1 of p2 as string) & "," & (item 2 of p2 as string) & "," & (item 1 of s2 as string) & "," & (item 2 of s2 as string) & "," & winTitle
      end tell
    end if
  end tell
on error msg
  return ""
end try
OSA
)

if [[ -z "$WIN_INFO" ]]; then
  echo "ERROR: Could not obtain Analytics window info via Accessibility." >&2
  exit 3
fi

IFS=',' read -r X Y W H WIN_TITLE <<<"$WIN_INFO"

# Final activation and focus - critical for window capture
osascript <<OSA2 >/dev/null 2>&1 || true
try
  if "${BUNDLE_ID}" is not "" then
    tell application id "${BUNDLE_ID}" to activate
  else
    tell application "${APP_NAME}" to activate
  end if
  delay 0.3
  tell application "System Events"
    set procName to "${APP_NAME}"
    if not (exists process procName) then
      if exists process "Agent Sessions" then set procName to "Agent Sessions"
      if exists process "AgentSessions" then set procName to "AgentSessions"
    end if
    if exists process procName then
      tell process procName
        set frontmost to true
        delay 0.2
      end tell
    end if
  end tell
end try
OSA2

# Critical: wait for window compositor to settle
sleep 1.2

# Get display scale (backing factor)
SCALE=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.mainScreen; s ? s.backingScaleFactor : 2.0' 2>/dev/null || echo 2.0)

# Convert points->pixels (rounded)
PX=$(python3 - <<PY
x=$X; s=$SCALE
print(int(round(x*s)))
PY
)
PY=$(python3 - <<PY
y=$Y; s=$SCALE
print(int(round(y*s)))
PY
)
PW=$(python3 - <<PY
w=$W; s=$SCALE
print(int(round(w*s)))
PY
)
PH=$(python3 - <<PY
h=$H; s=$SCALE
print(int(round(h*s)))
PY
)

OUT="${OUT:-$OUTDIR/analytics-$(date +%Y%m%d-%H%M%S).png}"

# Get CGWindowID using Python and Quartz framework
# This gets the actual window server ID that screencapture needs
WINDOW_ID=$(python3 - <<PYWIN
import sys
try:
    import Quartz
    # Get all windows
    window_list = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID
    )

    # Find AgentSessions Analytics window
    for window in window_list:
        owner = window.get(Quartz.kCGWindowOwnerName, '')
        name = window.get(Quartz.kCGWindowName, '')
        layer = window.get(Quartz.kCGWindowLayer, -1)
        window_id = window.get(Quartz.kCGWindowNumber, 0)

        # Match by owner name and window name
        if ('AgentSessions' in owner or 'Agent Sessions' in owner):
            if 'Analytics' in name and layer == 0:
                print(window_id)
                sys.exit(0)

    # Fallback: just get first window from AgentSessions
    for window in window_list:
        owner = window.get(Quartz.kCGWindowOwnerName, '')
        layer = window.get(Quartz.kCGWindowLayer, -1)
        window_id = window.get(Quartz.kCGWindowNumber, 0)

        if ('AgentSessions' in owner or 'Agent Sessions' in owner) and layer == 0:
            print(window_id)
            sys.exit(0)

except Exception as e:
    print('', file=sys.stderr)
    pass
PYWIN
)

if [[ -n "$WINDOW_ID" && "$WINDOW_ID" != "" ]]; then
  # Capture specific window by ID - this captures the window content only, no desktop
  screencapture -x -l "$WINDOW_ID" -o "$OUT" || {
    echo "Warning: Window capture failed, falling back to region capture" >&2
    screencapture -x -R "$PX,$PY,$PW,$PH" "$OUT" || true
  }
else
  # Fallback to rectangle capture if we couldn't get window ID
  echo "Warning: Could not find window ID, falling back to region capture" >&2
  screencapture -x -R "$PX,$PY,$PW,$PH" "$OUT" || true
fi

if [[ -f "$OUT" ]]; then
  echo "Saved: $OUT"
else
  echo "ERROR: screencapture failed. Check Screen Recording and Accessibility permissions for terminal." >&2
  exit 4
fi
