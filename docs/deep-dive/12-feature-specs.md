# Feature Specs (painkillers for modern vibe coding)

This file describes concrete, shippable feature specs. It is intentionally specific.

The north star is: “local-first memory and limits radar for terminal agents”.

## Spec 1: Context Pack export (hero feature)

### Problem
Users lose time and quality when they have to re-explain a long session to a fresh agent chat.

### User story
“I want to pick a session (or a slice of it) and get a clean, pasteable summary that lets me continue work immediately in a new agent session.”

### Success criteria
- A user can resume work in under 2 minutes without rereading the transcript.
- The exported pack is readable by humans and agents.
- The pack is safe to share by default (redacts sensitive content).

### MVP scope
- Export “whole session” and “selected range” (if selection exists in transcript view).
- Two export formats:
  - Markdown (primary)
  - Plain text (fallback)
- Two modes:
  - Normal (no redaction)
  - Share-safe (redaction on, default)

### Output format (recommended)

```md
# Context Pack

## Snapshot
- Source: Codex | Claude | Gemini | Copilot | OpenCode | Droid
- Repo: <best-effort repo name>
- CWD: <best-effort, redacted if share-safe>
- Branch/worktree: <best-effort>
- Session: <short ID> (<start> to <end>)

## Goal
<one paragraph>

## What changed
- <bullet list>

## What is verified
- Build/tests: <what ran, what passed>

## Decisions
- <decision>: <rationale>

## Commands and tools (curated)
- <command>

## Next steps
- [ ] <step 1>
- [ ] <step 2>
```

### Redaction (share-safe mode)
Rules should be conservative (false positives are fine):
- Replace absolute paths with `<PATH>`.
- Replace common secret patterns:
  - API keys/tokens (common prefixes, long base64/hex)
  - private key headers
- Replace usernames and home directories (macOS/Linux) with `<USER>`.

Non-goals for MVP:
- Perfect secret detection
- Cloud sync

### Implementation notes (no code, just design)
- Start with rule-based redaction only.
- Keep an “expand and show raw” option so users can verify nothing critical was removed.
- Treat Context Pack as a first-class artifact: add “Copy” and “Save” actions.

## Spec 2: Project Memory (project DNA and decisions)

### Problem
Vibe coding fails when the agent violates project conventions. Developers describe this as “the smell”.

### User story
“I want a per-repo memory that captures conventions and decisions so I can reuse them across sessions and include them in prompts.”

### Success criteria
- The user can define “how we build things here” once, and reuse it across sessions.
- The memory can be included in Context Packs and resume prompts.

### MVP scope
- A “Project Memory” panel for the selected repo.
- Manual editing only at first (no auto extraction required).
- Stored locally (App Support or DB).

### Suggested content structure
- Build/test commands
- Preferred libraries and patterns
- “Do not” list (anti-patterns)
- Architectural decisions (short)
- Links to key docs and folders

### Import sources (nice-to-have)
- Detect and offer to import from:
  - `AGENTS.md` / `agents.md`
  - `CLAUDE.md`
  - cc-sessions task files (if present)

Non-goals:
- Trying to infer conventions automatically before the manual path is excellent.

## Spec 3: Command Palette (keyboard-first control)

### Problem
Power users do not want to hunt in menus.

### User story
“I want one palette to do everything important without taking my hands off the keyboard.”

### MVP commands (minimum set)
- Open session by fuzzy search
- Toggle agent/source filters
- Export Context Pack (share-safe default)
- Resume in Terminal / iTerm
- Jump: next/previous user prompt, tool call, error (transcript navigation)

### UX constraints
- Opens fast, no network, no heavy parsing.
- Results stream as the user types.

## Spec 4: DB-backed full-text search (FTS) for scale

### Problem
“Generate transcripts then search” is expensive and does not scale to thousands of sessions.

### User story
“I want search to be instant even when I have thousands of sessions and very large logs.”

### Success criteria
- Searching common terms is instant (<100ms perceived) on large corpora.
- Search does not cause a CPU spike that fights the user while typing.

### MVP scope
- SQLite FTS index of normalized session search text.
- Use `mtime/size` to skip unchanged files (you already track this).
- UI search hits return session IDs; full parsing happens only on open.

### Data model (summary)
- `session_meta` remains the metadata table.
- Add `session_text` + `session_text_fts` (see `docs/deep-dive/10-refactor-roadmap.md` Appendix B).

Non-goals:
- Semantic embeddings
- Cloud indexing

## Spec 5: Quality signals extracted from session logs

### Problem
Vibe coding fails when you cannot tell what was verified.

### User story
“Before I trust the output of a session, I want a quick signal: did we run builds/tests, and were there errors near the end?”

### MVP signals (heuristics, best-effort)
- Detect build/test commands in tool calls and outputs:
  - `xcodebuild`, `swift test`, `npm test`, `pnpm test`, `pytest`, `go test`, `cargo test`, `dotnet test`, etc.
- Detect error bursts:
  - tool outputs containing “error:”, “fatal:”, “Traceback”, etc.
- Detect “ended in failure”:
  - last N events include errors, or last command exit suggests failure (where available)

### UI placement
- Session list: small “Quality” indicator (pass/unknown/fail)
- Session detail: “Quality summary” section with evidence lines

Non-goals:
- Full CI parsing
- Perfect correctness (this is a signal, not a proof)

## Spec 6: Workstreams view (repo/worktree/branch grouping)

### Problem
Modern workflows are multi-branch and multi-session. Users need structure.

### User story
“Show me my work by project and branch/worktree so I can pick up the right thread.”

### MVP grouping rules (best-effort)
- Group by repo (from existing repo detection).
- Within repo, group by:
  - branch if detected
  - otherwise by cwd (worktree path heuristics)
- Provide quick filters:
  - “Active today”
  - “Has errors”
  - “Has commands”

Integration win:
- This makes Agent Sessions a natural companion to Crystal/Claude Squad without running sessions itself.

