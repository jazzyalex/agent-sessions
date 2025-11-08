#!/usr/bin/env bash
set -euo pipefail

# Scan for Agent Sessions probe/debug sessions for Claude Code and Codex CLI.
# Produces two manifests under scripts/probe_scan_output/ and prints counts.

CL_ROOT=${CL_ROOT:-"$HOME/.claude/projects"}
CX_ROOT=${CX_ROOT:-"$HOME/.codex/sessions"}

# Known probe working directories (current + legacy hints)
CL_WD_CURRENT="$HOME/Library/Application Support/AgentSessions/ClaudeProbeProject"
CL_WD_LEGACY_HINT="AgentSessions-claude-usage"  # appears in sanitized Claude project folder names
# New canonical Codex probe working directory name
CX_WD_CURRENT="$HOME/Library/Application Support/AgentSessions/AgentSessions-codex-usage"

CL_MARKER="[AS_USAGE_PROBE v1]"
CX_MARKER="[AS_CX_PROBE v1]"

OUT_DIR="scripts/probe_scan_output"
mkdir -p "$OUT_DIR"
CL_OUT="$OUT_DIR/claude_probe_sessions.txt"
CX_OUT="$OUT_DIR/codex_probe_sessions.txt"
>"$CL_OUT"; >"$CX_OUT"

scan_claude() {
  local tmp_mark tmp_path tmp_proj
  tmp_mark=$(mktemp)
  tmp_path=$(mktemp)

  # 1) Content-based: sessions containing the probe marker
  if [[ -d "$CL_ROOT" ]]; then
    # Find jsonl/ndjson and grep for the marker (case-sensitive)
    find "$CL_ROOT" -type f \( -name '*.jsonl' -o -name '*.ndjson' \) -print0 \
      | xargs -0 grep -l --binary-files=without-match -- "$CL_MARKER" \
      | sort -u > "$tmp_mark" || true
  fi

  # 2) Path-based: any files living under project folders that reference the probe WD (current or legacy)
  #   - legacy project folder names contain "AgentSessions-claude-usage"
  #   - current projects may include the cleartext WD in project.json; also include any files under a folder name with that substring
  if [[ -d "$CL_ROOT" ]]; then
    # Legacy path hint in folder name
    find "$CL_ROOT" -type f \( -name '*.jsonl' -o -name '*.ndjson' \) -path "*${CL_WD_LEGACY_HINT}*" -print \
      | sort -u > "$tmp_path" || true

    # Current WD referenced in project.json; add all jsonl/ndjson within those project dirs
    while IFS= read -r -d '' proj; do
      if grep -q "$(printf '%s' "$CL_WD_CURRENT" | sed 's/[].[^$*\\]/\\&/g')" "$proj" 2>/dev/null; then
        proj_dir=$(dirname "$proj")
        find "$proj_dir" -type f \( -name '*.jsonl' -o -name '*.ndjson' \) -print
      fi
    done < <(find "$CL_ROOT" -type f -name 'project.json' -print0)
    # Append to tmp_path
  fi >> "$tmp_path"

  # Union → output
  cat "$tmp_mark" "$tmp_path" | sed '/^\s*$/d' | sort -u > "$CL_OUT"
  rm -f "$tmp_mark" "$tmp_path"
}

scan_codex() {
  local tmp_mark tmp_wd tmp_all
  tmp_mark=$(mktemp)
  tmp_wd=$(mktemp)

  # 1) Content-based: marker in any jsonl
  if [[ -d "$CX_ROOT" ]]; then
    rg -n --no-messages -F "$CX_MARKER" "$CX_ROOT" -g '**/*.jsonl' \
      | cut -d: -f1 | sort -u > "$tmp_mark" || true
  fi

  # 2) Working dir-based: cwd/project fields contain CodexProbeProject path
  if [[ -d "$CX_ROOT" ]]; then
    rg -n --no-messages '"(cwd|project)"\s*:\s*".*AgentSessions/CodexProbeProject' "$CX_ROOT" -g '**/*.jsonl' \
      | cut -d: -f1 | sort -u > "$tmp_wd" || true
  fi

  # Union → output
  cat "$tmp_mark" "$tmp_wd" | sed '/^\s*$/d' | sort -u > "$CX_OUT"
  rm -f "$tmp_mark" "$tmp_wd"
}

scan_claude
scan_codex

CL_COUNT=$(wc -l < "$CL_OUT" | tr -d ' ')
CX_COUNT=$(wc -l < "$CX_OUT" | tr -d ' ')

cat <<EOF
Probe sessions scan complete
- Claude files: $CL_COUNT
- Codex files:  $CX_COUNT

Manifests written to:
- $CL_OUT
- $CX_OUT
EOF

exit 0
