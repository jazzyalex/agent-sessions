#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

OUT_DIR="${OUT_DIR:?OUT_DIR required}"
AGENT_STAGE_ROOT="${AGENT_STAGE_ROOT:-$HOME/Library/Application Support/agent-triage/stage}"
RUN_ID="$(basename "$OUT_DIR")-$$"
STAGE="$AGENT_STAGE_ROOT/$RUN_ID"
AGENT_CONFIG="$HERE/lib/agent-config"

cleanup() {
  rm -rf "$STAGE"
  # Best-effort: drop the root too if this was the only run using it (test
  # harnesses use a fresh mktemp root per run and expect it fully gone).
  # rmdir no-ops (silently) if another concurrent run still has a sibling
  # subdir under it, so this is safe under the orchestrator's locking model.
  rmdir "$AGENT_STAGE_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$STAGE"
cp "$OUT_DIR/snapshot.json" "$STAGE/snapshot.json"
cp "$HERE/PROMPT.md" "$STAGE/PROMPT.md"

agent="$(policy_get '.agent')"
model="$(policy_get '.agent_model')"

run_claude() {
  # Confinement mechanism, proven by the Task 4 gate, WITHOUT breaking auth:
  #  - cwd = stage, OUTSIDE the repo -> repo CLAUDE.md / .claude/settings are never
  #    discovered by walking up, and Read/Write are workspace-scoped to the stage
  #    (a write outside cwd has no permission prompt in -p mode, so it is denied).
  #  - CLAUDE_CONFIG_DIR is left UNSET (default): the real OAuth session lives in
  #    ~/.claude.json; relocating the config dir logs the agent out ("Not logged in").
  #  - --strict-mcp-config with no --mcp-config -> zero MCP servers load.
  #  - --disallowedTools denies Bash/WebFetch/WebSearch; deny wins over any inherited
  #    (user-global) allowlist, so there is no shell/network channel.
  #  - --settings <file> adds the same denials + empty mcp/hooks declaratively
  #    (belt-and-suspenders); it is a FILE path, not a config dir, so auth is intact.
  #  - the prompt is piped via STDIN so the variadic --disallowedTools cannot swallow it.
  local suffix=$'\n\nRead snapshot.json in this directory. Write digest.md and actions.json here. Do not take any other action.'
  ( cd "$STAGE" && \
    printf '%s%s' "$(cat PROMPT.md)" "$suffix" | claude -p \
      --model "$model" \
      --settings "$AGENT_CONFIG/settings.json" \
      --strict-mcp-config \
      --allowedTools Read Write \
      --disallowedTools Bash WebFetch WebSearch )
}

run_codex() {
  # Future adapter — see spec Portability. Confinement via --sandbox + network off.
  ( cd "$STAGE" && codex exec --model "$model" \
      "$(cat PROMPT.md)

Read snapshot.json here. Write digest.md and actions.json here." )
}

case "$agent" in
  claude) run_claude ;;
  codex)  run_codex ;;
  *) log "unknown agent: $agent"; exit 2 ;;
esac

# Require at least one output; copy whatever exists back.
produced=0
for f in digest.md actions.json; do
  if [ -f "$STAGE/$f" ]; then cp "$STAGE/$f" "$OUT_DIR/$f"; produced=1; fi
done
[ "$produced" -eq 1 ] || { log "agent produced no output"; exit 3; }
