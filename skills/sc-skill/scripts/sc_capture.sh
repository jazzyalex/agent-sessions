#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") --app <AppName> --output <path.png> [options]

Required:
  --app <name>             App name (e.g. "AgentSessions")
  --output <path.png>      Destination image path

Options:
  --mode testing|marketing Capture mode (default: testing)
  --tool auto|peekaboo|native  Tool selection (default: auto)
  --delay <seconds>        Minimum wait before capture readiness check (default: 0.25)
  --settle-timeout <sec>   Max wait for UI to settle (default: 2.0)
  --settle-poll <sec>      Poll interval for settle check (default: 0.25)
  --wait-settle            Force settle check on
  --no-wait-settle         Disable settle check and only use --delay
  --wait-agent-sessions-transcript    Retry capture until AgentSessions transcript is non-blank
  --no-wait-agent-sessions-transcript Disable AgentSessions transcript readiness retry
  --transcript-timeout <sec>          Max retry window for transcript readiness (default: 0.25)
  --transcript-poll <sec>             Delay between transcript retries (default: 0.25)
  --agent-sessions-selection-nudge    Send key down + pause to trigger transcript load (default: auto)
  --no-agent-sessions-selection-nudge Disable AgentSessions selection nudge
  --nudge-pause <sec>                 Pause after selection nudge (default: 0.5)
  --nudge-attempts <n>                Number of nudges before fail (default: 1)
  --allow-blank-transcript            Keep last capture even if transcript readiness fails
  --max-edge <px|auto>                Resize output so longest edge is <= px (default: auto)
  --no-resize                         Disable max-edge resizing
  --optimize-output                   Optimize/compress output image (default: on)
  --no-optimize-output                Disable output optimization
  --jpeg-quality <1-100>              JPEG/WebP quality when relevant (default: 84)
  --normalize-window                  Apply deterministic window preset before capture
  --no-normalize-window               Skip automatic window preset
  --window-preset testing|marketing|hero|auto
                                     Preset to apply when normalization is enabled (default: auto)
  --metadata                          Write sidecar metadata JSON (opt-in)
  --close-window           Close captured app window(s) after capture (default: on)
  --no-close-window        Keep app window(s) open after capture
  --no-activate            Skip app activation before capture
  --no-metadata            Disable sidecar metadata JSON
  --retina                 Request retina capture for Peekaboo
  --dry-run                Print chosen command without executing

Examples:
  $(basename "$0") --app "AgentSessions" --output artifacts/screenshots/main.png
  $(basename "$0") --app "AgentSessions" --mode marketing --tool native --output /tmp/shot.png
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

ceil_div_iterations() {
  local duration="${1:-0}"
  local interval="${2:-1}"
  awk -v d="$duration" -v i="$interval" 'BEGIN {
    if (i <= 0) { print 1; exit }
    n = int((d / i) + 0.999999)
    if (n < 1) n = 1
    print n
  }'
}

get_window_snapshot_signature() {
  local app_name="$1"
  osascript - "$app_name" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  tell application "System Events"
    if not (exists process appName) then return "__NO_PROCESS__"
    tell process appName
      if (count of windows) = 0 then return "__NO_WINDOW__"
      set w to window 1
      set p to position of w
      set s to size of w
      set wName to ""
      try
        set wName to name of w as text
      end try
      set progressCount to 0
      try
        set progressCount to count of (every UI element of w whose role is "AXProgressIndicator")
      on error
        set progressCount to 0
      end try
      return (item 1 of p as text) & "," & (item 2 of p as text) & ";" & (item 1 of s as text) & "x" & (item 2 of s as text) & ";p=" & (progressCount as text) & ";w=" & wName
    end tell
  end tell
end run
APPLESCRIPT
}

