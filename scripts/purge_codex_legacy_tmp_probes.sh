#!/usr/bin/env bash
#
# Purge legacy Codex probe sessions that were logged in tmp.* working directories.
#
# Safety rules:
# - Only considers files under Codex sessions root: $CODEX_HOME/sessions or ~/.codex/sessions
# - Requires cwd/project path to match a tmp-like folder (var/folders/.../T/tmp.* or /tmp/tmp.*)
# - AND one of:
#     * contains "[AS_CX_PROBE v1]" in a user message, OR
#     * contains a user_message with message "/status", OR
#     * is a tiny session: <= 5 event_msg entries
# - Prints a manifest (session path + project/cwd) before deletion.
# - Default is dry-run; pass --delete to actually remove files.
#
# Usage:
#   scripts/purge_codex_legacy_tmp_probes.sh           # dry run, prints list
#   scripts/purge_codex_legacy_tmp_probes.sh --delete  # delete matched files
#
set -euo pipefail

ROOT="${CODEX_HOME:-$HOME/.codex}/sessions"
if [[ ! -d "$ROOT" ]]; then
  echo "Codex sessions root not found: $ROOT" >&2
  exit 0
fi

DO_DELETE=0
if [[ "${1:-}" == "--delete" ]]; then DO_DELETE=1; fi

OUTDIR="scripts/probe_scan_output"
mkdir -p "$OUTDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
MANIFEST="$OUTDIR/codex_legacy_tmp_probes_${STAMP}.txt"

echo "Scanning for legacy tmp-based Codex probe sessions under: $ROOT"

# Gather candidates (portable across macOS bash 3.x)
FILES=()
while IFS= read -r ff; do
  FILES+=("$ff")
done < <(find "$ROOT" -type f -name '*.jsonl' -print 2>/dev/null)

is_tmp_path() {
  local path="$1"
  # tmp under var/folders or /tmp
  if [[ "$path" =~ ^/(private/)?var/folders/.*/T/tmp\.[A-Za-z0-9]+(/.*)?$ ]]; then return 0; fi
  if [[ "$path" =~ ^/tmp/tmp\.[A-Za-z0-9]+(/.*)?$ ]]; then return 0; fi
  return 1
}

extract_first_json() {
  # print first N lines to stdout
  sed -n '1,400p' "$1" 2>/dev/null
}

extract_project_or_cwd() {
  local file="$1"
  local head
  head=$(extract_first_json "$file") || head=""
  # Prefer project, then cwd
  local p
  p=$(printf "%s\n" "$head" | awk -F '"project"' '{print $2}' | awk -F '"' '{for(i=1;i<=NF;i++){if($i ~ /^\/[~A-Za-z0-9_\-\.:\/]/){print $i; exit}}}')
  if [[ -z "$p" ]]; then
    p=$(printf "%s\n" "$head" | awk -F '"cwd"' '{print $2}' | awk -F '"' '{for(i=1;i<=NF;i++){if($i ~ /^\/[~A-Za-z0-9_\-\.:\/]/){print $i; exit}}}')
  fi
  printf "%s" "$p"
}

contains_marker() {
  local file="$1"; grep -q "\[AS_CX_PROBE v1\]" "$file" 2>/dev/null || return 1
}

contains_status_user() {
  local file="$1"; grep -q '"type"\s*:\s*"user_message".*"/status"' "$file" 2>/dev/null || return 1
}

event_count() {
  local file="$1"; grep -c '"type"\s*:\s*"event_msg"' "$file" 2>/dev/null || true
}

MATCHED=()
SKIPPED=0
for f in "${FILES[@]}"; do
  head=$(extract_first_json "$f") || head=""
  # pull project/cwd path candidate
  proj=$(extract_project_or_cwd "$f")
  if [[ -z "$proj" ]]; then SKIPPED=$((SKIPPED+1)); continue; fi
  if ! is_tmp_path "$proj"; then SKIPPED=$((SKIPPED+1)); continue; fi
  # extra gates
  tiny=0
  ec=$(event_count "$f")
  if [[ "$ec" -le 5 ]]; then tiny=1; fi
  if contains_marker "$f" || contains_status_user "$f" || [[ "$tiny" == 1 ]]; then
    MATCHED+=("$f:::${proj}")
  else
    SKIPPED=$((SKIPPED+1))
  fi
done

COUNT=${#MATCHED[@]}
echo "Found $COUNT legacy tmp-based probe file(s). Writing manifest: $MANIFEST"
{
  echo "# Legacy Codex tmp probe sessions (file ::: project/cwd)"
  for entry in "${MATCHED[@]}"; do echo "$entry"; done
} > "$MANIFEST"

echo "\nSessions to remove (file → project):"
for entry in "${MATCHED[@]}"; do
  file=${entry%%:::*}
  proj=${entry##*:::}
  echo "- $file"
  echo "    project: $proj"
done

if [[ "$DO_DELETE" == 1 ]]; then
  echo "\nDeleting…"
  DELETED=0
  for entry in "${MATCHED[@]}"; do
    file=${entry%%:::*}
    # Ensure file still under ROOT and exists
    case "$file" in
      "$ROOT"/*)
        if rm -f -- "$file" 2>/dev/null; then DELETED=$((DELETED+1)); fi ;;
      *) echo "! skipped outside root: $file";;
    esac
  done
  echo "Deleted $DELETED file(s). Manifest: $MANIFEST"
else
  echo "\nDry-run only. To delete, re-run with --delete"
fi
