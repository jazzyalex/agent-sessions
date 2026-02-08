#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-/Applications/AgentSessions.app}"
OUT_DIR="${2:-scripts/energy_samples}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

timestamp() { date +%Y%m%d-%H%M%S; }

activate_app() {
  /usr/bin/osascript >/dev/null <<'OSA' || return 1
tell application "AgentSessions" to activate
OSA
}

keystroke() {
  local key="$1"
  local mods="$2"
  /usr/bin/osascript >/dev/null <<OSA || return 1
tell application "System Events" to keystroke "${key}" using ${mods}
OSA
}

type_text() {
  local text="$1"
  /usr/bin/osascript >/dev/null <<OSA || return 1
tell application "System Events" to keystroke "${text}"
OSA
}

sample_pid() {
  local pid="$1"
  local seconds="$2"
  local label="$3"
  local ts
  ts="$(timestamp)"
  local out="${OUT_DIR}/sample-${label}-${pid}-${ts}.txt"
  echo "Sampling ${seconds}s -> ${out}"
  /usr/bin/sample "$pid" "$seconds" -file "$out" >/dev/null 2>&1 || true
}

echo "Launching: $APP_PATH"
open -n "$APP_PATH"

echo "Waiting for pid..."
pid=""
for _ in {1..40}; do
  # Prefer the newest instance when multiple AgentSessions processes exist.
  pid="$(pgrep -nx AgentSessions || true)"
  if [[ -n "$pid" ]]; then break; fi
  sleep 0.25
done
if [[ -z "$pid" ]]; then
  echo "Could not find AgentSessions pid" >&2
  exit 1
fi
echo "pid=$pid"

# Always take a baseline sample.
sample_pid "$pid" 10 "baseline"

# Start threshold watcher in background (best-effort).
./scripts/cpu_sample_watch.sh --pid "$pid" --threshold 25 --consecutive 6 --sample 20 --cooldown 60 --out "$OUT_DIR" >/dev/null 2>&1 &
watcher_pid="$!"
echo "watcher_pid=$watcher_pid"

# Try to drive refresh + search with keyboard shortcuts. This requires Accessibility.
can_drive=1
if ! activate_app; then
  can_drive=0
fi

if [[ "$can_drive" -eq 1 ]]; then
  # Refresh (Cmd+R)
  if ! keystroke "r" "{command down}"; then
    can_drive=0
  fi
fi

if [[ "$can_drive" -eq 1 ]]; then
  sleep 3
  sample_pid "$pid" 20 "after-refresh"

  # Open Search Sessions (Cmd+Opt+F), type query, press Return.
  if keystroke "f" "{command down, option down}"; then
    sleep 0.4
    type_text "git" || true
    sleep 0.2
    keystroke return "{}" || true
  fi

  sleep 3
  sample_pid "$pid" 20 "after-search"

  # Background the app by activating Finder.
  /usr/bin/osascript >/dev/null <<'OSA' || true
tell application "Finder" to activate
OSA

  sleep 8
  sample_pid "$pid" 20 "background"
else
  echo "Note: UI driving via AppleScript failed (likely missing Accessibility permission). Captured baseline sample only."
fi

# Stop watcher.
kill "$watcher_pid" >/dev/null 2>&1 || true

echo "Done. Samples in: $OUT_DIR"