wait_for_window_settle() {
  local app_name="$1"
  local min_wait_s="$2"
  local timeout_s="$3"
  local poll_s="$4"
  local stable_required=3
  local total_iters min_wait_iters i
  local minimum_effective_timeout_s effective_timeout_s
  local initial_sig last_sig current_sig
  local stable_count=0
  local saw_change=0

  minimum_effective_timeout_s="$(awk -v m="$min_wait_s" -v p="$poll_s" -v s="$stable_required" 'BEGIN { print m + (p * s) }')"
  effective_timeout_s="$(awk -v t="$timeout_s" -v min="$minimum_effective_timeout_s" 'BEGIN { if (t > min) print t; else print min }')"
  total_iters="$(ceil_div_iterations "$effective_timeout_s" "$poll_s")"
  min_wait_iters="$(ceil_div_iterations "$min_wait_s" "$poll_s")"

  initial_sig="$(get_window_snapshot_signature "$app_name" 2>/dev/null || true)"
  if [[ -z "$initial_sig" || "$initial_sig" == "__NO_PROCESS__" || "$initial_sig" == "__NO_WINDOW__" ]]; then
    sleep "$min_wait_s"
    return 0
  fi
  last_sig="$initial_sig"

  for ((i = 1; i <= total_iters; i++)); do
    sleep "$poll_s"
    current_sig="$(get_window_snapshot_signature "$app_name" 2>/dev/null || true)"
    if [[ -z "$current_sig" || "$current_sig" == "__NO_PROCESS__" || "$current_sig" == "__NO_WINDOW__" ]]; then
      continue
    fi

    if [[ "$current_sig" == "$last_sig" ]]; then
      stable_count=$((stable_count + 1))
    else
      stable_count=0
      if [[ "$current_sig" != "$initial_sig" ]]; then
        saw_change=1
      fi
      last_sig="$current_sig"
    fi

    if (( i >= min_wait_iters && stable_count >= stable_required )); then
      # If content changed, wait until it re-stabilizes.
      # If it never changed, still allow capture once we observed sustained stability.
      if (( saw_change == 1 || i >= (min_wait_iters + stable_required) )); then
        return 0
      fi
    fi
  done

  return 0
}

resolve_python_with_pillow() {
  local candidates=()
  local py

  if [[ -x "$repo_root/.venv/bin/python" ]]; then
    candidates+=("$repo_root/.venv/bin/python")
  fi
  if command -v python3 >/dev/null 2>&1; then
    candidates+=("python3")
  fi

  for py in "${candidates[@]}"; do
    if "$py" - <<'PY' >/dev/null 2>&1
import PIL  # noqa: F401
PY
    then
      echo "$py"
      return 0
    fi
  done

  return 1
}

agent_sessions_transcript_non_blank() {
  local image_path="$1"
  local python_bin="$2"
  "$python_bin" - "$image_path" <<'PY' >/dev/null
from PIL import Image, ImageStat
import sys

path = sys.argv[1]
img = Image.open(path).convert("L")
w, h = img.size

# AgentSessions layout: transcript body is in the right pane.
# Use a centered sub-region to avoid top counters and edge overlap from other windows.
left = int(w * 0.56)
top = int(h * 0.40)
right = int(w * 0.88)
bottom = int(h * 0.94)

if left >= right or top >= bottom:
    raise SystemExit(1)

crop = img.crop((left, top, right, bottom))
stats = ImageStat.Stat(crop)

# Empty transcript body is near-white with minimal variance.
# Loaded transcript body has noticeably lower mean luminance and higher variance.
if stats.stddev[0] >= 8.0 or stats.mean[0] <= 252.0:
    raise SystemExit(0)

raise SystemExit(1)
PY
}

