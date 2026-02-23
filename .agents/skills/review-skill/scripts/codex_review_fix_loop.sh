#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# codex_review_fix_loop.sh
#
# Deterministic headless loop:
#   review -> (if not clean) fix -> review -> ...
#
# Review uses: codex review (non-interactive)
# Fix uses:    codex exec   (non-interactive)
#
# Control file: polled between rounds only
###############################################################################

# ----------------------------- Defaults --------------------------------------

MAX_ROUNDS="${MAX_ROUNDS:-6}"

# These are "selectors" per your spec defaults; we interpret:
# - if value is one of minimal|low|medium|high|xhigh => reasoning effort
# - otherwise => model id (optionally with "@<effort>")
REVIEW_MODEL_EARLY="${REVIEW_MODEL_EARLY:-high}"
REVIEW_MODEL_LATE="${REVIEW_MODEL_LATE:-xhigh}"
# Backward compatible env behavior:
# - FIX_MODEL (legacy): pins all fix rounds to one selector
# - FIX_MODEL_EARLY/FIX_MODEL_LATE: round-based defaults
FIX_MODEL_EARLY="${FIX_MODEL_EARLY:-${FIX_MODEL:-high}}"
FIX_MODEL_LATE="${FIX_MODEL_LATE:-${FIX_MODEL:-xhigh}}"

CONTROL_FILE="${CONTROL_FILE:-.codex-review-control.md}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.codex-review-artifacts}"

# If set, overrides what "model id" we pass (separate from reasoning effort)
REVIEW_MODEL_ID="${REVIEW_MODEL_ID:-}"
FIX_MODEL_ID="${FIX_MODEL_ID:-}"

# Optional prompt sources
REVIEW_PROMPT="${REVIEW_PROMPT:-}"            # literal text OR path to file
REVIEW_PROMPT_FILE=""                         # set by flag --review-prompt-file
# Review prompt mode:
# - plain (default): start with working path, no prompt injection
# - prompt: always inject review prompt
# - auto: try prompt first, then fallback to plain on CLI incompatibility
REVIEW_PROMPT_MODE="${REVIEW_PROMPT_MODE:-plain}"

# Scope defaults
SCOPE_MODE="uncommitted"  # uncommitted|base|commit
SCOPE_BASE_BRANCH=""
SCOPE_COMMIT_SHA=""
REVIEW_LOOP_MODE="${REVIEW_LOOP_MODE:-conservative}"  # conservative|balanced
SCOPE_INCLUDE_UNTRACKED="${SCOPE_INCLUDE_UNTRACKED:-}"
SCOPE_ALLOWLIST_FILE="${SCOPE_ALLOWLIST_FILE:-}"
FAIL_ON_SCOPE_VIOLATION="${FAIL_ON_SCOPE_VIOLATION:-}"
REVERT_SCOPE_VIOLATION_UNTRACKED="${REVERT_SCOPE_VIOLATION_UNTRACKED:-}"
FAIL_ON_FORBIDDEN_COMMANDS="${FAIL_ON_FORBIDDEN_COMMANDS:-}"

# CLI-only knobs
DRY_RUN="0"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-60}"
ERROR_SCAN_TAIL_LINES="${ERROR_SCAN_TAIL_LINES:-200}"
REVIEW_TIMEOUT_SECONDS="${REVIEW_TIMEOUT_SECONDS:-900}"
FIX_TIMEOUT_SECONDS="${FIX_TIMEOUT_SECONDS:-900}"
REVIEW_TIMEOUT_RETRIES="${REVIEW_TIMEOUT_RETRIES:-1}"
AUTH_FAILURE_RETRIES="${AUTH_FAILURE_RETRIES:-1}"
AUTH_SCAN_TAIL_LINES="${AUTH_SCAN_TAIL_LINES:-200}"
FINDINGS_FUZZY="${FINDINGS_FUZZY:-1}"
FINDINGS_FUZZY_THRESHOLD="${FINDINGS_FUZZY_THRESHOLD:-0.86}"
AUTH_ERROR_EXIT_CODE=66

# Control-file overrides (loaded between rounds)
CF_STATUS="resume"           # pause|resume|stop
CF_APPEND_CONTEXT=""         # free text block
CF_REVIEW_SELECTOR=""        # overrides review selector (model id / effort / model@effort)
CF_FIX_SELECTOR=""           # overrides fix selector (model id / effort / model@effort)
CF_SCOPE_OVERRIDE=""         # uncommitted | base:<branch> | commit:<sha>

# Run state
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR=""
LAST_CONTROL_HASH=""
LAST_EFFECTIVE_REVIEW_EFFORT=""
LAST_EFFECTIVE_FIX_EFFORT=""
LAUNCH_CHILD_PID=""
LAUNCH_ISOLATED="0"
LAUNCH_CHILD_PGID=""
HEARTBEAT_AUTH_FAILURE="0"
HEARTBEAT_AUTH_DETAIL=""

# ----------------------------- Helpers ---------------------------------------

usage() {
  cat <<'USAGE'
Usage:
  codex_review_fix_loop.sh [--uncommitted] [--base <branch>] [--commit <sha>]
                           [--max-rounds <n>]
                           [--loop-mode <conservative|balanced>]
                           [--scope-include-untracked|--scope-ignore-untracked]
                           [--scope-allowlist-file <path>]
                           [--fail-on-scope-violation <0|1>]
                           [--revert-scope-violation-untracked <0|1>]
                           [--fail-on-forbidden-commands <0|1>]
                           [--review-model-early <id|effort|model@effort>]
                           [--review-model-late  <id|effort|model@effort>]
                           [--fix-model-early <id|effort|model@effort>]
                           [--fix-model-late  <id|effort|model@effort>]
                           [--fix-model <id|effort|model@effort>]
                           [--review-model-id <model_id>]
                           [--fix-model-id <model_id>]
                           [--review-prompt-mode <plain|prompt|auto>]
                           [--review-prompt-file <path>]
                           [--heartbeat-seconds <n>]
                           [--review-timeout-seconds <n>]
                           [--fix-timeout-seconds <n>]
                           [--review-timeout-retries <n>]
                           [--auth-failure-retries <n>]
                           [--auth-scan-tail-lines <n>]
                           [--error-scan-tail-lines <n>]
                           [--control-file <path>]
                           [--artifacts-dir <path>]
                           [--dry-run]

Defaults:
  --uncommitted
  --max-rounds 6
  --loop-mode conservative
  --scope-ignore-untracked (for uncommitted scope)
  --fail-on-scope-violation 1
  --revert-scope-violation-untracked 1
  --fail-on-forbidden-commands 1
  --review-model-early high
  --review-model-late  xhigh
  --fix-model-early    high
  --fix-model-late     xhigh
  --review-prompt-mode plain
  --heartbeat-seconds  60
  --review-timeout-seconds 900
  --fix-timeout-seconds    900
  --review-timeout-retries 1
  --auth-failure-retries   1
  --auth-scan-tail-lines   200
  --error-scan-tail-lines  200
  --control-file       .codex-review-control.md
  --artifacts-dir      .codex-review-artifacts

Notes:
  - "high" and "xhigh" are treated as reasoning effort (model_reasoning_effort).
  - To specify both model and effort, use "gpt-5.3-codex@xhigh" format.
  - --fix-model is a convenience override that pins both early+late fix selectors.
  - Heartbeat lines print periodic in-progress summaries during review/fix commands.
  - Review/fix phases are killed when timeout is exceeded (>0 seconds).
  - Review phase retries once on timeout by default (configurable).
  - Auth failures (for example `refresh_token_reused`) are detected and fail
    fast instead of stalling until timeout.
  - Review error parsing ignores known benign internal rollout-log noise.
  - Finding deltas use exact matching + optional fuzzy reworded reconciliation
    (env: FINDINGS_FUZZY=1, FINDINGS_FUZZY_THRESHOLD=0.86).
  - Conservative mode blocks build/test/package-manager command execution in
    fix output and fails on post-fix edits outside the computed scope.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 2; }
warn() { echo "WARN: $*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

trim() {
  # trim leading/trailing whitespace
  local s="$1"
  # shellcheck disable=SC2001
  s="$(echo "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf "%s" "$s"
}

validate_toggle_01() {
  local flag_name="$1"
  local value="$2"
  [[ "$value" =~ ^[01]$ ]] || die "${flag_name} must be 0 or 1"
}

apply_mode_defaults() {
  case "$REVIEW_LOOP_MODE" in
    conservative)
      if [[ -z "$SCOPE_INCLUDE_UNTRACKED" ]]; then SCOPE_INCLUDE_UNTRACKED="0"; fi
      if [[ -z "$FAIL_ON_SCOPE_VIOLATION" ]]; then FAIL_ON_SCOPE_VIOLATION="1"; fi
      if [[ -z "$REVERT_SCOPE_VIOLATION_UNTRACKED" ]]; then REVERT_SCOPE_VIOLATION_UNTRACKED="1"; fi
      if [[ -z "$FAIL_ON_FORBIDDEN_COMMANDS" ]]; then FAIL_ON_FORBIDDEN_COMMANDS="1"; fi
      ;;
    balanced)
      if [[ -z "$SCOPE_INCLUDE_UNTRACKED" ]]; then SCOPE_INCLUDE_UNTRACKED="1"; fi
      if [[ -z "$FAIL_ON_SCOPE_VIOLATION" ]]; then FAIL_ON_SCOPE_VIOLATION="0"; fi
      if [[ -z "$REVERT_SCOPE_VIOLATION_UNTRACKED" ]]; then REVERT_SCOPE_VIOLATION_UNTRACKED="0"; fi
      if [[ -z "$FAIL_ON_FORBIDDEN_COMMANDS" ]]; then FAIL_ON_FORBIDDEN_COMMANDS="0"; fi
      ;;
    *)
      die "--loop-mode must be one of: conservative|balanced"
      ;;
  esac
}

is_effort() {
  case "$1" in
    minimal|low|medium|high|xhigh) return 0 ;;
    *) return 1 ;;
  esac
}

hash_file() {
  local path="$1"
  if have_cmd shasum; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif have_cmd sha256sum; then
    sha256sum "$path" | awk '{print $1}'
  elif have_cmd md5; then
    # macOS md5
    md5 -q "$path"
  else
    # last resort: filesize+mtime
    stat -c '%s:%Y' "$path" 2>/dev/null || stat -f '%z:%m' "$path" 2>/dev/null || echo "nohash"
  fi
}

