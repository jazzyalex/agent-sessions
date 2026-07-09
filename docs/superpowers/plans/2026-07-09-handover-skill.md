# Handover Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a global `/handover` skill + a global Stop hook that append dated, structured entries to a per-repo `RepoHandover.md`, so archived-session context is recoverable without grepping.

**Architecture:** Develop three testable shell artifacts + one skill markdown in the repo under `tools/handover/` (source of truth, versioned, TDD-tested following the existing `tools/test_*.sh` pattern), then an idempotent `install.sh` deploys them to the global `~/.claude/` (skill → `~/.claude/skills/handover/`, hook → `~/.claude/hooks/`, Stop-hook wiring merged into `~/.claude/settings.json`). "Test in `tools/handover/` first, install to `~/.claude/` last" honors the repo's test-before-production rule.

**Tech Stack:** Bash (`#!/usr/bin/env bash`, `set -euo pipefail`), `jq` (`/usr/bin/jq`), Claude Code skills + hooks (`Stop` event), plain-shell test scripts.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-09-handover-skill-design.md` (authoritative for format + behavior).
- Test style: plain `bash` scripts under `tools/`, named `tools/test_handover_*.sh`, using `set -euo pipefail` and `pass()`/`fail()` helpers with `PASSED`/`FAILED` counters (match `tools/test_smoke.sh`).
- All hermetic tests must NOT touch the real `~/.claude/` — override `HOME` and `TMPDIR` to temp dirs.
- The skill and hook **never run `git commit`** — they write files only; the user commits (repo rule).
- Entry key block is exactly: line 1 `## <DATE> <TIME> · <slug> · <title>`, line 2 `status: <value>`, line 3 `branch: <text>`. `status` ∈ `in-progress | blocked | done | superseded-by:<YYYY-MM-DD>`. Not YAML.
- Newest-first: new entries are **prepended** to `RepoHandover.md`.
- Stop hook offers **at most once per session** (session-id sentinel), soft offer only (never `decision:"block"`).
- Commit messages: Conventional Commits, no "Generated with Claude Code" footer, no Co-Authored-By. Trailers `Tool:`/`Model:`/`Why:` optional per repo convention. Do NOT commit unless the executing operator confirms (repo rule); plan commit steps stage only their own task's paths.

---

## File Structure

Source of truth (repo, versioned, tested):
- Create `tools/handover/handover-lint.sh` — validates the newest entry's key block. Test oracle + reusable by the skill.
- Create `tools/handover/handover-offer.sh` — the `Stop` hook: gates + soft offer.
- Create `tools/handover/install.sh` — idempotent global installer.
- Create `tools/handover/SKILL.md` — the `/handover` skill (drafting/format/write/supersede/pointer logic).
- Create `tools/test_handover_lint.sh` — tests for the validator.
- Create `tools/test_handover_hook.sh` — tests for the hook (gate matrix).
- Create `tools/test_handover_install.sh` — tests for the installer (fake `HOME`).

Deployed (global, created by installer at execution time):
- `~/.claude/skills/handover/SKILL.md`
- `~/.claude/hooks/handover-offer.sh`
- `~/.claude/settings.json` (`Stop` hook entry merged in)

---

## Task 1: Format validator (`handover-lint.sh`)

Locks the entry-format contract as executable spec. The validator checks the **newest** (topmost) entry's 3-line key block. Later tasks (the skill) use it as an acceptance oracle.

**Files:**
- Create: `tools/handover/handover-lint.sh`
- Test: `tools/test_handover_lint.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: CLI `handover-lint.sh <path-to-RepoHandover.md>` → exit `0` if the topmost entry's key block is valid, exit `1` + a one-line reason on stderr otherwise. Empty/missing file → exit `1`.

- [ ] **Step 1: Write the failing test**

Create `tools/test_handover_lint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

LINT="$(dirname "$0")/handover/handover-lint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0
pass() { echo "✓ $1"; PASSED=$((PASSED+1)); }
fail() { echo "✗ $1"; FAILED=$((FAILED+1)); }

# assert_exit <expected-code> <file> <label>
assert_exit() {
  local want="$1" file="$2" label="$3" got=0
  bash "$LINT" "$file" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label (want exit $want, got $got)"; fi
}