postprocess_image_with_python() {
  local image_path="$1"
  local python_bin="$2"
  local max_edge_px="$3"
  local optimize_flag="$4"
  local jpeg_quality="$5"

  "$python_bin" - "$image_path" "$max_edge_px" "$optimize_flag" "$jpeg_quality" <<'PY' >/dev/null
from pathlib import Path
from PIL import Image
import sys

path = Path(sys.argv[1])
max_edge = int(sys.argv[2])
optimize_output = sys.argv[3] == "true"
jpeg_quality = int(sys.argv[4])

img = Image.open(path)
w, h = img.size

if max_edge > 0:
    longest = max(w, h)
    if longest > max_edge:
        scale = max_edge / float(longest)
        new_w = max(1, int(round(w * scale)))
        new_h = max(1, int(round(h * scale)))
        resampling = getattr(Image, "Resampling", Image)
        img = img.resize((new_w, new_h), resampling.LANCZOS)

suffix = path.suffix.lower()
save_kwargs = {}

if suffix in (".jpg", ".jpeg"):
    if img.mode != "RGB":
        if img.mode in ("RGBA", "LA"):
            bg = Image.new("RGB", img.size, (255, 255, 255))
            alpha = img.split()[-1]
            bg.paste(img, mask=alpha)
            img = bg
        else:
            img = img.convert("RGB")
    save_kwargs["quality"] = jpeg_quality
    save_kwargs["progressive"] = True
    if optimize_output:
        save_kwargs["optimize"] = True
elif suffix == ".webp":
    save_kwargs["quality"] = jpeg_quality
    save_kwargs["method"] = 6
elif suffix == ".png":
    if optimize_output:
        save_kwargs["optimize"] = True
        save_kwargs["compress_level"] = 9

img.save(path, **save_kwargs)
PY
}

resolve_max_edge() {
  local mode_name="$1"
  local max_edge_setting="$2"
  if [[ "$max_edge_setting" == "auto" ]]; then
    case "$mode_name" in
      marketing) echo "2560" ;;
      testing) echo "1800" ;;
      *) echo "1800" ;;
    esac
  else
    echo "$max_edge_setting"
  fi
}

activate_app_frontmost() {
  local app_name="$1"
  osascript -e "tell application \"$app_name\" to activate" >/dev/null 2>&1 || true
  sleep 0.08
}

run_capture_command() {
  local app_name="$1"
  shift
  if [[ "$activate" == "true" ]]; then
    activate_app_frontmost "$app_name"
  fi
  "$@"
}

nudge_agent_sessions_selection() {
  local pause_s="$1"
  local bounds x y w h click_x click_y

  bounds="$(get_native_window_bounds "AgentSessions" 2>/dev/null || true)"
  if [[ -n "$bounds" ]]; then
    IFS=',' read -r x y w h <<< "$bounds"
    if [[ -n "${x:-}" && -n "${y:-}" && -n "${w:-}" && -n "${h:-}" ]] && command -v swift >/dev/null 2>&1; then
      click_x=$((x + w / 4))
      click_y=$((y + 120))
      swift -e 'import Cocoa
let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let p = CGPoint(x: x, y: y)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
' "$click_x" "$click_y" >/dev/null 2>&1 || true
      sleep 0.06
    fi
  fi

  osascript - <<'APPLESCRIPT' >/dev/null 2>&1
tell application "AgentSessions" to activate
delay 0.05
tell application "System Events"
  key code 125
end tell
APPLESCRIPT
  sleep "$pause_s"
}

close_app_windows() {
  local app_name="$1"
  osascript - "$app_name" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set appName to item 1 of argv
  tell application "System Events"
    if not (exists process appName) then return
  end tell

  tell application appName to activate
  delay 0.1

  repeat with i from 1 to 12
    tell application "System Events"
      if not (exists process appName) then return
      tell process appName
        if (count of windows) = 0 then return
      end tell
      keystroke "w" using {command down}
    end tell
    delay 0.12
  end repeat

  tell application "System Events"
    if not (exists process appName) then return
    tell process appName
      repeat with w in windows
        try
          close w
        end try
      end repeat
    end tell
  end tell
end run
APPLESCRIPT
}