write_meta_json() {
  local path="$1"
  local round="$2"
  local scope="$3"
  local review_model_id="$4"
  local review_effort="$5"
  local fix_model_id="$6"
  local fix_effort="$7"
  local review_ec="$8"
  local fix_ec="$9"
  shift 9
  local review_clean="$1"
  local append_context_len="$2"

  if have_cmd python3; then
    python3 - <<PY \
      "$path" "$round" "$scope" "$review_model_id" "$review_effort" \
      "$fix_model_id" "$fix_effort" "$review_ec" "$fix_ec" "$review_clean" "$append_context_len"
import json, sys, time
(
  path, round_s, scope, rmid, reff, fmid, feff, rec_s, fec_s, clean_s, acl_s
) = sys.argv[1:]
doc = {
  "round": int(round_s),
  "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
  "scope": scope,
  "review": {
    "model_id": rmid or None,
    "reasoning_effort": reff or None,
    "exit_code": int(rec_s),
    "clean": (clean_s.lower() == "true"),
  },
  "fix": {
    "model_id": fmid or None,
    "reasoning_effort": feff or None,
    "exit_code": int(fec_s),
  },
  "append_context_len": int(acl_s),
}
with open(path, "w", encoding="utf-8") as f:
  json.dump(doc, f, indent=2, sort_keys=True)
  f.write("\n")
PY
  else
    # Fallback minimal JSON without perfect escaping
    cat >"$path" <<EOF
{
  "round": $round,
  "scope": "$(printf "%s" "$scope" | sed 's/"/\\"/g')",
  "review": {"model_id": "$(printf "%s" "$review_model_id" | sed 's/"/\\"/g')", "reasoning_effort": "$(printf "%s" "$review_effort" | sed 's/"/\\"/g')", "exit_code": $review_ec, "clean": $review_clean},
  "fix": {"model_id": "$(printf "%s" "$fix_model_id" | sed 's/"/\\"/g')", "reasoning_effort": "$(printf "%s" "$fix_effort" | sed 's/"/\\"/g')", "exit_code": $fix_ec},
  "append_context_len": $append_context_len
}
EOF
  fi
}

select_review_selector_for_round() {
  local round="$1"
  if [[ "$round" -le 2 ]]; then
    printf "%s" "$REVIEW_MODEL_EARLY"
  else
    printf "%s" "$REVIEW_MODEL_LATE"
  fi
}

select_fix_selector_for_round() {
  local round="$1"
  if [[ "$round" -le 4 ]]; then
    printf "%s" "$FIX_MODEL_EARLY"
  else
    printf "%s" "$FIX_MODEL_LATE"
  fi
}

# Parse selector into model_id + effort.
# Supported formats:
#   - "high" => effort=high
#   - "gpt-5.3-codex" => model_id=..., effort stays default
#   - "gpt-5.3-codex@xhigh" => model_id=..., effort=xhigh
parse_selector() {
  local sel="$1"
  local default_model_id="$2"
  local default_effort="$3"

  local model_id="$default_model_id"
  local effort="$default_effort"

  if [[ -n "$sel" && "$sel" == *"@"* ]]; then
    model_id="${sel%@*}"
    effort="${sel#*@}"
  elif [[ -n "$sel" ]]; then
    if is_effort "$sel"; then
      effort="$sel"
    else
      model_id="$sel"
    fi
  fi

  # validate effort if provided
  if [[ -n "$effort" ]] && ! is_effort "$effort"; then
    warn "Unknown reasoning effort '$effort' (expected minimal|low|medium|high|xhigh). Passing through anyway."
  fi

  printf "%s\n%s\n" "$model_id" "$effort"
}

ensure_codex() {
  have_cmd codex || die "codex CLI not found in PATH"
}

ensure_git_repo() {
  if ! have_cmd git; then
    warn "git not found; codex review likely requires a git repo."
    return 0
  fi
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repo (git rev-parse failed)."
}

ensure_codex_login_healthy() {
  local out_file="$1"
  if ! codex_login_status_is_healthy "$out_file"; then
    warn "Codex login status is unhealthy; review loop will not start."
    warn "Run 'codex logout' then 'codex login' and retry."
    warn "login status output:"
    sed 's/^/  /' "$out_file" >&2 || true
    return 1
  fi
  if grep -Eqi 'login status unsupported; preflight skipped' "$out_file"; then
    warn "Codex CLI does not support 'codex login status'; auth preflight skipped."
    return 0
  fi
  if grep -Eqi 'logged in using chatgpt' "$out_file"; then
    warn "Codex login is using ChatGPT session auth."
    warn "For maximum loop reliability, prefer API-key login in automation:"
    warn "  printenv OPENAI_API_KEY | codex login --with-api-key"
  fi
  return 0
}

mk_run_dir() {
  mkdir -p "$ARTIFACTS_DIR"
  RUN_DIR="${ARTIFACTS_DIR%/}/${RUN_TS}"
  mkdir -p "$RUN_DIR"

  # Pointer file
  local latest_path="${ARTIFACTS_DIR%/}/LATEST"
  if [[ -e "$latest_path" || -L "$latest_path" ]]; then
    if [[ -d "$latest_path" && ! -L "$latest_path" ]]; then
      rm -rf "$latest_path"
    else
      rm -f "$latest_path"
    fi
  fi
  echo "$RUN_DIR" > "$latest_path"

  # Best-effort symlink
  if have_cmd ln; then
    (cd "$ARTIFACTS_DIR" && ln -sfn "$RUN_TS" latest) >/dev/null 2>&1 || true
  fi
}

print_phase() {
  # single-line header style
  local msg="$1"
  echo "==> $msg"
}

preview_nonempty_lines() {
  local file="$1"
  local max_lines="${2:-12}"
  # Avoid SIGPIPE under `set -o pipefail` by limiting inside awk.
  awk -v max="$max_lines" 'NF{print; c++; if (c>=max) exit}' "$file"
}

