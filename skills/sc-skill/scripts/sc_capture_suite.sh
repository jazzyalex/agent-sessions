#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") --manifest <file.tsv> --outdir <directory> [options]

Manifest format (tab-separated):
  name<TAB>app<TAB>preset<TAB>mode

Lines starting with # are ignored.

Options:
  --tool auto|peekaboo|native  Capture tool (default: auto)
  --delay <seconds>            Forwarded to sc_capture.sh (default: 0.25)
  --settle-timeout <seconds>   Forwarded to sc_capture.sh (default: 2.0)
  --settle-poll <seconds>      Forwarded to sc_capture.sh (default: 0.25)
  --wait-settle                      Forwarded to sc_capture.sh
  --no-wait-settle                   Forwarded to sc_capture.sh
  --wait-agent-sessions-transcript    Forwarded to sc_capture.sh
  --no-wait-agent-sessions-transcript Forwarded to sc_capture.sh
  --agent-sessions-selection-nudge    Forwarded to sc_capture.sh (default: auto)
  --no-agent-sessions-selection-nudge Forwarded to sc_capture.sh
  --nudge-pause <seconds>             Forwarded to sc_capture.sh (default: 0.5)
  --nudge-attempts <n>                Forwarded to sc_capture.sh (default: 1)
  --allow-blank-transcript            Forwarded to sc_capture.sh
  --transcript-timeout <seconds>      Forwarded to sc_capture.sh (default: 0.25)
  --transcript-poll <seconds>         Forwarded to sc_capture.sh (default: 0.25)
  --max-edge <px|auto>                Forwarded to sc_capture.sh (default: auto)
  --no-resize                         Forwarded to sc_capture.sh
  --optimize-output                   Forwarded to sc_capture.sh (default: on)
  --no-optimize-output                Forwarded to sc_capture.sh
  --jpeg-quality <1-100>              Forwarded to sc_capture.sh (default: 84)
  --normalize-window                  Forwarded to sc_capture.sh
  --no-normalize-window               Forwarded to sc_capture.sh
  --window-preset testing|marketing|hero|auto Forwarded to sc_capture.sh (default: auto)
  --metadata                          Forwarded to sc_capture.sh (opt-in)
  --no-metadata                       Forwarded to sc_capture.sh (default)
  --close-after-suite          Close captured app windows at end (default)
  --no-close-after-suite       Leave app windows open

Example:
  $(basename "$0") --manifest skills/sc-skill/references/examples/agent-sessions.tsv --outdir artifacts/screenshots
USAGE
}

manifest=""
outdir=""
tool="auto"
delay="0.25"
settle_timeout="2.0"
settle_poll="0.25"
wait_settle="auto"
wait_agent_sessions_transcript="auto"
agent_sessions_selection_nudge="auto"
nudge_pause="0.5"
nudge_attempts="1"
allow_blank_transcript="false"
transcript_timeout="0.25"
transcript_poll="0.25"
max_edge="auto"
optimize_output="true"
jpeg_quality="84"
normalize_window="auto"
window_preset="auto"
metadata="false"
close_after_suite="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) manifest="${2:-}"; shift 2 ;;
    --outdir) outdir="${2:-}"; shift 2 ;;
    --tool) tool="${2:-}"; shift 2 ;;
    --delay) delay="${2:-}"; shift 2 ;;
    --settle-timeout) settle_timeout="${2:-}"; shift 2 ;;
    --settle-poll) settle_poll="${2:-}"; shift 2 ;;
    --wait-settle) wait_settle="true"; shift ;;
    --no-wait-settle) wait_settle="false"; shift ;;
    --wait-agent-sessions-transcript) wait_agent_sessions_transcript="true"; shift ;;
    --no-wait-agent-sessions-transcript) wait_agent_sessions_transcript="false"; shift ;;
    --agent-sessions-selection-nudge) agent_sessions_selection_nudge="true"; shift ;;
    --no-agent-sessions-selection-nudge) agent_sessions_selection_nudge="false"; shift ;;
    --nudge-pause) nudge_pause="${2:-}"; shift 2 ;;
    --nudge-attempts) nudge_attempts="${2:-}"; shift 2 ;;
    --allow-blank-transcript) allow_blank_transcript="true"; shift ;;
    --transcript-timeout) transcript_timeout="${2:-}"; shift 2 ;;
    --transcript-poll) transcript_poll="${2:-}"; shift 2 ;;
    --max-edge) max_edge="${2:-}"; shift 2 ;;
    --no-resize) max_edge="0"; shift ;;
    --optimize-output) optimize_output="true"; shift ;;
    --no-optimize-output) optimize_output="false"; shift ;;
    --jpeg-quality) jpeg_quality="${2:-}"; shift 2 ;;
    --normalize-window) normalize_window="true"; shift ;;
    --no-normalize-window) normalize_window="false"; shift ;;
    --window-preset) window_preset="${2:-}"; shift 2 ;;
    --metadata) metadata="true"; shift ;;
    --no-metadata) metadata="false"; shift ;;
    --close-after-suite) close_after_suite="true"; shift ;;
    --no-close-after-suite) close_after_suite="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$manifest" || -z "$outdir" ]]; then
  echo "--manifest and --outdir are required" >&2
  usage
  exit 1
