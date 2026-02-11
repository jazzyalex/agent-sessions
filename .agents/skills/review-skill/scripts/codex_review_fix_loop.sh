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

# CLI-only knobs
DRY_RUN="0"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-60}"

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

# ----------------------------- Helpers ---------------------------------------

usage() {
  cat <<'USAGE'
Usage:
  codex_review_fix_loop.sh [--uncommitted] [--base <branch>] [--commit <sha>]
                           [--max-rounds <n>]
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
                           [--control-file <path>]
                           [--artifacts-dir <path>]
                           [--dry-run]

Defaults:
  --uncommitted
  --max-rounds 6
  --review-model-early high
  --review-model-late  xhigh
  --fix-model-early    high
  --fix-model-late     xhigh
  --review-prompt-mode plain
  --heartbeat-seconds  60
  --control-file       .codex-review-control.md
  --artifacts-dir      .codex-review-artifacts

Notes:
  - "high" and "xhigh" are treated as reasoning effort (model_reasoning_effort).
  - To specify both model and effort, use "gpt-5.3-codex@xhigh" format.
  - --fix-model is a convenience override that pins both early+late fix selectors.
  - Heartbeat lines print periodic in-progress summaries during review/fix commands.
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
  awk 'NF{print} ' "$file" | head -n "$max_lines"
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

count_exec_events() {
  local file="$1"
  local n
  n="$(grep -Eci '(^exec$|succeeded in [0-9]+ms)' "$file" 2>/dev/null || true)"
  n="$(printf "%s" "$n" | head -n1 | tr -d '[:space:]')"
  [[ -z "$n" ]] && n=0
  printf "%s" "$n"
}

count_error_events() {
  local file="$1"
  local n
  n="$(grep -Eci '(^|[[:space:]])(ERROR:|error:)' "$file" 2>/dev/null || true)"
  n="$(printf "%s" "$n" | head -n1 | tr -d '[:space:]')"
  [[ -z "$n" ]] && n=0
  printf "%s" "$n"
}

phase_hint_from_output() {
  local file="$1"
  local tail_buf
  tail_buf="$(tail -n 120 "$file" 2>/dev/null || true)"
  if printf "%s" "$tail_buf" | grep -Eqi '(^|[[:space:]])(ERROR:|error:)'; then
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
  if grep -Eqi '(REVIEW_CLEAN|no issues found|no issues identified|no findings|looks good|lgtm)' "$file"; then
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
  local action message phase_label clock alert_detail

  cmds="$(count_exec_events "$out_file")"
  errs="$(count_error_events "$out_file")"
  phase_hint="$(phase_hint_from_output "$out_file")"
  clock="$(format_elapsed_clock "$elapsed")"

  if [[ "$phase" == "review" ]]; then
    phase_label="review"
    findings="$(estimate_findings_count "$out_file")"
    clean_signal="$(clean_signal_from_output "$out_file")"
    if [[ "$errs" -gt 0 ]]; then
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
    if [[ "$errs" -gt 0 ]]; then
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
  if [[ -n "$stdin_file" ]]; then
    "$@" <"$stdin_file" >"$out_file" 2>&1 &
  else
    "$@" >"$out_file" 2>&1 &
  fi
  local child_pid=$!
  set -e

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

    # Steering during in-flight command:
    # - stop is applied immediately
    # - other control updates are applied between rounds
    read_control_file
    if [[ "$CF_STATUS" == "stop" ]]; then
      warn "Control requested stop during ${phase}; terminating active command."
      kill "$child_pid" >/dev/null 2>&1 || true
      wait "$child_pid" >/dev/null 2>&1 || true
      return 130
    fi
  done

  set +e
  wait "$child_pid"
  local ec=$?
  set -e
  return $ec
}

is_review_clean_output() {
  local file="$1"
  local review_ec="$2"
  local trimmed
  trimmed="$(trim "$(cat "$file")")"

  # Preferred deterministic sentinel when prompt mode is supported.
  if [[ "$trimmed" == "REVIEW_CLEAN" ]]; then
    return 0
  fi

  # Non-zero review command should not be treated as clean.
  if [[ "$review_ec" -ne 0 ]]; then
    return 1
  fi

  # Common clean-language fallbacks from headless review output.
  if grep -Eqi '(no issues found|no issues identified|no findings|looks good|lgtm)' "$file"; then
    return 0
  fi

  # Last-resort heuristic for CLI variants that do not accept custom prompts.
  if [[ "$(estimate_findings_count "$file")" -eq 0 ]] && ! grep -Eqi '^[[:space:]]*error:' "$file"; then
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
  #     multi line
  # Stops when hitting a new top-level "<key>:" line.
  local ac_line
  ac_line="$(grep -nE '^[[:space:]]*append_context[[:space:]]*:' "$CONTROL_FILE" | head -n1 || true)"
  if [[ -n "$ac_line" ]]; then
    local ln
    ln="$(echo "$ac_line" | cut -d: -f1)"
    local rhs
    rhs="$(echo "$ac_line" | cut -d: -f2- | sed -E 's/^[[:space:]]*append_context[[:space:]]*:[[:space:]]*//')"
    rhs="$(trim "$rhs")"

    if [[ "$rhs" == "|" || -z "$rhs" ]]; then
      # Read from next line forward until next key:
      CF_APPEND_CONTEXT="$(awk -v start="$ln" '
        NR <= start {next}
        # stop at the next non-indented key: value line (top-level)
        /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {exit}
        {print}
      ' "$CONTROL_FILE")"
      # If user used YAML-style indentation, strip one leading space consistently
      CF_APPEND_CONTEXT="$(echo "$CF_APPEND_CONTEXT" | sed -E 's/^[ ]{1}//')"
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

  local review_text
  review_text="$(cat "$review_file")"

  cat <<EOF
You are an autonomous coding agent fixing issues found by a code review.

Goal:
- Fix the issues described in the review output below.
- Keep changes minimal and directly tied to the findings.
- Do not introduce unrelated refactors.
- If tests exist and are fast, run them. If lint exists and is fast, run it.

Review output (verbatim):
------------------------
$review_text
------------------------

EOF

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

  local args=()
  case "$scope_mode" in
    uncommitted) args+=(--uncommitted) ;;
    base)        args+=(--base "$scope_base") ;;
    commit)      args+=(--commit "$scope_sha") ;;
    *) die "internal: unknown scope_mode '$scope_mode'" ;;
  esac

  # Title helps identify runs in Codex history (optional)
  args+=(--title "review-fix-loop round ${round}")

  # Config overrides:
  # - review_model: sets the model for /review; used here as a best-effort override for codex review too
  # - model_reasoning_effort: sets effort
  if [[ -n "$review_model_id" ]]; then
    args+=(--config "review_model=$review_model_id")
  fi
  if [[ -n "$review_effort" ]]; then
    args+=(--config "model_reasoning_effort=$review_effort")
  fi

  # Default to plain mode because current codex review commonly rejects prompt
  # with --uncommitted/--base/--commit.
  if [[ "$REVIEW_PROMPT_MODE" == "plain" ]]; then
    run_with_heartbeat "review" "$round" "$out_file" "" codex review "${args[@]}"
    return $?
  fi

  local prompt
  prompt="$(build_review_prompt)"
  local review_prompt_file="${RUN_DIR}/round-${round}-review-prompt.txt"
  printf "%s" "$prompt" > "$review_prompt_file"

  run_with_heartbeat "review" "$round" "$out_file" "$review_prompt_file" codex review "${args[@]}" -
  local ec=$?
  if [[ "$ec" -ne 0 ]] && grep -q "cannot be used with '\\[PROMPT\\]'" "$out_file"; then
    if [[ "$REVIEW_PROMPT_MODE" == "auto" ]]; then
      warn "codex review prompt input is not supported for this scope on this CLI; retrying without prompt."
      run_with_heartbeat "review" "$round" "$out_file" "" codex review "${args[@]}"
      ec=$?
    else
      warn "codex review prompt mode requested, but this CLI/scope combination does not support prompt input."
    fi
  fi
  return $ec
}