estimate_findings_count() {
  local file="$1"
  # heuristic: count bullet/numbered items outside fenced code blocks
  awk '
    BEGIN{c=0; in_code=0}
    /^```/{in_code = !in_code; next}
    in_code{next}
    /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+/{c++}
    END{print c}
  ' "$file"
}

count_nonempty_lines() {
  local file="$1"
  awk 'NF{c++} END{print c+0}' "$file"
}

extract_review_findings() {
  local in_file="$1"
  local out_file="$2"
  : > "$out_file"

  if have_cmd python3; then
    python3 - "$in_file" "$out_file" <<'PY'
import json
import re
import sys

in_file, out_file = sys.argv[1], sys.argv[2]
text = open(in_file, "r", encoding="utf-8", errors="ignore").read()

items = []
seen = set()

def add(raw: str) -> None:
    s = raw.strip()
    if not s:
        return
    if s in seen:
        return
    seen.add(s)
    items.append(s)

# JSON-shaped findings from codex outputs.
for m in re.finditer(r'"title"\s*:\s*"((?:[^"\\]|\\.)*)"', text):
    raw = m.group(1)
    try:
        decoded = json.loads('"' + raw + '"')
    except Exception:
        decoded = raw
    add(decoded)

# Plain-text reviewer bullets with priority prefixes.
for m in re.finditer(r'(?m)^[ \t]*[-*][ \t]+(\[[Pp]\d+\][^\n]+)$', text):
    add(m.group(1))

with open(out_file, "w", encoding="utf-8") as f:
    for item in items:
        f.write(item + "\n")
PY
  else
    grep -E '^[[:space:]]*[-*][[:space:]]+\[[Pp][0-9]+\]' "$in_file" \
      | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' > "$out_file" || true
  fi
}

print_indented_list() {
  local file="$1"
  local indent="${2:-  - }"
  awk -v ind="$indent" 'NF{print ind $0}' "$file"
}

fuzzy_reconcile_reworded_findings() {
  local resolved_file="$1"
  local new_file="$2"
  local out_resolved_file="$3"
  local out_new_file="$4"
  local out_reworded_file="$5"
  local threshold="${6:-0.86}"

  : > "$out_reworded_file"

  if ! have_cmd python3; then
    cp -f "$resolved_file" "$out_resolved_file"
    cp -f "$new_file" "$out_new_file"
    return 0
  fi

  python3 - "$resolved_file" "$new_file" "$out_resolved_file" "$out_new_file" "$out_reworded_file" "$threshold" <<'PY'
import re
import sys
from difflib import SequenceMatcher

resolved_path, new_path, out_resolved, out_new, out_pairs, thr_s = sys.argv[1:]
threshold = float(thr_s)

def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return [ln.strip() for ln in f.read().splitlines() if ln.strip()]
    except FileNotFoundError:
        return []

def normalize(text: str) -> str:
    t = text.lower()
    t = re.sub(r'\[[pP]\d+\]', ' ', t)
    t = re.sub(r'[^a-z0-9]+', ' ', t)
    t = re.sub(r'\s+', ' ', t).strip()
    return t

def priority_tag(text: str) -> str:
    m = re.search(r'\[([pP]\d+)\]', text)
    return m.group(1).lower() if m else ""

resolved = sorted(read_lines(resolved_path))
new = sorted(read_lines(new_path))

new_meta = [(n, normalize(n), priority_tag(n)) for n in new]
used_new = set()
pairs = []

for prev in resolved:
    prev_norm = normalize(prev)
    prev_pri = priority_tag(prev)
    best = None  # (score, new_item)
    for curr, curr_norm, curr_pri in new_meta:
        if curr in used_new:
            continue
        # If both findings carry explicit priority tags, require match.
        if prev_pri and curr_pri and prev_pri != curr_pri:
            continue
        score = SequenceMatcher(None, prev_norm, curr_norm).ratio()
        if best is None or score > best[0]:
            best = (score, curr)
    if best and best[0] >= threshold:
        score, curr = best
        used_new.add(curr)
        pairs.append((prev, curr, score))

pair_prev = {p[0] for p in pairs}
resolved_remaining = [p for p in resolved if p not in pair_prev]
new_remaining = [n for n in new if n not in used_new]

with open(out_resolved, "w", encoding="utf-8") as f:
    for item in resolved_remaining:
        f.write(item + "\n")

with open(out_new, "w", encoding="utf-8") as f:
    for item in new_remaining:
        f.write(item + "\n")

with open(out_pairs, "w", encoding="utf-8") as f:
    for prev, curr, score in sorted(pairs, key=lambda x: (-x[2], x[0], x[1])):
        f.write(f"{score:.2f} | PREV: {prev} | CURR: {curr}\n")
PY
}

compare_finding_sets() {
  local prev_file="$1"
  local curr_file="$2"
  local resolved_file="$3"
  local remaining_file="$4"
  local new_file="$5"
  local reworded_file="${6:-}"

  local prev_sorted curr_sorted
  prev_sorted="$(mktemp "${TMPDIR:-/tmp}/codex-prev-findings.XXXXXX")"
  curr_sorted="$(mktemp "${TMPDIR:-/tmp}/codex-curr-findings.XXXXXX")"

  if [[ -f "$prev_file" ]]; then
    LC_ALL=C sort -u "$prev_file" > "$prev_sorted"
  else
    : > "$prev_sorted"
  fi
  if [[ -f "$curr_file" ]]; then
    LC_ALL=C sort -u "$curr_file" > "$curr_sorted"
  else
    : > "$curr_sorted"
  fi

  LC_ALL=C comm -23 "$prev_sorted" "$curr_sorted" > "$resolved_file"
  LC_ALL=C comm -12 "$prev_sorted" "$curr_sorted" > "$remaining_file"
  LC_ALL=C comm -13 "$prev_sorted" "$curr_sorted" > "$new_file"

  if [[ -n "$reworded_file" ]]; then
    : > "$reworded_file"
  fi

  if [[ "$FINDINGS_FUZZY" == "1" ]]; then
    local thr resolved_tmp new_tmp reworded_tmp
    thr="$FINDINGS_FUZZY_THRESHOLD"
    resolved_tmp="$(mktemp "${TMPDIR:-/tmp}/codex-resolved2.XXXXXX")"
    new_tmp="$(mktemp "${TMPDIR:-/tmp}/codex-new2.XXXXXX")"

    if [[ -n "$reworded_file" ]]; then
      reworded_tmp="$reworded_file"
    else
      reworded_tmp="$(mktemp "${TMPDIR:-/tmp}/codex-reworded.XXXXXX")"
    fi

    fuzzy_reconcile_reworded_findings "$resolved_file" "$new_file" \
      "$resolved_tmp" "$new_tmp" "$reworded_tmp" "$thr"

    mv -f "$resolved_tmp" "$resolved_file"
    mv -f "$new_tmp" "$new_file"

    if [[ -z "$reworded_file" ]]; then
      rm -f "$reworded_tmp"
    fi
  fi

  rm -f "$prev_sorted" "$curr_sorted"
}

extract_fix_touched_files() {
  local in_file="$1"
  local out_file="$2"
  : > "$out_file"

  if have_cmd python3; then
    python3 - "$in_file" "$out_file" "$PWD" <<'PY'
import os
import re
import sys

in_file, out_file, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(in_file, "r", encoding="utf-8", errors="ignore").read().splitlines()

items = []
seen = set()

def add(path: str) -> None:
    p = path.strip()
    if not p:
        return
    if p.startswith(repo_root + os.sep):
        p = os.path.relpath(p, repo_root)
    if p in seen:
        return
    seen.add(p)
    items.append(p)

for line in lines:
    m = re.match(r'^diff --git a/([^ ]+) b/[^ ]+$', line)
    if m:
        add(m.group(1))
        continue
    m = re.match(r'^M\s+(/.+)$', line)
    if m:
        add(m.group(1))

with open(out_file, "w", encoding="utf-8") as f:
    for item in items:
        f.write(item + "\n")
PY
  else
    grep -E '^diff --git a/' "$in_file" \
      | sed -E 's#^diff --git a/([^ ]+) b/[^ ]+$#\1#' \
      | sort -u > "$out_file" || true
  fi
}

count_exec_events() {
  local file="$1"
  local n
  n="$(grep -Eci '(^exec$|succeeded in [0-9]+ms)' "$file" 2>/dev/null || true)"
  n="$(printf "%s" "$n" | head -n1 | tr -d '[:space:]')"
  [[ -z "$n" ]] && n=0
  printf "%s" "$n"
}

is_benign_review_error_line() {
  local line="$1"
  if printf "%s" "$line" | grep -Eqi 'codex_core::rollout::list: state db missing rollout path'; then
    return 0
  fi
  return 1
}

is_auth_error_line() {
  local line="$1"
  # Keep this matcher strict: it is used to fail-fast long-running child
  # processes, so broad phrases can cause false-positive aborts.
  # Ignore diff-like output lines where auth phrases may appear in content.
  if printf "%s" "$line" | grep -Eq '^[[:space:]]*(\+\+\+|---|@@|\+|-)'; then
    return 1
  fi
  # Match real Codex auth refresh failures emitted by the CLI/runtime.
  if printf "%s" "$line" | grep -Eqi '^([0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+[[:space:]]+)?ERROR[[:space:]]+codex_core::auth:[[:space:]]+Failed to refresh token:'; then
    return 0
  fi
  return 1
}

auth_error_summary() {
  local file="$1"
  local tail_buf line
  tail_buf="$(tail -n "$AUTH_SCAN_TAIL_LINES" "$file" 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if is_auth_error_line "$line"; then
      printf "%s" "$line" | cut -c1-240
      return 0
    fi
  done <<< "$tail_buf"
  return 1
}

is_login_status_unsupported_output() {
  local text="$1"
  if printf "%s" "$text" | grep -Eqi '(unknown|unrecognized|unsupported|invalid|unexpected)[[:space:][:punct:]]*(subcommand|command|argument)[^[:cntrl:]]*status'; then
    return 0
  fi
  if printf "%s" "$text" | grep -Eqi '(unknown|unrecognized|unsupported|invalid|unexpected)[[:space:][:punct:]]*(subcommand|command|argument|option|choice)[^[:cntrl:]]*status'; then
    return 0
  fi
  if printf "%s" "$text" | grep -Eqi '(subcommand|command|argument|option|choice)[^[:cntrl:]]*status[^[:cntrl:]]*(unknown|unrecognized|unsupported|invalid|unexpected|not[[:space:]]+supported|not[[:space:]]+recognized|not[[:space:]]+found|wasn'\''t expected)'; then
    return 0
  fi
  if printf "%s" "$text" | grep -Eqi 'no[[:space:]]+such[[:space:]]+(subcommand|command|option)[^[:cntrl:]]*status'; then
    return 0
  fi
  if printf "%s" "$text" | grep -Eqi 'found[[:space:]]+argument[^[:cntrl:]]*status[^[:cntrl:]]*(wasn'\''t expected|unexpected)'; then
    return 0
  fi
  return 1
}

codex_login_status_is_healthy() {
  local out_file="$1"
  local out_text
  set +e
  out_text="$(codex login status 2>&1)"
  local ec=$?
  set -e
  printf "%s\n" "$out_text" >"$out_file"

  if [[ "$ec" -ne 0 ]]; then
    if is_login_status_unsupported_output "$out_text"; then
      printf "%s\n" "login status unsupported; preflight skipped." >> "$out_file"
      return 0
    fi
    return 1
  fi

  if auth_error_summary "$out_file" >/dev/null 2>&1; then
    return 1
  fi

  if grep -Eqi 'not[[:space:]]+logged[[:space:]]+in|login[[:space:]]+required' "$out_file"; then
    return 1
  fi

  if grep -Eqi '^logged[[:space:]]+in( using| as)?' "$out_file"; then
    return 0
  fi

  # Fallback for minor output format variations while still avoiding
  # "Not logged in" false-positives.
  if grep -Eqi 'logged[[:space:]]+in' "$out_file"; then
    return 0
  fi

  return 1
}

count_error_events() {
  local phase="$1"
  local file="$2"
  local tail_buf n line
  tail_buf="$(tail -n "$ERROR_SCAN_TAIL_LINES" "$file" 2>/dev/null || true)"
  n=0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! printf "%s" "$line" | grep -Eqi '(^|[[:space:]])(ERROR:|error:|fatal:)'; then
      continue
    fi
    if [[ "$phase" == "review" ]] && is_benign_review_error_line "$line"; then
      continue
    fi
    n=$((n + 1))
  done <<< "$tail_buf"

  printf "%s" "$n"
}

phase_hint_from_output() {
  local phase="$1"
  local file="$2"
  local tail_buf
  tail_buf="$(tail -n 120 "$file" 2>/dev/null || true)"
  if auth_error_summary "$file" >/dev/null 2>&1; then
    printf "auth-error"
  elif [[ "$(count_error_events "$phase" "$file")" -gt 0 ]]; then
    printf "error"
  elif printf "%s" "$tail_buf" | grep -Eqi '(^exec$|succeeded in [0-9]+ms|in_progress)'; then
    printf "executing"
  elif printf "%s" "$tail_buf" | grep -Eqi '(^thinking$|reasoning)'; then
    printf "thinking"
  elif printf "%s" "$tail_buf" | grep -Eqi '(REVIEW_CLEAN|no issues found|no findings|looks good|lgtm)'; then
    printf "finalizing"
  else
    printf "running"
  fi
}

clean_signal_from_output() {
  local file="$1"
  if grep -Eqi '(REVIEW_CLEAN|no issues found|no issues identified|no findings|looks good|lgtm|did not identify any (actionable )?(discrete )?(defects|issues)|did not find any actionable defects|no actionable defects)' "$file"; then
    printf "possible"
  else
    printf "none"
  fi
}

file_mentions_from_output() {
  local file="$1"
  local n
  n="$(
    grep -Eo '[A-Za-z0-9_./-]+\.(swift|m|mm|h|md|sh|py|json|ya?ml|ts|js|tsx|jsx)' "$file" 2>/dev/null \
      | sort -u | wc -l | tr -d '[:space:]'
  )"
  [[ -z "$n" ]] && n=0
  printf "%s" "$n"
}

is_effort_unsupported_error() {
  local file="$1"
  grep -Eqi '(model_reasoning_effort|reasoning effort).*(supported values|must be one of|invalid|unsupported|not supported|expected)' "$file"
}

launch_in_new_process_group() {
  local out_file="$1"
  local stdin_file="$2"
  shift 2

  if have_cmd setsid; then
    if [[ -n "$stdin_file" ]]; then
      setsid "$@" <"$stdin_file" >"$out_file" 2>&1 &
    else
      setsid "$@" >"$out_file" 2>&1 &
    fi
    LAUNCH_CHILD_PID="$!"
    LAUNCH_ISOLATED="1"
    return 0
  fi

  if have_cmd python3; then
    if [[ -n "$stdin_file" ]]; then
      python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" \
        <"$stdin_file" >"$out_file" 2>&1 &
    else
      python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" \
        >"$out_file" 2>&1 &
    fi
    LAUNCH_CHILD_PID="$!"
    LAUNCH_ISOLATED="1"
    return 0
  fi

  # Fallback: no process-group isolation available.
  if [[ -n "$stdin_file" ]]; then
    "$@" <"$stdin_file" >"$out_file" 2>&1 &
  else
    "$@" >"$out_file" 2>&1 &
  fi
  LAUNCH_CHILD_PID="$!"
  LAUNCH_ISOLATED="0"
}

kill_pid_or_group() {
  local pid="$1"
  local pgid="$2"
  local self_pgid=""
  self_pgid="$(ps -o pgid= "$$" 2>/dev/null | tr -d '[:space:]' || true)"

  if [[ -n "$pgid" && "$pgid" != "$self_pgid" ]]; then
    kill -TERM "-$pgid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "-$pgid" >/dev/null 2>&1 || true
  else
    if have_cmd pkill; then
      pkill -TERM -P "$pid" >/dev/null 2>&1 || true
    fi
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    if have_cmd pkill; then
      pkill -KILL -P "$pid" >/dev/null 2>&1 || true
    fi
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
}

list_changed_files() {
  if ! have_cmd git; then
    return 0
  fi
  {
    git diff --name-only 2>/dev/null || true
    git diff --cached --name-only 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u
}

capture_changed_file_hashes() {
  local out_file="$1"
  : > "$out_file"
  if ! have_cmd git; then
    return 0
  fi

  local files_tmp
  files_tmp="$(mktemp "${TMPDIR:-/tmp}/codex-changed-files.XXXXXX")"
  list_changed_files > "$files_tmp"

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    local digest
    if [[ -d "$path" ]]; then
      digest="__DIR__"
    elif [[ -e "$path" ]]; then
      digest="$(hash_file "$path")"
    else
      digest="__MISSING__"
    fi
    printf "%s\t%s\n" "$path" "$digest" >> "$out_file"
  done < "$files_tmp"

  rm -f "$files_tmp"
}

compute_touched_files_from_snapshots() {
  local before_file="$1"
  local after_file="$2"
  local out_file="$3"
  : > "$out_file"

  if ! have_cmd python3; then
    return 1
  fi

  python3 - "$before_file" "$after_file" "$out_file" <<'PY'
import sys

before_path, after_path, out_path = sys.argv[1:]

def load(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                if "\t" in line:
                    p, h = line.split("\t", 1)
                else:
                    p, h = line, ""
                data[p] = h
    except FileNotFoundError:
        pass
    return data

before = load(before_path)
after = load(after_path)
paths = sorted(set(before) | set(after))
touched = [p for p in paths if before.get(p) != after.get(p)]

with open(out_path, "w", encoding="utf-8") as f:
    for p in touched:
        f.write(p + "\n")
PY
}

compute_scope_allowed_files() {
  local scope_mode="$1"
  local scope_base="$2"
  local scope_sha="$3"
  local out_file="$4"
  : > "$out_file"

  if ! have_cmd git; then
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/codex-scope-allowed.XXXXXX")"
  : > "$tmp_file"

  case "$scope_mode" in
    uncommitted)
      {
        git diff --name-only 2>/dev/null || true
        git diff --cached --name-only 2>/dev/null || true
        if [[ "$SCOPE_INCLUDE_UNTRACKED" == "1" ]]; then
          git ls-files --others --exclude-standard 2>/dev/null || true
        fi
      } >> "$tmp_file"
      ;;
    base)
      git diff --name-only "${scope_base}...HEAD" 2>/dev/null >> "$tmp_file" || true
      ;;
    commit)
      git diff-tree --no-commit-id --name-only -r "$scope_sha" 2>/dev/null >> "$tmp_file" || true
      if [[ ! -s "$tmp_file" ]]; then
        git show --name-only --pretty=format: "$scope_sha" 2>/dev/null >> "$tmp_file" || true
      fi
      ;;
    *)
      ;;
  esac

  if [[ -n "$SCOPE_ALLOWLIST_FILE" && -f "$SCOPE_ALLOWLIST_FILE" ]]; then
    awk 'NF && $0 !~ /^[[:space:]]*#/{print}' "$SCOPE_ALLOWLIST_FILE" >> "$tmp_file"
  fi

  sed '/^[[:space:]]*$/d' "$tmp_file" | LC_ALL=C sort -u > "$out_file"
  rm -f "$tmp_file"
}

compute_scope_violations() {
  local touched_file="$1"
  local allowed_file="$2"
  local out_file="$3"
  : > "$out_file"

  [[ -s "$touched_file" ]] || return 0
  [[ -s "$allowed_file" ]] || return 0

  if have_cmd python3; then
    python3 - "$touched_file" "$allowed_file" "$out_file" <<'PY'
import sys

touched_path, allowed_path, out_path = sys.argv[1:]

def load(path):
    values = []
    seen = set()
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            item = raw.strip()
            if not item or item in seen:
                continue
            seen.add(item)
            values.append(item)
    return values

touched = load(touched_path)
allowed = set(load(allowed_path))
violations = [p for p in touched if p not in allowed]

with open(out_path, "w", encoding="utf-8") as f:
    for p in violations:
        f.write(p + "\n")
PY
  else
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      if ! grep -Fxq -- "$path" "$allowed_file"; then
        echo "$path" >> "$out_file"
      fi
    done < "$touched_file"
  fi
}

is_safe_repo_relative_path() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != "." ]] || return 1
  [[ "$path" != ".." ]] || return 1
  [[ "$path" != ../* ]] || return 1
  [[ "$path" != */../* ]] || return 1
  [[ "$path" != */.. ]] || return 1
  [[ "$path" != *$'\n'* ]] || return 1
  return 0
}

lookup_snapshot_digest() {
  local snapshot_file="$1"
  local path="$2"
  local digest
  digest="$(awk -F'\t' -v target="$path" '$1 == target { print $2; found=1; exit } END { if (!found) print "__MISSING__" }' "$snapshot_file")"
  printf "%s" "$digest"
}

revert_new_untracked_scope_violations() {
  local before_snapshot="$1"
  local violations_file="$2"
  local reverted_file="$3"
  : > "$reverted_file"

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if ! is_safe_repo_relative_path "$path"; then
      warn "Skipping unsafe scope-violation path: '$path'"
      continue
    fi
    local before_digest
    before_digest="$(lookup_snapshot_digest "$before_snapshot" "$path")"
    [[ "$before_digest" == "__MISSING__" ]] || continue
    [[ -e "$path" || -L "$path" ]] || continue
    if have_cmd git && git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      continue
    fi
    rm -rf -- "$path"
    echo "$path" >> "$reverted_file"
  done < "$violations_file"
}

extract_forbidden_commands_from_output() {
  local in_file="$1"
  local out_file="$2"
  : > "$out_file"

  if have_cmd python3; then
    python3 - "$in_file" "$out_file" <<'PY'
import re
import sys

in_path, out_path = sys.argv[1], sys.argv[2]
lines = open(in_path, "r", encoding="utf-8", errors="ignore").read().splitlines()

cmd_line_re = re.compile(r"^[^ \t].*\s-lc\s+")
forbidden_re = re.compile(
    r"\b(xcodebuild|xcpretty)\b|"
    r"\bswift\s+(build|test|package)\b|"
    r"\bnpm\s+(install|test|run)\b|"
    r"\bpnpm\b|"
    r"\byarn\b|"
    r"\bbundle\s+exec\b|"
    r"\bpod\s+install\b|"
    r"\bcargo\s+(build|test)\b|"
    r"\bgo\s+test\b|"
    r"\bpytest\b|"
    r"\bcmake\b|"
    r"(?:^|[;&| \t])make(?:[ \t]|$)",
    re.IGNORECASE,
)

seen = set()
items = []
for line in lines:
    if not cmd_line_re.search(line):
        continue
    if not forbidden_re.search(line):
        continue
    if line in seen:
        continue
    seen.add(line)
    items.append(line)

with open(out_path, "w", encoding="utf-8") as f:
    for item in items:
        f.write(item + "\n")
PY
  else
    grep -Ei ' -lc .*([[:<:]]xcodebuild[[:>:]]|[[:<:]]xcpretty[[:>:]]|[[:<:]]swift[[:space:]]+(build|test|package)[[:>:]]|[[:<:]]npm[[:space:]]+(install|test|run)[[:>:]]|[[:<:]]pnpm[[:>:]]|[[:<:]]yarn[[:>:]]|[[:<:]]bundle[[:space:]]+exec[[:>:]]|[[:<:]]pod[[:space:]]+install[[:>:]]|[[:<:]]cargo[[:space:]]+(build|test)[[:>:]]|[[:<:]]go[[:space:]]+test[[:>:]]|[[:<:]]pytest[[:>:]]|[[:<:]]cmake[[:>:]]|(^|[;&|[:space:]])make([[:space:]]|$))' "$in_file" > "$out_file" || true
  fi
}

format_elapsed_clock() {
  local elapsed="$1"
  printf "%02d:%02d" "$((elapsed / 60))" "$((elapsed % 60))"
}

print_heartbeat() {
  local phase="$1"
  local round="$2"
  local out_file="$3"
  local elapsed="$4"

  local findings cmds errs phase_hint clean_signal file_refs
  local action message phase_label clock alert_detail auth_detail

  cmds="$(count_exec_events "$out_file")"
  errs="$(count_error_events "$phase" "$out_file")"
  phase_hint="$(phase_hint_from_output "$phase" "$out_file")"
  clock="$(format_elapsed_clock "$elapsed")"
  HEARTBEAT_AUTH_FAILURE="0"
  HEARTBEAT_AUTH_DETAIL=""
  auth_detail="$(auth_error_summary "$out_file" || true)"
  if [[ -n "$auth_detail" ]]; then
    HEARTBEAT_AUTH_FAILURE="1"
    HEARTBEAT_AUTH_DETAIL="$auth_detail"
  fi

  if [[ "$phase" == "review" ]]; then
    phase_label="review"
    findings="$(estimate_findings_count "$out_file")"
    clean_signal="$(clean_signal_from_output "$out_file")"
    if [[ "$HEARTBEAT_AUTH_FAILURE" == "1" ]]; then
      action="stop"
      message="auth failure detected; stopping review"
      alert_detail="$auth_detail"
    elif [[ "$errs" -gt 0 ]]; then
      action="stop"
      message="error detected (${errs}); review may be blocked"
      alert_detail="${errs} error(s) detected while reviewing"
    elif [[ "$findings" -gt 0 ]]; then
      action="steer"
      message="findings detected (${findings}); steer recommended"
      alert_detail="${findings} finding(s) currently reported"
    elif [[ "$clean_signal" == "possible" ]]; then
      action="continue"
      message="likely clean; waiting for final review output"
      alert_detail=""
    else
      action="continue"
      message="running; no findings yet"
      alert_detail=""
    fi
    echo "r${round}/${MAX_ROUNDS} ${phase_label} ${clock} - ${message} (cmds ${cmds}, phase ${phase_hint})"
  else
    phase_label="fix"
    file_refs="$(file_mentions_from_output "$out_file")"
    if [[ "$HEARTBEAT_AUTH_FAILURE" == "1" ]]; then
      action="stop"
      message="auth failure detected; stopping fix"
      alert_detail="$auth_detail"
    elif [[ "$errs" -gt 0 ]]; then
      action="stop"
      message="error detected (${errs}); fix may be blocked"
      alert_detail="${errs} error(s) detected while fixing"
    elif [[ "$file_refs" -gt 0 || "$cmds" -gt 0 ]]; then
      action="continue"
      message="applying changes (files ~${file_refs})"
      alert_detail=""
    else
      action="continue"
      message="starting fix phase"
      alert_detail=""
    fi
    echo "r${round}/${MAX_ROUNDS} ${phase_label} ${clock} - ${message} (cmds ${cmds}, phase ${phase_hint})"
  fi

  HEARTBEAT_PHASE_LABEL="$phase_label"
  HEARTBEAT_CLOCK="$clock"
  HEARTBEAT_ACTION="$action"
  HEARTBEAT_ALERT_DETAIL="$alert_detail"
}

run_with_heartbeat() {
  local phase="$1"
  local round="$2"
  local out_file="$3"
  local stdin_file="$4"
  shift 4

  : > "$out_file"

  set +e
  local child_pid launch_isolated phase_timeout
  LAUNCH_CHILD_PID=""
  LAUNCH_ISOLATED="0"
  LAUNCH_CHILD_PGID=""
  launch_in_new_process_group "$out_file" "$stdin_file" "$@"
  child_pid="$LAUNCH_CHILD_PID"
  launch_isolated="$LAUNCH_ISOLATED"
  [[ -n "$child_pid" ]] || die "Failed to launch command for phase '$phase'"
  local pgid=""
  if [[ "$launch_isolated" == "1" ]]; then
    pgid="$(ps -o pgid= "$child_pid" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  LAUNCH_CHILD_PGID="$pgid"
  set -e

  phase_timeout=0
  if [[ "$phase" == "review" ]]; then
    phase_timeout="$REVIEW_TIMEOUT_SECONDS"
  elif [[ "$phase" == "fix" ]]; then
    phase_timeout="$FIX_TIMEOUT_SECONDS"
  fi

  local elapsed=0
  local last_action=""
  while kill -0 "$child_pid" >/dev/null 2>&1; do
    sleep "$HEARTBEAT_SECONDS"
    elapsed=$((elapsed + HEARTBEAT_SECONDS))

    if ! kill -0 "$child_pid" >/dev/null 2>&1; then
      break
    fi

    print_heartbeat "$phase" "$round" "$out_file" "$elapsed"
    if [[ "$HEARTBEAT_ACTION" != "$last_action" && "$HEARTBEAT_ACTION" != "continue" ]]; then
      if [[ -n "$HEARTBEAT_ALERT_DETAIL" ]]; then
        echo "ALERT: r${round}/${MAX_ROUNDS} ${HEARTBEAT_PHASE_LABEL} ${HEARTBEAT_CLOCK} - ${HEARTBEAT_ACTION} recommended (${HEARTBEAT_ALERT_DETAIL})"
      else
        echo "ALERT: r${round}/${MAX_ROUNDS} ${HEARTBEAT_PHASE_LABEL} ${HEARTBEAT_CLOCK} - ${HEARTBEAT_ACTION} recommended"
      fi
    fi
    last_action="$HEARTBEAT_ACTION"

    if [[ "$HEARTBEAT_AUTH_FAILURE" == "1" ]]; then
      warn "Authentication failure detected during ${phase}: ${HEARTBEAT_AUTH_DETAIL}"
      kill_pid_or_group "$child_pid" "$pgid"
      wait "$child_pid" >/dev/null 2>&1 || true
      LAUNCH_CHILD_PID=""
      LAUNCH_ISOLATED="0"
      LAUNCH_CHILD_PGID=""
      return "$AUTH_ERROR_EXIT_CODE"
    fi

    if [[ "$phase_timeout" -gt 0 && "$elapsed" -ge "$phase_timeout" ]]; then
      warn "${phase} timed out after ${phase_timeout}s in round ${round}; terminating active command."
      kill_pid_or_group "$child_pid" "$pgid"
      wait "$child_pid" >/dev/null 2>&1 || true
      LAUNCH_CHILD_PID=""
      LAUNCH_ISOLATED="0"
      LAUNCH_CHILD_PGID=""
      return 124
    fi

    # Steering during in-flight command:
    # - stop is applied immediately
    # - other control updates are applied between rounds
    read_control_file
    if [[ "$CF_STATUS" == "stop" ]]; then
      warn "Control requested stop during ${phase}; terminating active command."
      kill_pid_or_group "$child_pid" "$pgid"
      wait "$child_pid" >/dev/null 2>&1 || true
      LAUNCH_CHILD_PID=""
      LAUNCH_ISOLATED="0"
      LAUNCH_CHILD_PGID=""
      return 130
    fi
  done

  set +e
  wait "$child_pid"
  local ec=$?
  set -e
  LAUNCH_CHILD_PID=""
  LAUNCH_ISOLATED="0"
  LAUNCH_CHILD_PGID=""
  if [[ "$ec" -ne 0 ]] && auth_error_summary "$out_file" >/dev/null 2>&1; then
    return "$AUTH_ERROR_EXIT_CODE"
  fi
  return $ec
}

run_with_timeout_retry() {
  local phase="$1"
  local round="$2"
  local out_file="$3"
  local stdin_file="$4"
  local retries="$5"
  shift 5

  local ec=0
  local retry_count=0
  local auth_retry_count=0
  while true; do
    run_with_heartbeat "$phase" "$round" "$out_file" "$stdin_file" "$@"
    ec=$?
    if [[ "$ec" -eq 124 && "$phase" == "review" && "$retry_count" -lt "$retries" ]]; then
      retry_count=$((retry_count + 1))
      warn "Review timed out; retrying (${retry_count}/${retries})."
      continue
    fi
    if [[ "$ec" -eq "$AUTH_ERROR_EXIT_CODE" ]] \
      && auth_error_summary "$out_file" >/dev/null 2>&1 \
      && [[ "$auth_retry_count" -lt "$AUTH_FAILURE_RETRIES" ]]; then
      auth_retry_count=$((auth_retry_count + 1))
      local auth_status_file="${RUN_DIR}/round-${round}-${phase}-auth-retry-${auth_retry_count}.txt"
      if codex_login_status_is_healthy "$auth_status_file"; then
        warn "Auth failure looked transient; retrying ${phase} (${auth_retry_count}/${AUTH_FAILURE_RETRIES})."
        sleep 2
        continue
      fi
    fi
    return "$ec"
  done
}

is_review_clean_output() {
  local file="$1"
  local review_ec="$2"
  local findings_count="$3"
  local trimmed nonempty_count
  trimmed="$(trim "$(cat "$file")")"
  nonempty_count="$(count_nonempty_lines "$file")"

  # Preferred deterministic sentinel.
  if [[ "$trimmed" == "REVIEW_CLEAN" ]]; then
    return 0
  fi

  # Non-zero review command should not be treated as clean.
  if [[ "$review_ec" -ne 0 ]]; then
    return 1
  fi

  # Parsed findings are the primary signal.
  if [[ "$findings_count" -gt 0 ]]; then
    return 1
  fi

  # Fatal review errors in the recent tail region mean not clean.
  if [[ "$(count_error_events "review" "$file")" -gt 0 ]]; then
    return 1
  fi

  # Strict anchored clean lines in the tail section.
  if tail -n 120 "$file" | grep -Eiq '^[[:space:]]*(REVIEW_CLEAN|No issues found\.?|No issues identified\.?|No findings\.?)\s*$'; then
    return 0
  fi

  # Common reviewer "clean" prose, still guarded by zero findings/errors above.
  if tail -n 120 "$file" | grep -Eiq '(I did not identify any (actionable )?(discrete )?(defects|issues)|I did not find any actionable defects|no actionable defects)'; then
    return 0
  fi

  # Fuzzy clean phrases are accepted when strongly anchored.
  if [[ "$nonempty_count" -le 80 ]] && tail -n 120 "$file" | grep -Eiq '^[[:space:]]*(Looks good\.?|LGTM\.?)\s*$'; then
    return 0
  fi

  return 1
}

# Reads control file and sets CF_* globals.
read_control_file() {
  CF_STATUS="resume"
  CF_APPEND_CONTEXT=""
  CF_REVIEW_SELECTOR=""
  CF_FIX_SELECTOR=""
  CF_SCOPE_OVERRIDE=""

  [[ -f "$CONTROL_FILE" ]] || return 0

  local h
  h="$(hash_file "$CONTROL_FILE")"
  if [[ "$h" != "$LAST_CONTROL_HASH" ]]; then
    LAST_CONTROL_HASH="$h"
    echo "$(date +%Y-%m-%dT%H:%M:%S%z) hash=$h file=$CONTROL_FILE" >> "$RUN_DIR/control-snapshots.log"
  fi

  # status, review_model, fix_model, scope (simple key:value parsing)
  local status_line review_line fix_line scope_line
  status_line="$(grep -E '^[[:space:]]*status[[:space:]]*:' "$CONTROL_FILE" | head -n1 || true)"
  review_line="$(grep -E '^[[:space:]]*review_model[[:space:]]*:' "$CONTROL_FILE" | head -n1 || true)"
  fix_line="$(grep -E '^[[:space:]]*fix_model[[:space:]]*:' "$CONTROL_FILE" | head -n1 || true)"
  scope_line="$(grep -E '^[[:space:]]*scope[[:space:]]*:' "$CONTROL_FILE" | head -n1 || true)"

  if [[ -n "$status_line" ]]; then
    CF_STATUS="$(echo "$status_line" | sed -E 's/^[[:space:]]*status[[:space:]]*:[[:space:]]*//')"
    CF_STATUS="$(trim "$CF_STATUS")"
  fi
  if [[ -n "$review_line" ]]; then
    CF_REVIEW_SELECTOR="$(echo "$review_line" | sed -E 's/^[[:space:]]*review_model[[:space:]]*:[[:space:]]*//')"
    CF_REVIEW_SELECTOR="$(trim "$CF_REVIEW_SELECTOR")"
  fi
  if [[ -n "$fix_line" ]]; then
    CF_FIX_SELECTOR="$(echo "$fix_line" | sed -E 's/^[[:space:]]*fix_model[[:space:]]*:[[:space:]]*//')"
    CF_FIX_SELECTOR="$(trim "$CF_FIX_SELECTOR")"
  fi
  if [[ -n "$scope_line" ]]; then
    CF_SCOPE_OVERRIDE="$(echo "$scope_line" | sed -E 's/^[[:space:]]*scope[[:space:]]*:[[:space:]]*//')"
    CF_SCOPE_OVERRIDE="$(trim "$CF_SCOPE_OVERRIDE")"
  fi

  # append_context parsing:
  # Supports either:
  #   append_context: one line
  # or:
  #   append_context: |
  #     indented multi line
  # Multi-line block now requires indentation; first non-indented line ends the block.
  local ac_line
  ac_line="$(grep -nE '^[[:space:]]*append_context[[:space:]]*:' "$CONTROL_FILE" | head -n1 || true)"
  if [[ -n "$ac_line" ]]; then
    local ln
    ln="$(echo "$ac_line" | cut -d: -f1)"
    local rhs
    rhs="$(echo "$ac_line" | cut -d: -f2- | sed -E 's/^[[:space:]]*append_context[[:space:]]*:[[:space:]]*//')"
    rhs="$(trim "$rhs")"

    if [[ "$rhs" == "|" || "$rhs" == "|-" || "$rhs" == "|+" || -z "$rhs" ]]; then
      # Read indented lines only; stop at first non-indented line.
      CF_APPEND_CONTEXT="$(awk -v start="$ln" '
        NR <= start {next}
        # blank lines within a block are allowed
        /^[[:space:]]*$/ {print ""; next}
        # block content must be indented
        /^[^[:space:]]/ {exit}
        { sub(/^[[:space:]]/, "", $0); print }
      ' "$CONTROL_FILE")"
    else
      CF_APPEND_CONTEXT="$rhs"
    fi
  fi

  # normalize status
  case "$CF_STATUS" in
    pause|resume|stop) ;;
    *)
      warn "Control file: invalid status '$CF_STATUS' (expected pause|resume|stop). Ignoring."
      CF_STATUS="resume"
      ;;
  esac
}

apply_control_overrides_between_rounds() {
  read_control_file

  if [[ "$CF_STATUS" == "stop" ]]; then
    print_phase "Control requested stop. Exiting (artifacts kept at $RUN_DIR)."
    exit 130
  fi

  while [[ "$CF_STATUS" == "pause" ]]; do
    echo "PAUSED: edit '$CONTROL_FILE' and set 'status: resume' (or 'stop')."
    sleep 2
    read_control_file
    if [[ "$CF_STATUS" == "stop" ]]; then
      print_phase "Control requested stop. Exiting (artifacts kept at $RUN_DIR)."
      exit 130
    fi
  done
}

resolve_scope() {
  # Apply control-file scope override if present
  local mode="$SCOPE_MODE"
  local base="$SCOPE_BASE_BRANCH"
  local sha="$SCOPE_COMMIT_SHA"

  if [[ -n "$CF_SCOPE_OVERRIDE" ]]; then
    case "$CF_SCOPE_OVERRIDE" in
      uncommitted)
        mode="uncommitted"; base=""; sha=""
        ;;
      base:*)
        mode="base"; base="${CF_SCOPE_OVERRIDE#base:}"; sha=""
        ;;
      commit:*)
        mode="commit"; sha="${CF_SCOPE_OVERRIDE#commit:}"; base=""
        ;;
      *)
        warn "Control file: invalid scope '$CF_SCOPE_OVERRIDE' (expected uncommitted|base:<branch>|commit:<sha>). Ignoring."
        ;;
    esac
  fi

  printf "%s\n%s\n%s\n" "$mode" "$base" "$sha"
}

build_review_prompt() {
  local user_prompt=""
  if [[ -n "$REVIEW_PROMPT_FILE" ]]; then
    [[ -f "$REVIEW_PROMPT_FILE" ]] || die "--review-prompt-file not found: $REVIEW_PROMPT_FILE"
    user_prompt="$(cat "$REVIEW_PROMPT_FILE")"
  elif [[ -n "$REVIEW_PROMPT" ]]; then
    if [[ -f "$REVIEW_PROMPT" ]]; then
      user_prompt="$(cat "$REVIEW_PROMPT")"
    else
      user_prompt="$REVIEW_PROMPT"
    fi
  else
    # Default review prompt: practical and deterministic clean sentinel
    user_prompt="$(cat <<'PROMPT'
You are a strict code reviewer.

Review the provided diff for:
- correctness (logic, edge cases)
- tests (missing/incorrect)
- security footguns
- performance regressions
- API/behavior changes that are not justified
- code style issues that could cause bugs

Be concrete and actionable. Prefer small, high-signal findings over exhaustive nitpicks.

Output format:
- If you find any issues, list them as bullet points. Each bullet should be a single issue with a clear fix suggestion.
- If there are zero issues, output exactly: REVIEW_CLEAN
PROMPT
)"
  fi

  # Always enforce the sentinel (even if user supplies custom prompt)
  cat <<EOF
${user_prompt}

IMPORTANT: If there are zero issues, output exactly REVIEW_CLEAN and nothing else.
EOF
}

build_fix_prompt() {
  local review_file="$1"
  local append_context="$2"
  local allowed_files_file="$3"

  local review_text
  review_text="$(cat "$review_file")"

  cat <<EOF
You are an autonomous coding agent fixing issues found by a code review.

Goal:
- Fix the issues described in the review output below.
- Keep changes minimal and directly tied to the findings.
- Do not introduce unrelated refactors.
- Do not run build/test/lint/package-install commands in this fix pass.
- Focus on source edits only; validation happens in a separate step.

Review output (verbatim):
------------------------
$review_text
------------------------

EOF

  if [[ -f "$allowed_files_file" ]]; then
    local allowed_count
    allowed_count="$(count_nonempty_lines "$allowed_files_file")"
    if [[ "$allowed_count" -gt 0 ]]; then
      cat <<EOF
Allowed edit scope:
- Keep edits strictly within the scope files listed below.
- If a required fix is outside this list, stop and explain exactly which path is needed.

Scope files:
EOF
      awk 'NF{print "- " $0; c++; if (c>=300) exit}' "$allowed_files_file"
      if [[ "$allowed_count" -gt 300 ]]; then
        echo "- ... (${allowed_count} total files; truncated to first 300)"
      fi
      echo ""
    fi
  fi

  if [[ -n "$(trim "$append_context")" ]]; then
    cat <<EOF
Additional user steering context:
------------------------
$append_context
------------------------

EOF
  fi

  cat <<'EOF'
Deliverable:
- Apply fixes in the repository.
- Summarize what you changed and why.
- List any commands you ran and their results.
- Allowed commands should be read/edit/git introspection only.

Do NOT run anything destructive.
EOF
}

run_review() {
  local round="$1"
  local scope_mode="$2"
  local scope_base="$3"
  local scope_sha="$4"
  local review_model_id="$5"
  local review_effort="$6"
  local out_file="$7"

  local args_base=()
  case "$scope_mode" in
    uncommitted) args_base+=(--uncommitted) ;;
    base)        args_base+=(--base "$scope_base") ;;
    commit)      args_base+=(--commit "$scope_sha") ;;
    *) die "internal: unknown scope_mode '$scope_mode'" ;;
  esac

  # Title helps identify runs in Codex history (optional)
  args_base+=(--title "review-fix-loop round ${round}")

  # Config overrides:
  # - review_model: sets the model for /review; used here as a best-effort override for codex review too
  if [[ -n "$review_model_id" ]]; then
    args_base+=(--config "review_model=$review_model_id")
  fi

  local -a effort_candidates=()
  if [[ -n "$review_effort" ]]; then
    effort_candidates+=("$review_effort")
    [[ "$review_effort" != "high" ]] && effort_candidates+=("high")
    [[ "$review_effort" != "medium" ]] && effort_candidates+=("medium")
  else
    effort_candidates+=("")
  fi

  local ec=0
  local effort_try
  for effort_try in "${effort_candidates[@]}"; do
    local args=("${args_base[@]}")
    if [[ -n "$effort_try" ]]; then
      args+=(--config "model_reasoning_effort=$effort_try")
    fi

    # Default to plain mode because current codex review commonly rejects prompt
    # with --uncommitted/--base/--commit.
    if [[ "$REVIEW_PROMPT_MODE" == "plain" ]]; then
      run_with_timeout_retry "review" "$round" "$out_file" "" "$REVIEW_TIMEOUT_RETRIES" codex review "${args[@]}"
      ec=$?
    else
      local prompt
      prompt="$(build_review_prompt)"
      local review_prompt_file="${RUN_DIR}/round-${round}-review-prompt.txt"
      printf "%s" "$prompt" > "$review_prompt_file"

      run_with_timeout_retry "review" "$round" "$out_file" "$review_prompt_file" "$REVIEW_TIMEOUT_RETRIES" codex review "${args[@]}" -
      ec=$?
      if [[ "$ec" -ne 0 ]] && grep -q "cannot be used with '\\[PROMPT\\]'" "$out_file"; then
        if [[ "$REVIEW_PROMPT_MODE" == "auto" ]]; then
          warn "codex review prompt input is not supported for this scope on this CLI; retrying without prompt."
          run_with_timeout_retry "review" "$round" "$out_file" "" "$REVIEW_TIMEOUT_RETRIES" codex review "${args[@]}"
          ec=$?
        else
          warn "codex review prompt mode requested, but this CLI/scope combination does not support prompt input."
        fi
      fi
    fi

    if [[ "$ec" -eq 0 ]]; then
      LAST_EFFECTIVE_REVIEW_EFFORT="$effort_try"
      return 0
    fi

    if [[ -n "$effort_try" ]] && is_effort_unsupported_error "$out_file"; then
      warn "Review effort '$effort_try' was rejected by model/CLI; retrying with fallback effort."
      continue
    fi

    LAST_EFFECTIVE_REVIEW_EFFORT="$effort_try"
    return "$ec"
  done

  LAST_EFFECTIVE_REVIEW_EFFORT="$review_effort"
  return "$ec"
}

run_fix() {
  local round="$1"
  local fix_model_id="$2"
  local fix_effort="$3"
  local fix_prompt_file="$4"
  local out_file="$5"

  local args_base=()

  # Force headless execution with sandboxed automatic command handling.
  args_base+=(--full-auto)
  args_base+=(--sandbox workspace-write)

  if [[ -n "$fix_model_id" ]]; then
    args_base+=(--model "$fix_model_id")
  fi

  local -a effort_candidates=()
  if [[ -n "$fix_effort" ]]; then
    effort_candidates+=("$fix_effort")
    [[ "$fix_effort" != "high" ]] && effort_candidates+=("high")
    [[ "$fix_effort" != "medium" ]] && effort_candidates+=("medium")
  else
    effort_candidates+=("")
  fi

  local ec=0
  local effort_try
  for effort_try in "${effort_candidates[@]}"; do
    local args=("${args_base[@]}")
    if [[ -n "$effort_try" ]]; then
      args+=(--config "model_reasoning_effort=$effort_try")
    fi

    run_with_timeout_retry "fix" "$round" "$out_file" "$fix_prompt_file" 0 codex exec "${args[@]}" -
    ec=$?
    if [[ "$ec" -eq 0 ]]; then
      LAST_EFFECTIVE_FIX_EFFORT="$effort_try"
      return 0
    fi

    if [[ -n "$effort_try" ]] && is_effort_unsupported_error "$out_file"; then
      warn "Fix effort '$effort_try' was rejected by model/CLI; retrying with fallback effort."
      continue
    fi

    LAST_EFFECTIVE_FIX_EFFORT="$effort_try"
    return "$ec"
  done

  LAST_EFFECTIVE_FIX_EFFORT="$fix_effort"
  return "$ec"
}

on_interrupt() {
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

# --------------------------- Arg parsing -------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uncommitted)
      SCOPE_MODE="uncommitted"; SCOPE_BASE_BRANCH=""; SCOPE_COMMIT_SHA=""
      shift
      ;;
    --base)
      [[ $# -ge 2 ]] || die "--base requires <branch>"
      SCOPE_MODE="base"; SCOPE_BASE_BRANCH="$2"; SCOPE_COMMIT_SHA=""
      shift 2
      ;;
    --commit)
      [[ $# -ge 2 ]] || die "--commit requires <sha>"
      SCOPE_MODE="commit"; SCOPE_COMMIT_SHA="$2"; SCOPE_BASE_BRANCH=""
      shift 2
      ;;
    --max-rounds)
      [[ $# -ge 2 ]] || die "--max-rounds requires <n>"
      MAX_ROUNDS="$2"
      shift 2
      ;;
    --loop-mode)
      [[ $# -ge 2 ]] || die "--loop-mode requires <conservative|balanced>"
      REVIEW_LOOP_MODE="$2"
      shift 2
      ;;
    --scope-include-untracked)
      SCOPE_INCLUDE_UNTRACKED="1"
      shift
      ;;
    --scope-ignore-untracked)
      SCOPE_INCLUDE_UNTRACKED="0"
      shift
      ;;
    --scope-allowlist-file)
      [[ $# -ge 2 ]] || die "--scope-allowlist-file requires <path>"
      SCOPE_ALLOWLIST_FILE="$2"
      shift 2
      ;;
    --fail-on-scope-violation)
      [[ $# -ge 2 ]] || die "--fail-on-scope-violation requires <0|1>"
      FAIL_ON_SCOPE_VIOLATION="$2"
      shift 2
      ;;
    --revert-scope-violation-untracked)
      [[ $# -ge 2 ]] || die "--revert-scope-violation-untracked requires <0|1>"
      REVERT_SCOPE_VIOLATION_UNTRACKED="$2"
      shift 2
      ;;
    --fail-on-forbidden-commands)
      [[ $# -ge 2 ]] || die "--fail-on-forbidden-commands requires <0|1>"
      FAIL_ON_FORBIDDEN_COMMANDS="$2"
      shift 2
      ;;
    --review-model-early)
      [[ $# -ge 2 ]] || die "--review-model-early requires <id|effort|model@effort>"
      REVIEW_MODEL_EARLY="$2"
      shift 2
      ;;
    --review-model-late)
      [[ $# -ge 2 ]] || die "--review-model-late requires <id|effort|model@effort>"
      REVIEW_MODEL_LATE="$2"
      shift 2
      ;;
    --fix-model)
      [[ $# -ge 2 ]] || die "--fix-model requires <id|effort|model@effort>"
      FIX_MODEL_EARLY="$2"
      FIX_MODEL_LATE="$2"
      shift 2
      ;;
    --fix-model-early)
      [[ $# -ge 2 ]] || die "--fix-model-early requires <id|effort|model@effort>"
      FIX_MODEL_EARLY="$2"
      shift 2
      ;;
    --fix-model-late)
      [[ $# -ge 2 ]] || die "--fix-model-late requires <id|effort|model@effort>"
      FIX_MODEL_LATE="$2"
      shift 2
      ;;
    --review-model-id)
      [[ $# -ge 2 ]] || die "--review-model-id requires <model_id>"
      REVIEW_MODEL_ID="$2"
      shift 2
      ;;
    --fix-model-id)
      [[ $# -ge 2 ]] || die "--fix-model-id requires <model_id>"
      FIX_MODEL_ID="$2"
      shift 2
      ;;
    --review-prompt-mode)
      [[ $# -ge 2 ]] || die "--review-prompt-mode requires <plain|prompt|auto>"
      REVIEW_PROMPT_MODE="$2"
      shift 2
      ;;
    --review-prompt-file)
      [[ $# -ge 2 ]] || die "--review-prompt-file requires <path>"
      REVIEW_PROMPT_FILE="$2"
      shift 2
      ;;
    --heartbeat-seconds)
      [[ $# -ge 2 ]] || die "--heartbeat-seconds requires <n>"
      HEARTBEAT_SECONDS="$2"
      shift 2
      ;;
    --review-timeout-seconds)
      [[ $# -ge 2 ]] || die "--review-timeout-seconds requires <n>"
      REVIEW_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --fix-timeout-seconds)
      [[ $# -ge 2 ]] || die "--fix-timeout-seconds requires <n>"
      FIX_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --review-timeout-retries)
      [[ $# -ge 2 ]] || die "--review-timeout-retries requires <n>"
      REVIEW_TIMEOUT_RETRIES="$2"
      shift 2
      ;;
    --auth-failure-retries)
      [[ $# -ge 2 ]] || die "--auth-failure-retries requires <n>"
      AUTH_FAILURE_RETRIES="$2"
      shift 2
      ;;
    --auth-scan-tail-lines)
      [[ $# -ge 2 ]] || die "--auth-scan-tail-lines requires <n>"
      AUTH_SCAN_TAIL_LINES="$2"
      shift 2
      ;;
    --error-scan-tail-lines)
      [[ $# -ge 2 ]] || die "--error-scan-tail-lines requires <n>"
      ERROR_SCAN_TAIL_LINES="$2"
      shift 2
      ;;
    --control-file)
      [[ $# -ge 2 ]] || die "--control-file requires <path>"
      CONTROL_FILE="$2"
      shift 2
      ;;
    --artifacts-dir)
      [[ $# -ge 2 ]] || die "--artifacts-dir requires <path>"
      ARTIFACTS_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown arg: $1"
      ;;
  esac
done

# Validate scope exclusivity implicitly by parsing: only one mode is active
# Validate rounds integer
apply_mode_defaults
[[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]] || die "--max-rounds must be an integer"
[[ "$HEARTBEAT_SECONDS" =~ ^[0-9]+$ ]] || die "--heartbeat-seconds must be an integer"
[[ "$HEARTBEAT_SECONDS" -gt 0 ]] || die "--heartbeat-seconds must be > 0"
[[ "$REVIEW_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--review-timeout-seconds must be an integer"
[[ "$FIX_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--fix-timeout-seconds must be an integer"
[[ "$REVIEW_TIMEOUT_RETRIES" =~ ^[0-9]+$ ]] || die "--review-timeout-retries must be an integer"
[[ "$AUTH_FAILURE_RETRIES" =~ ^[0-9]+$ ]] || die "--auth-failure-retries must be an integer"
[[ "$AUTH_SCAN_TAIL_LINES" =~ ^[0-9]+$ ]] || die "--auth-scan-tail-lines must be an integer"
[[ "$AUTH_SCAN_TAIL_LINES" -gt 0 ]] || die "--auth-scan-tail-lines must be > 0"
[[ "$ERROR_SCAN_TAIL_LINES" =~ ^[0-9]+$ ]] || die "--error-scan-tail-lines must be an integer"
[[ "$ERROR_SCAN_TAIL_LINES" -gt 0 ]] || die "--error-scan-tail-lines must be > 0"
validate_toggle_01 "--scope-include-untracked/--scope-ignore-untracked" "$SCOPE_INCLUDE_UNTRACKED"
validate_toggle_01 "--fail-on-scope-violation" "$FAIL_ON_SCOPE_VIOLATION"
validate_toggle_01 "--revert-scope-violation-untracked" "$REVERT_SCOPE_VIOLATION_UNTRACKED"
validate_toggle_01 "--fail-on-forbidden-commands" "$FAIL_ON_FORBIDDEN_COMMANDS"
if [[ -n "$SCOPE_ALLOWLIST_FILE" && ! -f "$SCOPE_ALLOWLIST_FILE" ]]; then
  die "--scope-allowlist-file not found: $SCOPE_ALLOWLIST_FILE"
fi
case "$REVIEW_PROMPT_MODE" in
  plain|prompt|auto) ;;
  *) die "--review-prompt-mode must be one of: plain|prompt|auto" ;;
esac

# ------------------------------ Main -----------------------------------------

trap on_interrupt INT TERM

ensure_codex
ensure_git_repo
mk_run_dir

print_phase "Artifacts: $RUN_DIR"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Planned:"
  echo "- Scope default: $SCOPE_MODE"
  echo "- Loop mode: $REVIEW_LOOP_MODE"
  echo "- Scope include untracked: $SCOPE_INCLUDE_UNTRACKED"
  echo "- Scope allowlist file: ${SCOPE_ALLOWLIST_FILE:-<none>}"
  echo "- Fail on scope violation: $FAIL_ON_SCOPE_VIOLATION"
  echo "- Revert untracked scope violations: $REVERT_SCOPE_VIOLATION_UNTRACKED"
  echo "- Fail on forbidden commands: $FAIL_ON_FORBIDDEN_COMMANDS"
  echo "- Max rounds: $MAX_ROUNDS"
  echo "- Review selector early: $REVIEW_MODEL_EARLY"
  echo "- Review selector late:  $REVIEW_MODEL_LATE"
  echo "- Fix selector early:    $FIX_MODEL_EARLY"
  echo "- Fix selector late:     $FIX_MODEL_LATE"
  echo "- Review prompt mode:    $REVIEW_PROMPT_MODE"
  echo "- Heartbeat seconds:     $HEARTBEAT_SECONDS"
  echo "- Review timeout sec:    $REVIEW_TIMEOUT_SECONDS"
  echo "- Fix timeout sec:       $FIX_TIMEOUT_SECONDS"
  echo "- Review timeout retries:$REVIEW_TIMEOUT_RETRIES"
  echo "- Auth failure retries:  $AUTH_FAILURE_RETRIES"
  echo "- Auth scan tail lines:  $AUTH_SCAN_TAIL_LINES"
  echo "- Error scan tail lines: $ERROR_SCAN_TAIL_LINES"
  echo "- Review model id override: ${REVIEW_MODEL_ID:-<none>}"
  echo "- Fix model id override:    ${FIX_MODEL_ID:-<none>}"
  echo "- Finding fuzzy reconcile:  ${FINDINGS_FUZZY}"
  echo "- Finding fuzzy threshold:  ${FINDINGS_FUZZY_THRESHOLD}"
  echo "- Control file: $CONTROL_FILE"
  exit 0
fi

login_status_file="${RUN_DIR}/login-status-preflight.txt"
if ! ensure_codex_login_healthy "$login_status_file"; then
  print_phase "❌ Codex authentication preflight failed. Artifacts at $RUN_DIR"
  exit 2
fi

# Run summary state
CLEAN="false"
ROUNDS_RUN=0
PREV_FINDINGS_FILE=""
PREV_FINDINGS_ROUND=""

for ((round=1; round<=MAX_ROUNDS; round++)); do
  ROUNDS_RUN=$round

  # Poll control file between rounds (including before round 1)
  apply_control_overrides_between_rounds

  # Resolve current scope (may be overridden by control file)
  scope_lines="$(resolve_scope)"
  scope_mode="$(echo "$scope_lines" | sed -n '1p')"
  scope_base="$(echo "$scope_lines" | sed -n '2p')"
  scope_sha="$(echo "$scope_lines" | sed -n '3p')"

  scope_desc="$scope_mode"
  [[ "$scope_mode" == "base" ]] && scope_desc="base:${scope_base}"
  [[ "$scope_mode" == "commit" ]] && scope_desc="commit:${scope_sha}"

  # Select review/fix selectors (control overrides win)
  round_review_selector="$(select_review_selector_for_round "$round")"
  [[ -n "$CF_REVIEW_SELECTOR" ]] && round_review_selector="$CF_REVIEW_SELECTOR"
  round_fix_selector="$(select_fix_selector_for_round "$round")"
  [[ -n "$CF_FIX_SELECTOR" ]] && round_fix_selector="$CF_FIX_SELECTOR"

  # Parse selectors
  # Review: default effort = (if selector is effort, it sets it; else default to high)
  parsed="$(parse_selector "$round_review_selector" "$REVIEW_MODEL_ID" "high")"
  review_model_id="$(echo "$parsed" | sed -n '1p')"
  review_effort="$(echo "$parsed" | sed -n '2p')"

  parsed="$(parse_selector "$round_fix_selector" "$FIX_MODEL_ID" "high")"
  fix_model_id="$(echo "$parsed" | sed -n '1p')"
  fix_effort="$(echo "$parsed" | sed -n '2p')"

  review_file="$RUN_DIR/round-${round}-review.txt"
  fix_file="$RUN_DIR/round-${round}-fix.txt"
  meta_file="$RUN_DIR/round-${round}-meta.json"
  fix_prompt_file="$RUN_DIR/round-${round}-fix-prompt.txt"

  print_phase "[${round}/${MAX_ROUNDS}] review (scope=${scope_desc} model_id=${review_model_id:-<default>} effort=${review_effort:-<default>})"
  review_ec=0
  LAST_EFFECTIVE_REVIEW_EFFORT=""
  if run_review "$round" "$scope_mode" "$scope_base" "$scope_sha" "$review_model_id" "$review_effort" "$review_file"; then
    review_ec=0
  else
    review_ec=$?
    if [[ "$review_ec" -eq 130 ]]; then
      print_phase "Stopped during review (artifacts kept at $RUN_DIR)."
      exit 130
    fi
    if [[ "$review_ec" -eq "$AUTH_ERROR_EXIT_CODE" ]] && auth_error_summary "$review_file" >/dev/null 2>&1; then
      warn "Authentication failed during review; aborting loop."
      warn "Run 'codex logout' then 'codex login', then re-run this skill."
      print_phase "❌ Review stopped due to authentication failure. Artifacts at $RUN_DIR"
      exit 2
    fi
    warn "Review command exited non-zero (exit=$review_ec). Continuing."
  fi

  review_effort_used="${LAST_EFFECTIVE_REVIEW_EFFORT:-$review_effort}"
  if [[ "$review_ec" -eq 124 ]]; then
    echo "[${round}/${MAX_ROUNDS}] review timed out after retries; skipping fix and continuing."
    write_meta_json "$meta_file" "$round" "$scope_desc" "$review_model_id" "$review_effort_used" "$fix_model_id" "$fix_effort" "$review_ec" 124 false 0
    continue
  fi

  findings_file="$RUN_DIR/round-${round}-findings.txt"
  extract_review_findings "$review_file" "$findings_file"
  findings_parsed="$(count_nonempty_lines "$findings_file")"

  # Determine clean (parsed findings are primary; sentinel/strict anchors are fallback).
  if is_review_clean_output "$review_file" "$review_ec" "$findings_parsed"; then
    CLEAN="true"
  else
    CLEAN="false"
  fi

  findings_est="$(estimate_findings_count "$review_file")"
  if [[ "$CLEAN" == "true" ]]; then
    echo "[${round}/${MAX_ROUNDS}] ✅ CLEAN (findings≈0)"
    if [[ -n "$PREV_FINDINGS_FILE" && -f "$PREV_FINDINGS_FILE" ]]; then
      resolved_file="$RUN_DIR/round-${round}-resolved-findings.txt"
      remaining_file="$RUN_DIR/round-${round}-remaining-findings.txt"
      new_file="$RUN_DIR/round-${round}-new-findings.txt"
      reworded_file="$RUN_DIR/round-${round}-likely-reworded-findings.txt"
      compare_finding_sets "$PREV_FINDINGS_FILE" "$findings_file" "$resolved_file" "$remaining_file" "$new_file" "$reworded_file"
      resolved_count="$(count_nonempty_lines "$resolved_file")"
      if [[ "$resolved_count" -gt 0 ]]; then
        echo "Resolved since round ${PREV_FINDINGS_ROUND}:"
        print_indented_list "$resolved_file"
      fi
    fi
    write_meta_json "$meta_file" "$round" "$scope_desc" "$review_model_id" "$review_effort_used" "$fix_model_id" "$fix_effort" "$review_ec" 0 true 0
    break
  fi

  echo "[${round}/${MAX_ROUNDS}] ❌ NOT CLEAN (findings≈${findings_est}, parsed=${findings_parsed})"
  if [[ "$findings_parsed" -gt 0 ]]; then
    echo "Review findings:"
    print_indented_list "$findings_file"
  else
    echo "Findings preview:"
    preview_nonempty_lines "$review_file" 12 | sed 's/^/  /'
  fi

  if [[ -n "$PREV_FINDINGS_FILE" && -f "$PREV_FINDINGS_FILE" ]]; then
    resolved_file="$RUN_DIR/round-${round}-resolved-findings.txt"
    remaining_file="$RUN_DIR/round-${round}-remaining-findings.txt"
    new_file="$RUN_DIR/round-${round}-new-findings.txt"
    reworded_file="$RUN_DIR/round-${round}-likely-reworded-findings.txt"
    compare_finding_sets "$PREV_FINDINGS_FILE" "$findings_file" "$resolved_file" "$remaining_file" "$new_file" "$reworded_file"
    resolved_count="$(count_nonempty_lines "$resolved_file")"
    remaining_count="$(count_nonempty_lines "$remaining_file")"
    new_count="$(count_nonempty_lines "$new_file")"
    reworded_count="$(count_nonempty_lines "$reworded_file")"
    echo "Finding delta vs round ${PREV_FINDINGS_ROUND}: resolved=${resolved_count}, remaining=${remaining_count}, likely_reworded=${reworded_count}, new=${new_count}"
    if [[ "$resolved_count" -gt 0 ]]; then
      echo "Resolved:"
      print_indented_list "$resolved_file"
    fi
    if [[ "$remaining_count" -gt 0 ]]; then
      echo "Still open:"
      print_indented_list "$remaining_file"
    fi
    if [[ "$reworded_count" -gt 0 ]]; then
      echo "Likely remaining (reworded):"
      print_indented_list "$reworded_file"
    fi
    if [[ "$new_count" -gt 0 ]]; then
      echo "New:"
      print_indented_list "$new_file"
    fi
  fi

  # Build fix prompt (includes full review output)
  allowed_files_file="$RUN_DIR/round-${round}-allowed-files.txt"
  compute_scope_allowed_files "$scope_mode" "$scope_base" "$scope_sha" "$allowed_files_file"
  allowed_scope_count="$(count_nonempty_lines "$allowed_files_file")"
  if [[ "$allowed_scope_count" -eq 0 ]]; then
    warn "Computed allowed scope is empty for round ${round} (scope=${scope_desc})."
    if [[ "$FAIL_ON_SCOPE_VIOLATION" == "1" ]]; then
      warn "Scope-violation hard-fail is enabled; consider --scope-include-untracked or --scope-allowlist-file."
    fi
  fi
  fix_prompt="$(build_fix_prompt "$review_file" "$CF_APPEND_CONTEXT" "$allowed_files_file")"
  printf "%s" "$fix_prompt" > "$fix_prompt_file"

  print_phase "[${round}/${MAX_ROUNDS}] fix (model_id=${fix_model_id:-<default>} effort=${fix_effort:-<default>})"
  fix_ec=0
  LAST_EFFECTIVE_FIX_EFFORT=""
  pre_fix_hashes="$RUN_DIR/round-${round}-pre-fix-hashes.tsv"
  post_fix_hashes="$RUN_DIR/round-${round}-post-fix-hashes.tsv"
  capture_changed_file_hashes "$pre_fix_hashes"
  if run_fix "$round" "$fix_model_id" "$fix_effort" "$fix_prompt_file" "$fix_file"; then
    fix_ec=0
  else
    fix_ec=$?
    if [[ "$fix_ec" -eq 130 ]]; then
      print_phase "Stopped during fix (artifacts kept at $RUN_DIR)."
      exit 130
    fi
    if [[ "$fix_ec" -eq "$AUTH_ERROR_EXIT_CODE" ]] && auth_error_summary "$fix_file" >/dev/null 2>&1; then
      warn "Authentication failed during fix; aborting loop."
      warn "Run 'codex logout' then 'codex login', then re-run this skill."
      print_phase "❌ Fix stopped due to authentication failure. Artifacts at $RUN_DIR"
      exit 2
    fi
    warn "Fix command exited non-zero (exit=$fix_ec). Continuing to next round."
  fi

  fix_effort_used="${LAST_EFFECTIVE_FIX_EFFORT:-$fix_effort}"
  echo "[${round}/${MAX_ROUNDS}] fix done (exit=${fix_ec})."
  fix_touched_file="$RUN_DIR/round-${round}-fix-touched-files.txt"
  capture_changed_file_hashes "$post_fix_hashes"
  if ! compute_touched_files_from_snapshots "$pre_fix_hashes" "$post_fix_hashes" "$fix_touched_file"; then
    extract_fix_touched_files "$fix_file" "$fix_touched_file"
  fi
  if [[ "$(count_nonempty_lines "$fix_touched_file")" -eq 0 ]]; then
    # Fallback for environments where git snapshots could not infer touched paths.
    extract_fix_touched_files "$fix_file" "$fix_touched_file"
  fi
  fix_touched_count="$(count_nonempty_lines "$fix_touched_file")"
  if [[ "$fix_touched_count" -gt 0 ]]; then
    echo "What I changed:"
    print_indented_list "$fix_touched_file"
  fi

  forbidden_cmds_file="$RUN_DIR/round-${round}-forbidden-commands.txt"
  extract_forbidden_commands_from_output "$fix_file" "$forbidden_cmds_file"
  forbidden_cmds_count="$(count_nonempty_lines "$forbidden_cmds_file")"
  if [[ "$forbidden_cmds_count" -gt 0 ]]; then
    warn "Fix output includes ${forbidden_cmds_count} forbidden build/test/package command(s)."
    echo "Forbidden commands detected:"
    print_indented_list "$forbidden_cmds_file"
    if [[ "$FAIL_ON_FORBIDDEN_COMMANDS" == "1" ]]; then
      print_phase "❌ Forbidden command policy violated in round ${round}. Aborting."
      exit 3
    fi
  fi

  scope_violations_file="$RUN_DIR/round-${round}-scope-violations.txt"
  compute_scope_violations "$fix_touched_file" "$allowed_files_file" "$scope_violations_file"
  scope_violations_count="$(count_nonempty_lines "$scope_violations_file")"
  if [[ "$scope_violations_count" -gt 0 ]]; then
    warn "Detected ${scope_violations_count} out-of-scope touched file(s)."
    echo "Out-of-scope touched files:"
    print_indented_list "$scope_violations_file"
    if [[ "$REVERT_SCOPE_VIOLATION_UNTRACKED" == "1" ]]; then
      reverted_scope_file="$RUN_DIR/round-${round}-scope-violations-reverted-untracked.txt"
      revert_new_untracked_scope_violations "$pre_fix_hashes" "$scope_violations_file" "$reverted_scope_file"
      reverted_scope_count="$(count_nonempty_lines "$reverted_scope_file")"
      if [[ "$reverted_scope_count" -gt 0 ]]; then
        echo "Reverted new untracked out-of-scope files:"
        print_indented_list "$reverted_scope_file"
      fi
    fi
    if [[ "$FAIL_ON_SCOPE_VIOLATION" == "1" ]]; then
      print_phase "❌ Scope policy violated in round ${round}. Aborting."
      exit 4
    fi
  fi

  if [[ "$findings_parsed" -gt 0 ]]; then
    echo "Findings targeted in this fix:"
    print_indented_list "$findings_file"
  fi

  append_len="$(printf "%s" "$CF_APPEND_CONTEXT" | wc -c | tr -d ' ')"
  write_meta_json "$meta_file" "$round" "$scope_desc" "$review_model_id" "$review_effort_used" "$fix_model_id" "$fix_effort_used" "$review_ec" "$fix_ec" false "$append_len"
  PREV_FINDINGS_FILE="$findings_file"
  PREV_FINDINGS_ROUND="$round"
done

# Write summary.json
summary_path="$RUN_DIR/summary.json"
if have_cmd python3; then
  python3 - <<PY "$summary_path" "$RUN_DIR" "$ROUNDS_RUN" "$MAX_ROUNDS" "$CLEAN"
import json, sys, time
path, run_dir, rounds_run, max_rounds, clean = sys.argv[1:]
doc = {
  "run_dir": run_dir,
  "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
  "rounds_run": int(rounds_run),
  "max_rounds": int(max_rounds),
  "clean": (clean.lower() == "true"),
}
with open(path, "w", encoding="utf-8") as f:
  json.dump(doc, f, indent=2, sort_keys=True)
  f.write("\n")
PY
else
  echo "{\"run_dir\":\"$RUN_DIR\",\"rounds_run\":$ROUNDS_RUN,\"max_rounds\":$MAX_ROUNDS,\"clean\":$CLEAN}" > "$summary_path"
fi

if [[ "$CLEAN" == "true" ]]; then
  print_phase "✅ Review is clean. Artifacts at $RUN_DIR"
  exit 0
else
  print_phase "❌ Review not clean after ${MAX_ROUNDS} rounds."
  echo "Artifacts at: $RUN_DIR"
  exit 1
fi
