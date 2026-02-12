#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint for repo-local skills discovery.
# Canonical implementation lives under .agents/skills/review-skill/scripts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/.agents/skills/review-skill/scripts/codex_review_fix_loop.sh"
PATCHED_SCRIPT="${TMPDIR:-/tmp}/codex_review_fix_loop.patched.$$.$RANDOM.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to launch patched review loop wrapper." >&2
  exit 2
fi

python3 - "$SOURCE_SCRIPT" "$PATCHED_SCRIPT" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
patched_path = Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8", errors="ignore")

def must_replace(old: str, new: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"missing expected pattern:\\n{old[:120]}")
    text = text.replace(old, new, 1)

must_replace(
    """LAST_EFFECTIVE_REVIEW_EFFORT=""
LAST_EFFECTIVE_FIX_EFFORT=""
LAUNCH_CHILD_PID=""
LAUNCH_ISOLATED="0"
""",
    """LAST_EFFECTIVE_REVIEW_EFFORT=""
LAST_EFFECTIVE_FIX_EFFORT=""
LAUNCH_CHILD_PID=""
LAUNCH_ISOLATED="0"
LAUNCH_CHILD_PGID=""
""",
)

must_replace(
    """in_file, out_file = sys.argv[1], sys.argv[2]
text = open(in_file, "r", encoding="utf-8", errors="ignore").read()

items = []
""",
    """in_file, out_file = sys.argv[1], sys.argv[2]
text = open(in_file, "r", encoding="utf-8", errors="ignore").read()

def final_review_region(raw: str) -> str:
    # Prefer the last structured findings payload from the final review verdict.
    matches = list(re.finditer(r'\\{\\s*"findings"\\s*:', raw))
    if matches:
        return raw[matches[-1].start():]

    # Otherwise, focus on trailing output to avoid stale intermediate titles.
    lines = raw.splitlines()
    return "\\n".join(lines[-400:])

items = []
""",
)

must_replace(
    """# JSON-shaped findings from codex outputs.
for m in re.finditer(r'"title"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"', text):
""",
    """scan_text = final_review_region(text)

# JSON-shaped findings from codex outputs.
for m in re.finditer(r'"title"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"', scan_text):
""",
)

must_replace(
    """# Plain-text reviewer bullets with priority prefixes.
for m in re.finditer(r'(?m)^[ \\t]*[-*][ \\t]+(\\[[Pp]\\d+\\][^\\n]+)$', text):
""",
    """# Plain-text reviewer bullets with priority prefixes.
for m in re.finditer(r'(?m)^[ \\t]*[-*][ \\t]+(\\[[Pp]\\d+\\][^\\n]+)$', scan_text):
""",
)

must_replace(
    """  else
    grep -E '^[[:space:]]*[-*][[:space:]]+\\[[Pp][0-9]+\\]' "$in_file" \\
      | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' > "$out_file" || true
""",
    """  else
    tail -n 400 "$in_file" | grep -E '^[[:space:]]*[-*][[:space:]]+\\[[Pp][0-9]+\\]' \\
      | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' > "$out_file" || true
""",
)

must_replace(
    """  local child_pid launch_isolated
  LAUNCH_CHILD_PID=""
  LAUNCH_ISOLATED="0"
  launch_in_new_process_group "$out_file" "$stdin_file" "$@"
""",
    """  local child_pid launch_isolated
  LAUNCH_CHILD_PID=""
  LAUNCH_ISOLATED="0"
  LAUNCH_CHILD_PGID=""
  launch_in_new_process_group "$out_file" "$stdin_file" "$@"
""",
)

must_replace(
    """  if [[ "$launch_isolated" == "1" ]]; then
    pgid="$(ps -o pgid= "$child_pid" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  set -e
""",
    """  if [[ "$launch_isolated" == "1" ]]; then
    pgid="$(ps -o pgid= "$child_pid" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  LAUNCH_CHILD_PGID="$pgid"
  set -e
""",
)

must_replace(
    """      kill_pid_or_group "$child_pid" "$pgid"
      wait "$child_pid" >/dev/null 2>&1 || true
      return 130
""",
    """      kill_pid_or_group "$child_pid" "$pgid"
      wait "$child_pid" >/dev/null 2>&1 || true
      LAUNCH_CHILD_PID=""
      LAUNCH_ISOLATED="0"
      LAUNCH_CHILD_PGID=""
      return 130
""",
)

must_replace(
    """  set +e
  wait "$child_pid"
  local ec=$?
  set -e
  return $ec
}
""",
    """  set +e
  wait "$child_pid"
  local ec=$?
  set -e
  LAUNCH_CHILD_PID=""
  LAUNCH_ISOLATED="0"
  LAUNCH_CHILD_PGID=""
  return $ec
}
""",
)

must_replace(
    """on_interrupt() {
  echo ""
  warn "Interrupted. Exiting gracefully (artifacts kept at $RUN_DIR)."
  exit 130
}
""",
    """on_interrupt() {
  echo ""
  if [[ -n "$LAUNCH_CHILD_PID" ]]; then
    local pgid="$LAUNCH_CHILD_PGID"
    if [[ -z "$pgid" && "$LAUNCH_ISOLATED" == "1" ]]; then
      pgid="$(ps -o pgid= "$LAUNCH_CHILD_PID" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    warn "Interrupted. Terminating active command (pid=$LAUNCH_CHILD_PID)."
    kill_pid_or_group "$LAUNCH_CHILD_PID" "$pgid"
    set +e
    wait "$LAUNCH_CHILD_PID" >/dev/null 2>&1
    set -e
    LAUNCH_CHILD_PID=""
    LAUNCH_ISOLATED="0"
    LAUNCH_CHILD_PGID=""
  fi
  warn "Interrupted. Exiting gracefully (artifacts kept at ${RUN_DIR:-<not-created>})."
  exit 130
}
""",
)

patched_path.write_text(text, encoding="utf-8")
PY

chmod +x "$PATCHED_SCRIPT"
exec "$PATCHED_SCRIPT" "$@"