# Valid entry
cat > "$WORK/good.md" <<'EOF'
## 2026-07-09 14:32 · runway-auth · AS-owned OAuth (P2)
status: in-progress
branch: main @ 9ade2753 (dirty: 2 files)

**State in one line:** next is P2.
EOF
assert_exit 0 "$WORK/good.md" "valid entry passes"

# superseded-by status is valid
cat > "$WORK/superseded.md" <<'EOF'
## 2026-07-09 14:32 · runway-auth · title
status: superseded-by:2026-07-10
branch: main @ abc1234 (clean)
EOF
assert_exit 0 "$WORK/superseded.md" "superseded-by status passes"

# Bad status value
cat > "$WORK/badstatus.md" <<'EOF'
## 2026-07-09 14:32 · slug · title
status: wip
branch: main @ abc1234
EOF
assert_exit 1 "$WORK/badstatus.md" "invalid status fails"

# Missing branch line
cat > "$WORK/nobranch.md" <<'EOF'
## 2026-07-09 14:32 · slug · title
status: done
**State:** x
EOF
assert_exit 1 "$WORK/nobranch.md" "missing branch line fails"

# Heading without timestamp
cat > "$WORK/badhead.md" <<'EOF'
## runway-auth notes
status: done
branch: main
EOF
assert_exit 1 "$WORK/badhead.md" "heading without timestamp fails"

# Empty file
: > "$WORK/empty.md"
assert_exit 1 "$WORK/empty.md" "empty file fails"

# Missing file
assert_exit 1 "$WORK/does-not-exist.md" "missing file fails"

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/test_handover_lint.sh`
Expected: FAIL — script errors because `tools/handover/handover-lint.sh` does not exist yet.

- [ ] **Step 3: Write the validator**

Create `tools/handover/handover-lint.sh`:

```bash
#!/usr/bin/env bash
# Validate the newest (topmost) entry's key block in a RepoHandover.md.
# Usage: handover-lint.sh <path>   ->   exit 0 valid, exit 1 invalid (reason on stderr)
set -euo pipefail

file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "handover-lint: file not found: ${file:-<none>}" >&2
  exit 1
fi

# Find the first heading line and the two lines after it.
head_line="$(grep -nE '^## ' "$file" | head -1 || true)"
if [ -z "$head_line" ]; then
  echo "handover-lint: no '## ' entry heading found" >&2
  exit 1
fi
hn="${head_line%%:*}"                    # line number of first heading
h="$(sed -n "${hn}p" "$file")"
s="$(sed -n "$((hn+1))p" "$file")"
b="$(sed -n "$((hn+2))p" "$file")"

# Heading: "## DATE TIME · slug · title"
if ! printf '%s' "$h" | grep -qE '^## [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} · .+ · .+'; then
  echo "handover-lint: heading not in '## DATE TIME · slug · title' form: $h" >&2
  exit 1
fi
# status line
if ! printf '%s' "$s" | grep -qE '^status: (in-progress|blocked|done|superseded-by:[0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]*(#.*)?$'; then
  echo "handover-lint: bad or missing status line: $s" >&2
  exit 1
fi
# branch line (non-empty payload)
if ! printf '%s' "$b" | grep -qE '^branch: .+'; then
  echo "handover-lint: bad or missing branch line: $b" >&2
  exit 1
fi
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x tools/handover/handover-lint.sh && bash tools/test_handover_lint.sh`
Expected: PASS — final line `PASSED=7 FAILED=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tools/handover/handover-lint.sh tools/test_handover_lint.sh
git commit -m "feat(handover): entry-format validator + tests"
```

---

## Task 2: Stop hook (`handover-offer.sh`)

The gated soft-offer hook. Reads the hook JSON on stdin, applies gates, and — only when all pass — prints the offer JSON and marks a once-per-session sentinel.

**Files:**
- Create: `tools/handover/handover-offer.sh`
- Test: `tools/test_handover_hook.sh`

**Interfaces:**
- Consumes: stdin JSON with fields `stop_hook_active` (bool), `session_id` (string), `cwd` (string), `transcript_path` (string). (Field names per hook spec.)
- Produces: on all-gates-pass, prints to stdout either
  `{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"…"}}` (default) or
  `{"systemMessage":"…"}` when `HANDOVER_OFFER_MODE=systemMessage`; and creates sentinel `${TMPDIR:-/tmp}/claude-handover-<session_id>`. Always exits `0`. On any gate fail, prints nothing, exits `0`.
- Tunables (env): `HANDOVER_MIN_TRANSCRIPT_LINES` (default `50`), `HANDOVER_OFFER_MODE` (`context`|`systemMessage`, default `context`).

- [ ] **Step 1: Write the failing test**

Create `tools/test_handover_hook.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