run_fix() {
  local round="$1"
  local fix_model_id="$2"
  local fix_effort="$3"
  local fix_prompt_file="$4"
  local out_file="$5"

  local args=()

  # Force headless execution with sandboxed automatic command handling.
  args+=(--full-auto)
  args+=(--sandbox workspace-write)

  if [[ -n "$fix_model_id" ]]; then
    args+=(--model "$fix_model_id")
  fi
  if [[ -n "$fix_effort" ]]; then
    args+=(--config "model_reasoning_effort=$fix_effort")
  fi

  run_with_heartbeat "fix" "$round" "$out_file" "$fix_prompt_file" codex exec "${args[@]}" -
  return $?
}

on_interrupt() {
  echo ""
  warn "Interrupted. Exiting gracefully (artifacts kept at $RUN_DIR)."
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
[[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]] || die "--max-rounds must be an integer"
[[ "$HEARTBEAT_SECONDS" =~ ^[0-9]+$ ]] || die "--heartbeat-seconds must be an integer"
[[ "$HEARTBEAT_SECONDS" -gt 0 ]] || die "--heartbeat-seconds must be > 0"
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
  echo "- Max rounds: $MAX_ROUNDS"
  echo "- Review selector early: $REVIEW_MODEL_EARLY"
  echo "- Review selector late:  $REVIEW_MODEL_LATE"
  echo "- Fix selector early:    $FIX_MODEL_EARLY"
  echo "- Fix selector late:     $FIX_MODEL_LATE"
  echo "- Review prompt mode:    $REVIEW_PROMPT_MODE"
  echo "- Heartbeat seconds:     $HEARTBEAT_SECONDS"
  echo "- Review model id override: ${REVIEW_MODEL_ID:-<none>}"
  echo "- Fix model id override:    ${FIX_MODEL_ID:-<none>}"
  echo "- Control file: $CONTROL_FILE"
  exit 0
fi

# Run summary state
CLEAN="false"
ROUNDS_RUN=0

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
  if run_review "$round" "$scope_mode" "$scope_base" "$scope_sha" "$review_model_id" "$review_effort" "$review_file"; then
    review_ec=0
  else
    review_ec=$?
    if [[ "$review_ec" -eq 130 ]]; then
      print_phase "Stopped during review (artifacts kept at $RUN_DIR)."
      exit 130
    fi
    warn "Review command exited non-zero (exit=$review_ec). Continuing."
  fi

  # Determine clean
  if is_review_clean_output "$review_file" "$review_ec"; then
    CLEAN="true"
  else
    CLEAN="false"
  fi

  findings_est="$(estimate_findings_count "$review_file")"
  if [[ "$CLEAN" == "true" ]]; then
    echo "[${round}/${MAX_ROUNDS}] ✅ CLEAN (findings≈0)"
    write_meta_json "$meta_file" "$round" "$scope_desc" "$review_model_id" "$review_effort" "$fix_model_id" "$fix_effort" "$review_ec" 0 true 0
    break
  fi

  echo "[${round}/${MAX_ROUNDS}] ❌ NOT CLEAN (findings≈${findings_est})"
  echo "Findings preview:"
  preview_nonempty_lines "$review_file" 12 | sed 's/^/  /'

  # Build fix prompt (includes full review output)
  fix_prompt="$(build_fix_prompt "$review_file" "$CF_APPEND_CONTEXT")"
  printf "%s" "$fix_prompt" > "$fix_prompt_file"

  print_phase "[${round}/${MAX_ROUNDS}] fix (model_id=${fix_model_id:-<default>} effort=${fix_effort:-<default>})"
  fix_ec=0
  if run_fix "$round" "$fix_model_id" "$fix_effort" "$fix_prompt_file" "$fix_file"; then
    fix_ec=0
  else
    fix_ec=$?
    if [[ "$fix_ec" -eq 130 ]]; then
      print_phase "Stopped during fix (artifacts kept at $RUN_DIR)."
      exit 130
    fi
    warn "Fix command exited non-zero (exit=$fix_ec). Continuing to next round."
  fi

  echo "[${round}/${MAX_ROUNDS}] fix done (exit=${fix_ec})."

  append_len="$(printf "%s" "$CF_APPEND_CONTEXT" | wc -c | tr -d ' ')"
  write_meta_json "$meta_file" "$round" "$scope_desc" "$review_model_id" "$review_effort" "$fix_model_id" "$fix_effort" "$review_ec" "$fix_ec" false "$append_len"
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
