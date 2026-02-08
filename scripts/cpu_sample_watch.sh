#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
cpu_sample_watch.sh

Watches CPU usage for a process and captures a macOS `sample` when it stays high.

Usage:
  ./scripts/cpu_sample_watch.sh --name AgentSessions
  ./scripts/cpu_sample_watch.sh --pid 12345

Options:
  --name NAME            process name (exact match; uses `pgrep -x`)
  --pid PID              process id
  --threshold CPU        trigger threshold (default: 60.0)
  --consecutive SECONDS  seconds above threshold to trigger (default: 8)
  --sample SECONDS       sample duration (default: 25)
  --interval SECONDS     poll interval (default: 1)
  --cooldown SECONDS     minimum seconds between samples (default: 600)
  --out DIR              output directory (default: scripts/energy_samples)

Notes:
  - Requires: /usr/bin/sample
  - Produces: DIR/sample-<name>-<pid>-<timestamp>.txt
EOF
}

name=""
pid=""
threshold="60.0"
consecutive="8"
sample_seconds="25"
interval="1"
cooldown="600"
out_dir="scripts/energy_samples"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name="${2:-}"; shift 2 ;;
    --pid) pid="${2:-}"; shift 2 ;;
    --threshold) threshold="${2:-}"; shift 2 ;;
    --consecutive) consecutive="${2:-}"; shift 2 ;;
    --sample) sample_seconds="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --cooldown) cooldown="${2:-}"; shift 2 ;;
    --out) out_dir="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$pid" ]]; then
  if [[ -z "$name" ]]; then
    echo "Provide --pid or --name" >&2
    usage
    exit 2
  fi
  pid="$(pgrep -x "$name" | head -n 1 || true)"
  if [[ -z "$pid" ]]; then
    echo "Process not found: $name" >&2
    exit 1
  fi
else
  if ! ps -p "$pid" >/dev/null 2>&1; then
    echo "PID not running: $pid" >&2
    exit 1
  fi
  if [[ -z "$name" ]]; then
    name="$(ps -p "$pid" -o comm= | awk '{print $1}')"
  fi
fi

mkdir -p "$out_dir"

above=0
last_sample_at=0

echo "Watching pid=$pid name=$name threshold=$threshold consecutive=$consecutive sample=${sample_seconds}s out=$out_dir"

while ps -p "$pid" >/dev/null 2>&1; do
  cpu="$(ps -p "$pid" -o %cpu= | tr -d ' ' || true)"
  cpu="${cpu:-0}"

  if awk -v a="$cpu" -v b="$threshold" 'BEGIN { exit !(a >= b) }'; then
    above=$((above + interval))
  else
    above=0
  fi

  now="$(date +%s)"
  if [[ "$above" -ge "$consecutive" ]] && [[ $((now - last_sample_at)) -ge "$cooldown" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    out_file="${out_dir}/sample-${name}-${pid}-${ts}.txt"
    echo "CPU ${cpu}% sustained for ${above}s; capturing ${sample_seconds}s sample -> ${out_file}"
    /usr/bin/sample "$pid" "$sample_seconds" -file "$out_file" >/dev/null 2>&1 || true
    last_sample_at="$now"
    above=0
  fi

  sleep "$interval"
done

echo "Process exited: pid=$pid"