HOOK="$(dirname "$0")/handover/handover-offer.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
PASSED=0; FAILED=0
pass() { echo "✓ $1"; PASSED=$((PASSED+1)); }
fail() { echo "✗ $1"; FAILED=$((FAILED+1)); }

# make_input <session_id> <cwd> <transcript> <stop_active>
make_input() {
  jq -n --arg s "$1" --arg c "$2" --arg t "$3" --argjson a "$4" \
    '{session_id:$s, cwd:$c, transcript_path:$t, stop_hook_active:$a}'
}

# A substantive transcript (>= 50 lines) and a trivial one
BIG="$WORK/big.jsonl";  for i in $(seq 1 60); do echo "{\"i\":$i}"; done > "$BIG"
SMALL="$WORK/small.jsonl"; echo '{"i":1}' > "$SMALL"
REPO="$WORK/repo"; mkdir -p "$REPO"   # not a git repo; substantiveness comes from transcript size

# 1. all gates pass -> emits additionalContext offer
out="$(make_input sess1 "$REPO" "$BIG" false | HANDOVER_OFFER_MODE=context bash "$HOOK")"
if echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("handover")' >/dev/null 2>&1; then
  pass "substantive session emits additionalContext offer"; else fail "expected offer, got: $out"; fi

# 2. sentinel now exists -> second call is silent
out="$(make_input sess1 "$REPO" "$BIG" false | bash "$HOOK")"
[ -z "$out" ] && pass "once-per-session: second call silent" || fail "second call should be silent, got: $out"

# 3. stop_hook_active=true -> silent (loop guard), fresh session
out="$(make_input sess2 "$REPO" "$BIG" true | bash "$HOOK")"
[ -z "$out" ] && pass "loop guard: stop_hook_active silent" || fail "loop guard failed, got: $out"

# 4. trivial session (short transcript, no git changes) -> silent
out="$(make_input sess3 "$REPO" "$SMALL" false | bash "$HOOK")"
[ -z "$out" ] && pass "trivial session stays silent" || fail "trivial should be silent, got: $out"

# 5. systemMessage mode
out="$(make_input sess4 "$REPO" "$BIG" false | HANDOVER_OFFER_MODE=systemMessage bash "$HOOK")"
if echo "$out" | jq -e '.systemMessage | test("handover")' >/dev/null 2>&1; then
  pass "systemMessage mode emits systemMessage"; else fail "expected systemMessage, got: $out"; fi

# 6. git-dirty short session -> offers (git signal ORs in)
GITREPO="$WORK/gitrepo"; mkdir -p "$GITREPO"
git -C "$GITREPO" init -q && echo x > "$GITREPO/f.txt"   # untracked change = dirty
out="$(make_input sess5 "$GITREPO" "$SMALL" false | bash "$HOOK")"
if echo "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  pass "git-dirty short session offers"; else fail "git-dirty should offer, got: $out"; fi

# 7. always exits 0 even on gate fail
make_input sess6 "$REPO" "$SMALL" false | bash "$HOOK" >/dev/null 2>&1
[ $? = 0 ] && pass "exits 0 on silent path" || fail "should exit 0"

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/test_handover_hook.sh`
Expected: FAIL — `tools/handover/handover-offer.sh` does not exist yet.

- [ ] **Step 3: Write the hook**

Create `tools/handover/handover-offer.sh`:

```bash
#!/usr/bin/env bash
# Claude Code Stop hook: offer a handover once per substantive session.
# Reads hook JSON on stdin; prints a soft offer (stdout JSON) at most once/session.
# Never blocks, never writes RepoHandover.md — it only nudges. Always exits 0.
set -euo pipefail

