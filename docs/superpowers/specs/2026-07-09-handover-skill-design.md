# Handover Skill — Design Spec

**Date:** 2026-07-09
**Status:** approved (design) — pending implementation plan
**Author:** Alex (with Claude, Fable review, hook-mechanics research)

## Problem

Sessions are archived, not deleted. Restoring workflow later means grepping across
many archived sessions — slow and lossy. The user already writes handoff docs by hand
(~9 found across `docs/` and `Marketing/`), but they're ad-hoc, inconsistently named,
and scattered. Formalize that habit into a repeatable, low-friction system.

## Goal

A **global** Claude Code skill (`/handover`, usable in any repo) that appends a dated,
structured entry to a **per-repo `RepoHandover.md`** at the repo root — newest-first.
Each entry serves both a future agent (actionable state) and the human (skimmable
narrative) in one format. Plus a **global Stop hook** that offers a handover once, at
session close, when the session was substantive.

Success = weeks later, opening `RepoHandover.md` (or a fresh agent reading its newest
entry) restores enough context to resume without grepping archived sessions.

## Non-goals

- No cross-repo/global aggregation log (per-repo file only).
- No growing link-index section, no prose "summary" section (identified as where the
  user's past docs accumulated filler).
- The skill never commits — it writes; the user commits (repo rule).
- No in-place "current status" pin at file top (newest entry already serves as the pin).

## Storage model

- One `RepoHandover.md` at each repo root. Lives with the code, travels in git.
- Entries appended **newest-first** (top of file), each under a `##` heading.
- Committed by the user for durability — but the skill must never run `git commit`.

## Entry format

Each entry: a `##` heading, a fixed 2-line key block, a one-line state, then optional
sections. Every section except the header/key-block/state is optional — a mid-session
"capture state" entry may have only State + Next steps.

```markdown
## 2026-07-09 14:32 · runway-auth · AS-owned OAuth (P2)
status: in-progress          # in-progress | blocked | done | superseded-by:<date>
branch: main @ 9ade2753 (dirty: 2 files in ClaudeOAuth/)

**State in one line:** No-CLI ladder shipped; AS-owned OAuth store is next.

### Already decided / don't redo
- Desktop creds ≠ CLI OAuth — don't reuse
- CLI logout hangs the tmux probe — abandoned

### Key files
- `AgentSessions/.../ClaudeUsageSourceManager.swift:120` — source selection

### Verified
- Probe hardening confirmed by test suite (commit 9ade2753)

### Believed / unverified
- P2 store likely needs keychain scoping — not yet checked

### Next steps (prioritized)
1. Build AS-owned OAuth token store (P2)
2. DECIDE: fall back to Desktop creds read-only, or stay fully separate?

### Risks / landmines
- Test-build re-sign → invisible app — mitigation: build-only derivedData

### How to verify
- `xcodebuild … test` on the ClaudeOAuth suite
```

### Section semantics (ordered by signal)

1. **Header** — `## DATE TIME · <scope-slug> · <title>`. Slug is derived from the branch
   name or plan-doc name (not freestyled) so supersede-matching can fire.
2. **Key block (2 lines, always present, always this order):**
   - `status:` — one of `in-progress | blocked | done | superseded-by:<date>`
   - `branch:` — `<branch> @ <short-hash> (dirty: <n> files[ in <dir>])`. The hash +
     dirty count is the #1 resume signal (uncommitted code-complete branches are the
     top resume hazard).
   - Not YAML frontmatter (only valid at file top; would break mid-file). Parseable via
     `grep -A2 '^## \d{4}-\d{2}-\d{2}'`.
3. **State in one line** — bold, the entry's pin text.
4. **Already decided / don't redo** — highest-value section; the one thing grep can't
   reconstruct. Settled decisions + attempted-and-failed work.
5. **Key files** — `path:line` inline. Sourced from actual Edit/Write tool calls this
   session, NOT files merely mentioned in conversation.
6. **Verified** — a claim goes here ONLY if its evidence exists as a real tool result in
   the transcript (git hash, test output, sample). No exceptions.
7. **Believed / unverified** — everything else. Claims from prose/memory land here.
8. **Next steps (prioritized)** — numbered or P0/P1/P2. Items needing the human get a
   `DECIDE:` prefix (open questions are merged here, not a separate section).
9. **Risks / landmines** — risk → mitigation/stop-condition pairs.
10. **How to verify** — build/test command or QA checklist confirming the entry's claims
    still hold. Domain-dependent; omit if N/A.

### Conventions

