#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

OUT_ROOT="${OUT_ROOT:-$HERE/out}"
STATE_FILE="${STATE_FILE:-$HERE/state.json}"
LOCK="$OUT_ROOT/.lock"
TODAY="$(date +%Y-%m-%d)"
OUT_DIR="$OUT_ROOT/$TODAY"
mkdir -p "$OUT_ROOT"

# --- catch-up time gate ---
HHMM="${NOW_HHMM:-$(date +%H%M)}"
if [ "$HHMM" -lt "0800" ]; then log "before 08:00 ($HHMM) — waiting for schedule"; exit 0; fi
if [ -f "$OUT_DIR/status.json" ]; then log "today already completed — skipping"; exit 0; fi

# --- lock (scheduled runs only) ---
acquire_lock "$LOCK" || { log "another run holds the lock — deferring"; exit 0; }
STATUS="failed"
finish_run() {
  local rc=$?
  echo "{\"status\":\"$STATUS\",\"at\":\"$(utc_now)\"}" > "$OUT_DIR/status.json" 2>/dev/null || true
  bash "$HERE/lib/notify.sh" "Repo triage" \
     "$([ "$STATUS" = failed ] && echo 'FAILED — see run.log' || echo "status: $STATUS")" || true
  release_lock "$LOCK"
  exit $rc
}
trap finish_run EXIT

mkdir -p "$OUT_DIR"
exec > >(tee -a "$OUT_DIR/run.log") 2>&1

# retention prune
find "$OUT_ROOT" -maxdepth 1 -type d -name '20*-*-*' -mtime +"$(policy_get '.out_retention_days')" \
  -exec rm -rf {} + 2>/dev/null || true

# lastRun bootstrap
if [ -f "$STATE_FILE" ]; then LAST_RUN="$(jq -r '.lastRun' "$STATE_FILE")"
else LAST_RUN="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || utc_now)"; fi
export OUT_DIR LAST_RUN

# gather
OUT_DIR="$OUT_DIR" LAST_RUN="$LAST_RUN" bash "$HERE/gather.sh"
had_errors="$(jq '.errors | length' "$OUT_DIR/snapshot.json")"

# agent (fallback to minimal digest on failure)
if OUT_DIR="$OUT_DIR" bash "$HERE/run-agent.sh"; then :; else
  log "agent failed — writing minimal fallback digest"
  jq -r '.repos | to_entries[] | "## \(.key)\n- issues: \(.value.issues|length)  prs: \(.value.prs|length)"' \
     "$OUT_DIR/snapshot.json" > "$OUT_DIR/digest.md" || echo "# triage (fallback)" > "$OUT_DIR/digest.md"
  echo '{"generated_at":"'"$(utc_now)"'","snapshot_ref":"snapshot.json","actions":[]}' > "$OUT_DIR/actions.json"
  had_errors=1
fi

# auto-apply
OUT_DIR="$OUT_DIR" bash "$HERE/apply.sh" --auto "$OUT_DIR" || true

# terminal status + lastRun advancement
if [ "$had_errors" -eq 0 ]; then
  STATUS="success"
  gs="$(jq -r '.gather_start' "$OUT_DIR/snapshot.json")"
  echo "{\"lastRun\":\"$gs\"}" > "$STATE_FILE"
else
  STATUS="partial"   # do NOT advance lastRun
fi
# trap writes status.json + notifies