apply_window_preset_if_needed() {
  local app_name="$1"
  local mode_name="$2"
  local normalize_setting="$3"
  local preset_setting="$4"
  local preset_to_use="$preset_setting"
  local preset_script="$script_dir/sc_window_preset.sh"

  if [[ "$normalize_setting" == "false" ]]; then
    return 0
  fi

  if [[ "$normalize_setting" == "auto" && "$app_name" != "AgentSessions" ]]; then
    return 0
  fi

  if [[ "$preset_to_use" == "auto" ]]; then
    case "$mode_name" in
      marketing) preset_to_use="marketing" ;;
      testing) preset_to_use="testing" ;;
      *) preset_to_use="testing" ;;
    esac
  fi

  if [[ ! -x "$preset_script" ]]; then
    return 0
  fi

  "$preset_script" --app "$app_name" --preset "$preset_to_use" >/dev/null 2>&1 || true
}

peekaboo_permissions_granted() {
  if ! command -v peekaboo >/dev/null 2>&1; then
    return 1
  fi
  local p
  p="$(peekaboo permissions 2>/dev/null || true)"
  [[ "$p" == *"Screen Recording (Required): Granted"* ]] && [[ "$p" == *"Accessibility (Required): Granted"* ]]
}

get_native_window_bounds() {
  local app_name="$1"
  osascript - "$app_name" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  tell application "System Events"
    if not (exists process appName) then error "Process not found: " & appName
    tell process appName
      set frontmost to true
      if (count of windows) = 0 then error "No windows for app: " & appName
      set p to position of window 1
      set s to size of window 1
      return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
    end tell
  end tell
end run
APPLESCRIPT
}

write_metadata() {
  local output_path="$1"
  local app_name="$2"
  local mode_name="$3"
  local tool_name="$4"
  local bounds="$5"

  command -v jq >/dev/null 2>&1 || return 0

  local os_version ts
  os_version="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  jq -n \
    --arg timestamp "$ts" \
    --arg app "$app_name" \
    --arg mode "$mode_name" \
    --arg tool "$tool_name" \
    --arg output "$output_path" \
    --arg bounds "$bounds" \
    --arg os_version "$os_version" \
    '{timestamp: $timestamp, app: $app, mode: $mode, tool: $tool, output: $output, bounds: $bounds, os_version: $os_version}' \
    > "${output_path}.json"
}

app=""
output=""
mode="testing"
tool="auto"
delay="0.25"
settle_timeout="2.0"
settle_poll="0.25"
wait_settle="auto"
wait_agent_sessions_transcript="auto"
transcript_timeout="0.25"
transcript_poll="0.25"
allow_blank_transcript="false"
max_edge="auto"
optimize_output="true"
jpeg_quality="84"
agent_sessions_selection_nudge="auto"
nudge_pause="0.5"
nudge_attempts="1"
normalize_window="auto"
window_preset="auto"
close_window="true"
activate="true"
metadata="false"
retina="false"
dry_run="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --tool) tool="${2:-}"; shift 2 ;;
    --delay) delay="${2:-}"; shift 2 ;;
    --settle-timeout) settle_timeout="${2:-}"; shift 2 ;;
    --settle-poll) settle_poll="${2:-}"; shift 2 ;;
    --wait-settle) wait_settle="true"; shift ;;
    --no-wait-settle) wait_settle="false"; shift ;;
    --wait-agent-sessions-transcript) wait_agent_sessions_transcript="true"; shift ;;
    --no-wait-agent-sessions-transcript) wait_agent_sessions_transcript="false"; shift ;;
    --transcript-timeout) transcript_timeout="${2:-}"; shift 2 ;;
    --transcript-poll) transcript_poll="${2:-}"; shift 2 ;;
    --agent-sessions-selection-nudge) agent_sessions_selection_nudge="true"; shift ;;
    --no-agent-sessions-selection-nudge) agent_sessions_selection_nudge="false"; shift ;;
    --nudge-pause) nudge_pause="${2:-}"; shift 2 ;;
    --nudge-attempts) nudge_attempts="${2:-}"; shift 2 ;;
    --allow-blank-transcript) allow_blank_transcript="true"; shift ;;
    --max-edge) max_edge="${2:-}"; shift 2 ;;
    --no-resize) max_edge="0"; shift ;;
    --optimize-output) optimize_output="true"; shift ;;
    --no-optimize-output) optimize_output="false"; shift ;;
    --jpeg-quality) jpeg_quality="${2:-}"; shift 2 ;;
    --normalize-window) normalize_window="true"; shift ;;
    --no-normalize-window) normalize_window="false"; shift ;;
    --window-preset) window_preset="${2:-}"; shift 2 ;;
    --metadata) metadata="true"; shift ;;
    --close-window) close_window="true"; shift ;;
    --no-close-window) close_window="false"; shift ;;
    --no-activate) activate="false"; shift ;;
    --no-metadata) metadata="false"; shift ;;
    --retina) retina="true"; shift ;;
    --dry-run) dry_run="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$app" || -z "$output" ]]; then
  echo "--app and --output are required" >&2
  usage
  exit 1