- File refs are inline `path:line` (jumpable, greppable), not a separate table.
- Every claim is paired with its verification method or filed under Believed.
- Hard length budget: ~50 lines / ~600 words per entry. The drafter trims before
  showing. (Past docs were long because each was the *only* record; a running log
  must stay lean.)

## Retrieval (closes the write-only loop)

A `RepoHandover.md` nobody opens is a prettier grep problem. On first write in a repo,
the skill adds one line to that repo's `CLAUDE.md`:

> Before starting work, read the newest entry in `RepoHandover.md`.

Agents read `CLAUDE.md`; they don't spontaneously open arbitrary root files. This is
what makes future sessions actually consume the handover.

## Triggers

### 1. Manual `/handover` (any time)

Capture current state on demand, even mid-session (not only at close). The skill:

1. Runs `git status` / `git log` / `git diff --stat` at draft time — ground truth for
   branch, hash, dirty files, commits this session. Never inferred from conversation.
2. Extracts, in reliability order:
   - Files touched via Edit/Write tool calls → Key files.
   - User messages containing rejections/corrections → Already decided / don't redo.
   - Tool-result evidence (git hashes, test output) → Verified; everything else → Believed.
   - Final todo/plan state → Next steps.
3. Drafts an entry within the length budget, shows it, **default-accept on Enter** with
   inline edit allowed.
4. On accept: prepends to `RepoHandover.md` (creating it + the CLAUDE.md pointer on
   first use). Does NOT commit.
5. Supersede check: if the new entry's scope-slug matches an older entry, offer to stamp
   the older one `status: superseded-by:<date>` (one-line edit, prose untouched).

### 2. Global Stop hook (once per session, at close)

Configured in `~/.claude/settings.json` under the `Stop` event (SessionEnd fires too
late and cannot inject anything back into the conversation). The hook offers a handover
at most once per session; a second capture relies on manual `/handover`.

Gates, evaluated in order — silent no-op (exit 0) unless all pass:

1. **Loop guard:** `stop_hook_active == true` → exit 0.
2. **Once per session:** sentinel `/tmp/claude-handover-<session_id>` exists → exit 0.
   Otherwise create it when offering.
3. **Substantiveness:** either
   - `git -C "$cwd" diff --shortstat` shows non-trivial changes (or ≥N tool-uses), OR
   - a `type: "prompt"` (Haiku) hook judges the session substantive.
     Both are viable; the smoke-test (below) picks the cleaner one.

On pass, emit a soft offer — do NOT force work:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": "This was a substantive session. Offer the user a one-line handover they can save via /handover; do not write anything unless they say yes."
  }
}
```

Fallback: if `additionalContext` proves flaky at making Claude actually *ask*, use the
`systemMessage` field (shown straight to the user) as the offer channel. Do NOT use
`decision: "block"` — that forces continuation and reads as nagging.

## File hygiene

- **No top-of-file pin** — newest entry's State line is the pin; a separate pin drifts.
- **Superseding** via the `status:` key, scoped by slug (see manual flow step 5).
- **Rotation** (only once it bites, ~1000 lines): offer to move all-but-newest-10 to
  `RepoHandover-archive.md`. Never silent.

## Auto-draft failure modes (design against these)

- **Hallucinated verification** — mitigated by the transcript-evidence rule: a claim is
  Verified only with a real tool result in the transcript; else Believed.
- **Over-long entries** — hard length budget; trim before showing.
- **Conversation/git mismatch** — if conversation says "committed" but tree is dirty (or
  vice versa), flag the discrepancy rather than pick one. Git wins for facts;
  conversation wins for intent.
- **Approval fatigue** — default-accept on Enter + inline edit. Heavyweight approval
  kills the Stop-hook path within a week.

## Open validation item

Before locking implementation: smoke-test that `hookSpecificOutput.additionalContext` on
`Stop` reliably makes Claude *ask* the user (rather than silently proceed or silently
skip). If inconsistent, switch the offer channel to `systemMessage`, and/or use the
`type: "prompt"` hook variant for the substantiveness judgment.

## Components (isolation boundaries)

1. **`/handover` skill** — a markdown skill under `~/.claude/skills/handover/`. Owns
   drafting, formatting, file write, CLAUDE.md pointer, supersede check. Depends on git
   and the transcript; no other state.
2. **`RepoHandover.md` format** — a documented convention (this spec). The skill and any
   future reader/tool depend on the 2-line key block being parseable.
3. **Stop hook** — a small shell (or prompt) hook + `~/.claude/settings.json` entry.
   Owns only the once-per-session substantiveness offer. Writes nothing; just nudges.

Each is independently testable: the skill via a scripted session, the format via a grep
parse test, the hook via feeding it sample stdin JSON and asserting the emitted JSON.