fi

if [[ ! -f "$manifest" ]]; then
  echo "Manifest not found: $manifest" >&2
  exit 1
fi

mkdir -p "$outdir"

script_dir="$(cd "$(dirname "$0")" && pwd)"
captured_apps=()

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

add_captured_app() {
  local app_name="$1"
  local existing
  for existing in "${captured_apps[@]-}"; do
    [[ -z "$existing" ]] && continue
    if [[ "$existing" == "$app_name" ]]; then
      return 0
    fi
  done
  captured_apps+=("$app_name")
}

while IFS=$'\t' read -r name app preset mode; do
  [[ -z "${name:-}" ]] && continue
  [[ "${name:0:1}" == "#" ]] && continue

  if [[ -z "${app:-}" || -z "${preset:-}" || -z "${mode:-}" ]]; then
    echo "Skipping invalid line (expected 4 TSV fields): $name $app $preset $mode" >&2
    continue
  fi

  "$script_dir/sc_window_preset.sh" --app "$app" --preset "$preset"

  transcript_wait_flag=""
  if [[ "$wait_agent_sessions_transcript" == "true" ]]; then
    transcript_wait_flag="--wait-agent-sessions-transcript"
  elif [[ "$wait_agent_sessions_transcript" == "false" ]]; then
    transcript_wait_flag="--no-wait-agent-sessions-transcript"
  fi

  selection_nudge_flag=""
  if [[ "$agent_sessions_selection_nudge" == "true" ]]; then
    selection_nudge_flag="--agent-sessions-selection-nudge"
  elif [[ "$agent_sessions_selection_nudge" == "false" ]]; then
    selection_nudge_flag="--no-agent-sessions-selection-nudge"
  fi

  allow_blank_flag=""
  if [[ "$allow_blank_transcript" == "true" ]]; then
    allow_blank_flag="--allow-blank-transcript"
  fi

  resize_flag=""
  if [[ "$max_edge" == "0" ]]; then
    resize_flag="--no-resize"
  fi

  optimize_flag=""
  if [[ "$optimize_output" == "false" ]]; then
    optimize_flag="--no-optimize-output"
  fi

  settle_flag=""
  case "$wait_settle" in
    true) settle_flag="--wait-settle" ;;
    false) settle_flag="--no-wait-settle" ;;
  esac

  normalize_window_flag=""
  case "$normalize_window" in
    true) normalize_window_flag="--normalize-window" ;;
    false) normalize_window_flag="--no-normalize-window" ;;
  esac

  metadata_flag=""
  if [[ "$metadata" == "true" ]]; then
    metadata_flag="--metadata"
  else
    metadata_flag="--no-metadata"
  fi

  # Preserve manifest determinism: if suite-level preset is not explicitly
  # overridden, pass the row preset through to sc_capture.sh so its
  # normalization step cannot remap from mode (e.g. hero + testing).
  effective_window_preset="$window_preset"
  if [[ "$effective_window_preset" == "auto" ]]; then
    effective_window_preset="$preset"
  fi

  capture_args=(
    --app "$app"
    --mode "$mode"
    --tool "$tool"
    --delay "$delay"
    --settle-timeout "$settle_timeout"
    --settle-poll "$settle_poll"
    --transcript-timeout "$transcript_timeout"
    --transcript-poll "$transcript_poll"
    --nudge-pause "$nudge_pause"
    --nudge-attempts "$nudge_attempts"
    --max-edge "$max_edge"
    --jpeg-quality "$jpeg_quality"
    --window-preset "$effective_window_preset"
    "$metadata_flag"
    --no-close-window
    --output "$outdir/${name}.png"
  )

  if [[ -n "$transcript_wait_flag" ]]; then
    capture_args+=("$transcript_wait_flag")
  fi
  if [[ -n "$allow_blank_flag" ]]; then
    capture_args+=("$allow_blank_flag")
  fi
  if [[ -n "$selection_nudge_flag" ]]; then
    capture_args+=("$selection_nudge_flag")
  fi
  if [[ -n "$resize_flag" ]]; then
    capture_args+=("$resize_flag")
  fi
  if [[ -n "$optimize_flag" ]]; then
    capture_args+=("$optimize_flag")
  fi
  if [[ -n "$settle_flag" ]]; then
    capture_args+=("$settle_flag")
  fi
  if [[ -n "$normalize_window_flag" ]]; then
    capture_args+=("$normalize_window_flag")
  fi

  "$script_dir/sc_capture.sh" "${capture_args[@]}"
  add_captured_app "$app"
done < "$manifest"

if [[ "$close_after_suite" == "true" ]]; then
  for app_name in "${captured_apps[@]-}"; do
    [[ -z "$app_name" ]] && continue
    close_app_windows "$app_name"
  done
fi

echo "Suite capture complete: $outdir"