MIN_LINES="${HANDOVER_MIN_TRANSCRIPT_LINES:-50}"
MODE="${HANDOVER_OFFER_MODE:-context}"
OFFER_TEXT="This was a substantive session. Offer the user a one-line handover they can save via the /handover skill (which appends to RepoHandover.md); do not write anything unless they say yes."

input="$(cat)"
jqr() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# Gate 1: loop guard
[ "$(jqr '.stop_hook_active // false')" = "true" ] && exit 0

session_id="$(jqr '.session_id // ""')"
cwd="$(jqr '.cwd // ""')"
transcript="$(jqr '.transcript_path // ""')"
[ -n "$session_id" ] || exit 0

# Gate 2: once per session
sentinel="${TMPDIR:-/tmp}/claude-handover-${session_id}"
[ -e "$sentinel" ] && exit 0

# Gate 3: substantiveness — long transcript OR a dirty working tree.
tlines=0
[ -f "$transcript" ] && tlines="$(wc -l < "$transcript" | tr -d '[:space:]')"
dirty=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty="$(git -C "$cwd" status --porcelain 2>/dev/null | head -1)"
fi
substantive=false
[ "${tlines:-0}" -ge "$MIN_LINES" ] && substantive=true
[ -n "$dirty" ] && substantive=true
[ "$substantive" = true ] || exit 0

# All gates passed: mark sentinel, emit the soft offer.
: > "$sentinel" 2>/dev/null || true
if [ "$MODE" = "systemMessage" ]; then
  jq -n --arg m "$OFFER_TEXT" '{systemMessage:$m}'
else
  jq -n --arg m "$OFFER_TEXT" \
    '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$m}}'
fi
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x tools/handover/handover-offer.sh && bash tools/test_handover_hook.sh`
Expected: PASS — `PASSED=7 FAILED=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tools/handover/handover-offer.sh tools/test_handover_hook.sh
git commit -m "feat(handover): gated Stop-hook offer + tests"
```

---

## Task 3: Installer (`install.sh`)

Idempotently deploys the skill + hook to `~/.claude/` and merges the `Stop` hook into `~/.claude/settings.json` without clobbering existing keys. Hermetically testable via a fake `HOME`.

**Files:**
- Create: `tools/handover/install.sh`
- Test: `tools/test_handover_install.sh`

**Interfaces:**
- Consumes: `handover-offer.sh` and `SKILL.md` from `tools/handover/` (SKILL.md may be a stub until Task 4).
- Produces: `install.sh` honoring `CLAUDE_HOME` (default `$HOME/.claude`). Creates `skills/handover/SKILL.md`, `hooks/handover-offer.sh` (executable), and merges one `Stop` hook entry pointing at the absolute installed hook path. Running twice yields exactly one matching Stop entry (idempotent).

- [ ] **Step 1: Write the failing test**

Create `tools/test_handover_install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd "$(dirname "$0")/handover" && pwd)"
INSTALL="$SRC/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
PASSED=0; FAILED=0
pass() { echo "✓ $1"; PASSED=$((PASSED+1)); }
fail() { echo "✗ $1"; FAILED=$((FAILED+1)); }

# Ensure SKILL.md exists (stub tolerated for this task)
[ -f "$SRC/SKILL.md" ] || echo "# handover (stub)" > "$SRC/SKILL.md"

bash "$INSTALL"

CH="$HOME/.claude"
[ -f "$CH/skills/handover/SKILL.md" ] && pass "SKILL.md installed" || fail "SKILL.md missing"
[ -x "$CH/hooks/handover-offer.sh" ] && pass "hook installed + executable" || fail "hook missing/not executable"

if jq -e . "$CH/settings.json" >/dev/null 2>&1; then pass "settings.json is valid JSON"; else fail "settings.json invalid"; fi

cmd="$(jq -r '.hooks.Stop[].hooks[].command' "$CH/settings.json" 2>/dev/null | grep -c 'handover-offer.sh' || true)"
[ "$cmd" = "1" ] && pass "exactly one Stop hook entry" || fail "expected 1 Stop entry, got $cmd"