fi

case "$mode" in
  testing|marketing) ;;
  *) echo "Unsupported --mode: $mode" >&2; exit 1 ;;
esac

case "$tool" in
  auto|peekaboo|native) ;;
  *) echo "Unsupported --tool: $tool" >&2; exit 1 ;;
esac

if ! [[ "$max_edge" == "auto" || "$max_edge" =~ ^[0-9]+$ ]]; then
  echo "Invalid --max-edge (must be integer >= 0 or 'auto'): $max_edge" >&2
  exit 1
fi

if ! [[ "$jpeg_quality" =~ ^[0-9]+$ ]] || (( jpeg_quality < 1 || jpeg_quality > 100 )); then
  echo "Invalid --jpeg-quality (must be 1..100): $jpeg_quality" >&2
  exit 1
fi

case "$normalize_window" in
  true|false|auto) ;;
  *)
    echo "Invalid normalize-window setting: $normalize_window" >&2
    exit 1
    ;;
esac

case "$agent_sessions_selection_nudge" in
  true|false|auto) ;;
  *)
    echo "Invalid selection nudge mode: $agent_sessions_selection_nudge" >&2
    exit 1
    ;;
esac

if ! [[ "$nudge_attempts" =~ ^[0-9]+$ ]]; then
  echo "Invalid --nudge-attempts (must be integer >= 0): $nudge_attempts" >&2
  exit 1
fi

case "$wait_settle" in
  true|false|auto) ;;
  *)
    echo "Invalid settle mode: $wait_settle" >&2
    exit 1
    ;;
esac

case "$window_preset" in
  auto|testing|marketing|hero) ;;
  *)
    echo "Invalid --window-preset: $window_preset" >&2
    exit 1
    ;;
esac

if [[ "$tool" == "auto" ]]; then
  if peekaboo_permissions_granted; then
    tool="peekaboo"
  else
    tool="native"
  fi
fi

require_cmd osascript
require_cmd screencapture

mkdir -p "$(dirname "$output")"

if [[ "$activate" == "true" ]]; then
  open -a "$app"
  activate_app_frontmost "$app"
fi

apply_window_preset_if_needed "$app" "$mode" "$normalize_window" "$window_preset"

effective_wait_settle="$wait_settle"
if [[ "$effective_wait_settle" == "auto" ]]; then
  if [[ "$app" == "AgentSessions" ]]; then
    effective_wait_settle="false"
  else
    effective_wait_settle="true"
  fi
fi

if [[ "$effective_wait_settle" == "true" ]]; then
  wait_for_window_settle "$app" "$delay" "$settle_timeout" "$settle_poll"
