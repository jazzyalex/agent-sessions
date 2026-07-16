#!/usr/bin/env bash
# Daily triage: gather open issues/PRs/comments -> tool-less agent drafts a
# digest + suggested replies -> notify. You skim the digest and post the replies
# you want with `reply.sh <id>`. Nothing posts on its own.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

OUT_ROOT="${OUT_ROOT:-$HERE/out}"
OUT_DIR="$OUT_ROOT/$(date +%Y-%m-%d)"
mkdir -p "$OUT_DIR"
exec > >(tee -a "$OUT_DIR/run.log") 2>&1

# Rolling lookback window for "new comments" — stateless (no lastRun file). Open
# issues/PRs are always listed; comments are filtered to the last N hours.
LOOKBACK="$(policy_get '.lookback_hours' 2>/dev/null || echo 48)"
LAST_RUN="$(date -u -v-"${LOOKBACK}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -d "-${LOOKBACK} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || utc_now)"

OUT_DIR="$OUT_DIR" LAST_RUN="$LAST_RUN" bash "$HERE/gather.sh"

if OUT_DIR="$OUT_DIR" bash "$HERE/run-agent.sh"; then
  msg="digest ready → $OUT_DIR/digest.md"
else
  # Never leave a blank digest: fall back to a raw count from the snapshot.
  log "agent failed — writing minimal fallback digest"
  jq -r '.repos | to_entries[] | "## \(.key)\n- issues: \(.value.issues|length)  prs: \(.value.prs|length)"' \
     "$OUT_DIR/snapshot.json" > "$OUT_DIR/digest.md" 2>/dev/null \
     || echo "# triage (agent failed — see run.log)" > "$OUT_DIR/digest.md"
  echo '[]' > "$OUT_DIR/replies.json"
  msg="digest ready (agent fell back — see run.log) → $OUT_DIR/digest.md"
fi

bash "$HERE/lib/notify.sh" "Repo triage" "$msg" || true