# Idempotency: run again, still exactly one
bash "$INSTALL"
cmd="$(jq -r '.hooks.Stop[].hooks[].command' "$CH/settings.json" 2>/dev/null | grep -c 'handover-offer.sh' || true)"
[ "$cmd" = "1" ] && pass "idempotent: still one Stop entry" || fail "duplicate after re-install, got $cmd"

# Preserve unrelated pre-existing settings keys
echo '{"model":"opusish","hooks":{"Stop":[]}}' > "$CH/settings.json"
bash "$INSTALL"
[ "$(jq -r '.model' "$CH/settings.json")" = "opusish" ] && pass "preserves unrelated keys" || fail "clobbered unrelated keys"

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tools/test_handover_install.sh`
Expected: FAIL — `tools/handover/install.sh` does not exist yet.

- [ ] **Step 3: Write the installer**

Create `tools/handover/install.sh`:

```bash
#!/usr/bin/env bash
# Install the handover skill + Stop hook into the global Claude config.
# Honors CLAUDE_HOME (default: $HOME/.claude). Idempotent. Never commits.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SKILL_DIR="$CLAUDE_HOME/skills/handover"
HOOK_DIR="$CLAUDE_HOME/hooks"
SETTINGS="$CLAUDE_HOME/settings.json"
HOOK_DST="$HOOK_DIR/handover-offer.sh"

mkdir -p "$SKILL_DIR" "$HOOK_DIR"

install -m 0644 "$SRC/SKILL.md" "$SKILL_DIR/SKILL.md"
install -m 0755 "$SRC/handover-offer.sh" "$HOOK_DST"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "install: $SETTINGS is not valid JSON; refusing to modify" >&2
  exit 1
fi