else
  sleep "$delay"
fi

bounds=""
if [[ "$tool" == "peekaboo" ]]; then
  require_cmd peekaboo
  cmd=(peekaboo image --app "$app" --mode frontmost --path "$output")
  if [[ "$retina" == "true" ]]; then
    cmd+=(--retina)
  fi
else
  bounds="$(get_native_window_bounds "$app")"
  cmd=(screencapture -x -R "$bounds" "$output")
fi

if [[ "$dry_run" == "true" ]]; then
  printf 'Dry run: '
  printf '%q ' "${cmd[@]}"
  printf '\n'
  exit 0
fi

should_wait_transcript="false"
case "$wait_agent_sessions_transcript" in
  auto)
    if [[ "$app" == "AgentSessions" ]]; then
      should_wait_transcript="true"
    fi
    ;;
  true) should_wait_transcript="true" ;;
  false) should_wait_transcript="false" ;;
esac

if [[ "$should_wait_transcript" == "true" ]]; then
  python_bin="$(resolve_python_with_pillow || true)"
  if [[ -n "${python_bin:-}" ]]; then
    retries="$(ceil_div_iterations "$transcript_timeout" "$transcript_poll")"
    enable_nudge="false"
    if [[ "$app" == "AgentSessions" ]]; then
      case "$agent_sessions_selection_nudge" in
        true) enable_nudge="true" ;;
        auto) enable_nudge="true" ;;
      esac
    fi
    if [[ "$enable_nudge" == "true" ]]; then
      min_retries=$((nudge_attempts + 1))
      if (( retries < min_retries )); then
        retries="$min_retries"
      fi
    fi
    transcript_ready="false"
    for ((attempt = 1; attempt <= retries; attempt++)); do
      run_capture_command "$app" "${cmd[@]}"
      if agent_sessions_transcript_non_blank "$output" "$python_bin"; then
        transcript_ready="true"
        break
      fi
      if (( attempt < retries )); then
        if [[ "$enable_nudge" == "true" ]] && (( attempt <= nudge_attempts )); then
          nudge_agent_sessions_selection "$nudge_pause"
        else
          sleep "$transcript_poll"
        fi
      fi
    done
    if [[ "$transcript_ready" == "false" ]]; then
      if [[ "$allow_blank_transcript" == "true" ]]; then
        echo "Warning: transcript readiness timeout after ${transcript_timeout}s for app=$app; keeping last capture due to --allow-blank-transcript." >&2
      else
        echo "Error: transcript did not load within ${transcript_timeout}s for app=$app (likely missing session click/signal)." >&2
        rm -f "$output"
        exit 2
      fi
    fi
  else
    run_capture_command "$app" "${cmd[@]}"
    if [[ "$allow_blank_transcript" != "true" ]]; then
      echo "Error: transcript readiness check requested but Pillow is unavailable." >&2
      exit 2
    fi
  fi
else
  run_capture_command "$app" "${cmd[@]}"
fi

effective_max_edge="$(resolve_max_edge "$mode" "$max_edge")"
if [[ "$effective_max_edge" != "0" || "$optimize_output" == "true" ]]; then
  python_bin_post="$(resolve_python_with_pillow || true)"
  if [[ -n "${python_bin_post:-}" ]]; then
    postprocess_image_with_python "$output" "$python_bin_post" "$effective_max_edge" "$optimize_output" "$jpeg_quality" || true
  elif [[ "$effective_max_edge" != "0" ]] && command -v sips >/dev/null 2>&1; then
    sips -Z "$effective_max_edge" "$output" >/dev/null 2>&1 || true
  fi
fi

if [[ "$metadata" == "true" ]]; then
  write_metadata "$output" "$app" "$mode" "$tool" "$bounds"
fi

if [[ "$close_window" == "true" ]]; then
  close_app_windows "$app"
fi

echo "Capture complete: $output (mode=$mode tool=$tool)"