tmp="$(mktemp)"
jq --arg cmd "$HOOK_DST" '
  .hooks //= {} |
  .hooks.Stop //= [] |
  # Drop any prior entry that references our hook, then add a fresh one (idempotent).
  .hooks.Stop |= map(select((.hooks // [] | map(.command) | index($cmd)) | not)) |
  .hooks.Stop += [ { "matcher": "", "hooks": [ { "type": "command", "command": $cmd, "timeout": 10 } ] } ]
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "handover installed:"
echo "  skill:    $SKILL_DIR/SKILL.md"
echo "  hook:     $HOOK_DST"
echo "  settings: $SETTINGS (Stop hook merged)"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `chmod +x tools/handover/install.sh && bash tools/test_handover_install.sh`
Expected: PASS — `PASSED=7 FAILED=0`, exit 0. (No real `~/.claude` touched; test uses a fake `HOME`.)

- [ ] **Step 5: Commit**

```bash
git add tools/handover/install.sh tools/test_handover_install.sh
git commit -m "feat(handover): idempotent global installer + tests"
```

---

## Task 4: The `/handover` skill (`SKILL.md`)

Author the skill that drafts and writes entries. It is prose instruction to the agent (not unit-testable), so its acceptance is a **manual dry-run** whose *output* is validated by Task 1's `handover-lint.sh`. This ties the skill to the format contract.

**Files:**
- Create: `tools/handover/SKILL.md` (overwrites any Task 3 stub)

**Interfaces:**
- Consumes: `handover-lint.sh` (as the post-write self-check), git, the conversation transcript.
- Produces: a `SKILL.md` with YAML frontmatter (`name: handover`, a `description` that triggers on "handover", "hand off", "write handover", "capture state") and a procedure that: gathers git facts, drafts within the length budget, shows the draft for default-accept-on-Enter, prepends to `RepoHandover.md`, runs the supersede check, adds the `CLAUDE.md` pointer on first use, and never commits.

- [ ] **Step 1: Write the skill**

Create `tools/handover/SKILL.md`:

```markdown
---
name: handover
description: Use when wrapping up or capturing the current state of a coding session — writes a dated, structured entry to the repo's RepoHandover.md so a future agent or you can resume without grepping archived sessions. Triggers on "handover", "hand off", "write handover", "capture state", "checkpoint this session".
---

# Handover

Append one dated, structured entry to `RepoHandover.md` at the repo root (newest-first),
capturing the session's state so it can be resumed later. Serves both a future agent
(actionable state) and the human (skimmable narrative). You draft it; the user approves;
you write it. **Never commit** — the user commits.

## Procedure

### 1. Gather ground truth from git (never infer facts from the conversation)
Run and read the output:
- `git rev-parse --abbrev-ref HEAD` — branch
- `git rev-parse --short HEAD` — commit hash
- `git status --porcelain` — dirty files (count + top dir for the branch line)
- `git log --oneline -5` — commits (identify which were made this session)
- `git diff --stat` — scope of uncommitted work

### 2. Extract entry content, in reliability order
- **Key files** ← files you actually touched via Edit/Write this session (NOT files merely
  mentioned). Format each inline as `path:line — why`.
- **Already decided / don't redo** ← user messages that rejected/corrected an approach,
  plus approaches you tried that failed. This is the highest-value section.
- **Verified** ← claims backed by a real tool result in this session (a git hash, test
  output, a sample). **Believed / unverified** ← everything else. Never promote a Believed
  claim to Verified without transcript evidence.
- **Next steps (prioritized)** ← the final todo/plan state, numbered. Items needing the
  human get a `DECIDE:` prefix.
- **Risks / landmines** ← risk → mitigation/stop-condition pairs.
- **How to verify** ← the build/test command that confirms the entry's claims (omit if N/A).

### 3. Reconcile git vs conversation
If the conversation says "committed" but the tree is dirty (or vice versa), flag the
discrepancy in the entry rather than picking one. **Git wins for facts; conversation wins
for intent.**

### 4. Draft within budget
Compose the entry using the exact format below. Hard budget: **~50 lines / ~600 words**.
Trim before showing. Omit any section that would be empty. The scope-slug is derived from
the branch name or the active plan/spec doc name — do not freestyle it (supersede-matching
depends on stable slugs).

Format (key block is exactly three lines: heading, `status:`, `branch:`):

    ## <YYYY-MM-DD> <HH:MM> · <scope-slug> · <title>
    status: <in-progress | blocked | done>
    branch: <branch> @ <short-hash> (dirty: <n> files[ in <dir>])

    **State in one line:** <one sentence>

    ### Already decided / don't redo
    - …

    ### Key files
    - `path:line` — …

    ### Verified
    - … (commit <hash> / test output)
    ### Believed / unverified
    - …

    ### Next steps (prioritized)
    1. …
    2. DECIDE: …

    ### Risks / landmines
    - <risk> — mitigation: <…>

    ### How to verify
    - <command>

Use the current date/time for the heading (ask the shell: `date +'%Y-%m-%d %H:%M'`).

### 5. Show the draft; default-accept on Enter
Present the drafted entry. Tell the user: press Enter to accept as-is, or reply with edits.
Apply any edits inline. Keep approval lightweight — heavyweight approval kills the habit.

### 6. Write (prepend, newest-first)
- If `RepoHandover.md` does not exist, create it with the new entry as the only content,
  AND append one line to the repo's `CLAUDE.md` (create a short one if absent):
  `> Before starting work, read the newest entry in \`RepoHandover.md\`.`
- If it exists, **prepend** the new entry above the current topmost entry (a blank line
  between entries). Do not touch older entries except in step 7.
- **Never run `git commit`.** Tell the user the file is written and theirs to commit.

### 7. Supersede check
Scan existing entries for one whose scope-slug matches the new entry's slug and whose
status is not already `superseded-by:`. If found, offer to change that older entry's
`status:` line to `status: superseded-by:<new-entry-date>` (a one-line edit; leave its
prose untouched). Only on user confirmation.

### 8. Self-check the format
Run the installed validator against the file and report the result:
`~/.claude/skills/handover/handover-lint.sh RepoHandover.md` (or the repo copy
`tools/handover/handover-lint.sh` when developing). It must exit 0. If it fails, fix the
key block and re-run.

## Notes
- Rotation: if `RepoHandover.md` exceeds ~1000 lines, offer (never silently) to move all
  but the newest ~10 entries to `RepoHandover-archive.md`.
- The Stop hook may *offer* a handover at session close; this skill is what actually runs.
```

- [ ] **Step 2: Install locally and run the format validator against a real drafted entry**

Reinstall so the skill + validator are present, then dry-run the skill in a scratch repo and validate its output. First make the installer also ship the validator (the skill's step 8 references `~/.claude/skills/handover/handover-lint.sh`):

Add to `tools/handover/install.sh` after the SKILL.md install line:

```bash
install -m 0755 "$SRC/handover-lint.sh" "$SKILL_DIR/handover-lint.sh"
```

Run: `bash tools/test_handover_install.sh`
Expected: PASS (installer still green with the extra file).

- [ ] **Step 3: Manual dry-run acceptance**

In a scratch git repo, invoke the skill (or hand-produce one entry following the procedure), then verify the output passes the contract:

Run:
```bash
scratch="$(mktemp -d)"; git -C "$scratch" init -q
printf '## %s · demo · smoke\nstatus: in-progress\nbranch: main @ 0000000 (clean)\n\n**State in one line:** demo.\n' "$(date +'%Y-%m-%d %H:%M')" > "$scratch/RepoHandover.md"
bash tools/handover/handover-lint.sh "$scratch/RepoHandover.md" && echo "LINT OK"
```
Expected: prints `LINT OK` (exit 0). This confirms the format the SKILL.md documents is exactly what the validator accepts.

- [ ] **Step 4: Commit**

```bash
git add tools/handover/SKILL.md tools/handover/install.sh
git commit -m "feat(handover): /handover skill + ship validator with install"
```

---

## Task 5: Production install + end-to-end smoke + rollback

Deploy to the real `~/.claude/` and prove the two entry points work against the live config. This is the only task that mutates the user's global environment — run it last, and only with operator confirmation.

**Files:**
- Modify: `~/.claude/skills/handover/`, `~/.claude/hooks/`, `~/.claude/settings.json` (via installer)
- Create: `tools/handover/README.md` (install + rollback notes)

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: a working global install; a documented rollback.

- [ ] **Step 1: Back up any existing global settings**

Run:
```bash
[ -f ~/.claude/settings.json ] && cp ~/.claude/settings.json ~/.claude/settings.json.pre-handover.bak && echo "backed up" || echo "no prior settings.json"
```
Expected: prints `no prior settings.json` (confirmed at plan time) or `backed up`.

- [ ] **Step 2: Run the real install**

Run: `bash tools/handover/install.sh`
Expected: prints the three installed paths. Then verify:
```bash
jq -e '.hooks.Stop[].hooks[] | select(.command|test("handover-offer.sh"))' ~/.claude/settings.json >/dev/null && echo "STOP HOOK WIRED"
```
Expected: `STOP HOOK WIRED`.

- [ ] **Step 3: Smoke the hook — substantive session offers**

Run (simulate a substantive session's Stop payload against this repo):
```bash
big="$(mktemp)"; for i in $(seq 1 60); do echo "{}"; done > "$big"
jq -n --arg c "$PWD" --arg t "$big" '{session_id:"smoke-yes", cwd:$c, transcript_path:$t, stop_hook_active:false}' \
  | ~/.claude/hooks/handover-offer.sh | jq -e '.hookSpecificOutput.additionalContext' >/dev/null && echo "OFFERS: yes"
```
Expected: `OFFERS: yes`.

- [ ] **Step 4: Smoke the hook — trivial session is silent, loop guard holds**

Run:
```bash
small="$(mktemp)"; echo "{}" > "$small"
out="$(jq -n --arg t "$small" '{session_id:"smoke-no", cwd:"/tmp", transcript_path:$t, stop_hook_active:false}' | ~/.claude/hooks/handover-offer.sh)"
[ -z "$out" ] && echo "TRIVIAL: silent"
out="$(jq -n --arg t "$small" '{session_id:"smoke-loop", cwd:"'"$PWD"'", transcript_path:"'"$big"'", stop_hook_active:true}' | ~/.claude/hooks/handover-offer.sh)"
[ -z "$out" ] && echo "LOOPGUARD: silent"
```
Expected: `TRIVIAL: silent` and `LOOPGUARD: silent`.

- [ ] **Step 5: Live offer smoke-test (the spec's open validation item)**

In a fresh Claude Code session in a dirty repo, end a substantive turn and confirm the assistant *asks* whether to write a handover (proving `additionalContext` surfaces the offer). If it does not reliably ask, re-run the installer with the systemMessage channel and re-test:
```bash
# fallback: edit ~/.claude/hooks/handover-offer.sh invocation OR set default MODE
HANDOVER_OFFER_MODE=systemMessage  # document result in README either way
```
Expected: assistant surfaces a one-line handover offer at session close, at most once.

- [ ] **Step 6: Write install/rollback notes**

Create `tools/handover/README.md`:

```markdown
# Handover skill + Stop hook

Global `/handover` skill and a `Stop` hook that offers a handover once per substantive
session. Entries go to a per-repo `RepoHandover.md` (newest-first). Spec:
`docs/superpowers/specs/2026-07-09-handover-skill-design.md`.

## Install
    bash tools/handover/install.sh
Installs to `~/.claude/skills/handover/`, `~/.claude/hooks/handover-offer.sh`, and merges a
`Stop` hook into `~/.claude/settings.json`. Idempotent.

## Tune
- `HANDOVER_MIN_TRANSCRIPT_LINES` (default 50) — substantiveness threshold.
- `HANDOVER_OFFER_MODE` (`context` default | `systemMessage`) — offer channel.

## Rollback
- Remove the Stop entry:
      jq 'del(.hooks.Stop)' ~/.claude/settings.json > /tmp/s && mv /tmp/s ~/.claude/settings.json
  (or restore `~/.claude/settings.json.pre-handover.bak` if it exists).
- `rm -rf ~/.claude/skills/handover ~/.claude/hooks/handover-offer.sh`

## Tests
    bash tools/test_handover_lint.sh
    bash tools/test_handover_hook.sh
    bash tools/test_handover_install.sh
```

- [ ] **Step 7: Commit**

```bash
git add tools/handover/README.md
git commit -m "docs(handover): install + rollback notes; production smoke verified"
```

---

## Self-Review

**Spec coverage:**
- Per-repo `RepoHandover.md`, newest-first → Task 4 (write/prepend) + Task 1 (format). ✓
- 2-line parseable key block (status/branch, not YAML) → Task 1 validator + Task 4 format. ✓
- Verified/Believed split with transcript-evidence rule → Task 4 step 2. ✓
- `path:line` refs from actual Edit/Write → Task 4 step 2. ✓
- CLAUDE.md read-side pointer on first write → Task 4 step 6. ✓
- Supersede-by-slug (one-line status edit) → Task 4 step 7. ✓
- Manual `/handover` (mid-session capture) → Task 4. ✓
- Stop hook, once/session, gates (loop guard, sentinel, substantiveness), soft offer, no block → Task 2 + Task 5. ✓
- Global `~/.claude/settings.json` Stop wiring, idempotent → Task 3. ✓
- `additionalContext` default + `systemMessage` fallback + smoke-test the open item → Task 2 (mode) + Task 5 step 5. ✓
- Length budget, git-wins-for-facts reconciliation, default-accept approval → Task 4. ✓
- Rotation at ~1000 lines (offered, never silent) → Task 4 notes + README. ✓
- Never commits → constraints + Task 4 step 6 + installer comment. ✓

**Placeholder scan:** No TBD/TODO; every code + test step contains complete content. ✓

**Type/name consistency:** `handover-offer.sh`, `handover-lint.sh`, `install.sh`, `SKILL.md`, sentinel `${TMPDIR:-/tmp}/claude-handover-<session_id>`, env `HANDOVER_MIN_TRANSCRIPT_LINES` / `HANDOVER_OFFER_MODE`, and settings path `.hooks.Stop[].hooks[].command` are used identically across Tasks 1–5. ✓

**Note (honest deviation from strict TDD):** Task 4 (SKILL.md) is agent-prose and cannot carry a red→green unit test; its acceptance is a manual dry-run whose *output* is checked by Task 1's validator. All three shell artifacts (Tasks 1–3) are strict TDD.
