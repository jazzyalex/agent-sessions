# Multiple Claude Config Dirs — Implementation Plan

## Problem
Claude sessions are split across separate config dirs (e.g., launching with `CLAUDE_CONFIG_DIR=~/.claudeHome`), but Agent Sessions only scans `~/.claude`. Add multi-root discovery so all sessions appear.

## Constraints
- No coding now; this is a concrete plan.
- Keep user setup minimal; prefer zero new config where possible.
- Avoid regressions for single-dir users.

## Option 1 — Read Claude’s Own Config + Sibling Roots (No New Files)
### Overview
Auto-detect additional Claude roots by reading standard Claude artifacts and scanning peer dirs that Claude itself would use. Zero user-facing settings; works whether the app inherits env vars or not.

### Discovery Sources (in order)
1. Environment (if present): `CLAUDE_CONFIG_DIRS` (colon-separated), `CLAUDE_CONFIG_DIR` (single).
2. Default: `~/.claude`.
3. Sibling scan: include any `~/.claude*` that look like valid Claude roots.
4. Managed path (best-effort): `/Library/Application Support/ClaudeCode/.claude` (only if it contains session artifacts).

### Valid Root Heuristic (any true)
- `settings.json` exists, or
- `history.jsonl` exists, or
- `projects/` exists, or
- `todos/` exists.

### Implementation Outline
- `AgentSessions/Services/SessionDiscovery.swift`
  - Add `candidateRoots() -> [URL]` that:
    - Expands `~` and `$VARS`, resolves symlinks, dedupes.
    - Applies valid-root heuristic.
  - Update `ClaudeSessionDiscovery.discoverSessionFiles()` to iterate all candidates, union `.jsonl/.ndjson`, dedupe by canonical path, sort by mtime desc.
  - `sessionsRoot()` returns the first existing candidate (for display/logs only).
- `AgentSessions/Services/ClaudeSessionIndexer.swift`
  - Log discovered roots; set empty state based on the union.

### Pros
- No new config format.
- Works for GUI launches (sibling scan) and terminal launches (env).

### Cons/Risks
- Sibling scan might include unrelated dirs if a user creates similarly named folders; mitigated by valid-root heuristic.

## Option 2 — Env-First With Optional Dotfile (Minimal, Explicit)
### Overview
Prefer explicit sources from environment; optionally read a lightweight dotfile that lists Claude roots (one per line, `#` comments ok). Still default to `~/.claude`.

### Discovery Sources (in order)
1. `CLAUDE_CONFIG_DIRS` and `CLAUDE_CONFIG_DIR`.
2. Optional dotfile (choose one; both supported if desired):
   - `~/.claude-dirs`
   - `~/Library/Application Support/AgentSessions/claude-dirs.txt`
3. Default: `~/.claude`.

### Dotfile Rules
- Expand `~`/`$VARS`, ignore blanks and lines starting with `#`.
- Resolve symlinks, dedupe; skip missing/non-dirs.

### Implementation Outline
- Same code touchpoints as Option 1, but candidate assembly reads env + optional dotfile and skips sibling scanning entirely.

### Pros
- Fully explicit; no heuristic scanning.
- Simple to document in README (one small section).

### Cons/Risks
- Requires a tiny bit of user setup if env is not inherited by GUI apps.
- Introduces a new file users may need to manage.

## Common Behavior (Both Options)
- File selection: include only `.jsonl` and `.ndjson`.
- Dedupe by `url.resolvingSymlinksInPath()`.
- Sort sessions by modification time descending.
- Logs: print all roots and total files found per root and in total.
- Empty state: show only if all roots are missing/empty.
- Performance: use `.skipsHiddenFiles`; no full parse during listing.

## Validation (When Implemented)
- Build: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS' build`.
- Manual:
  - Create two Claude roots (e.g., `~/.claudeHome`, `~/.claudeWork`) with sample `projects/.../*.jsonl`.
  - Confirm union indexing, dedupe, ordering, and empty‑state behavior.
- Docs:
  - README “Multiple Claude Config Dirs”:
    - Option 1: automatic sibling detection.
    - Option 2: env variables and optional dotfile examples.

## Recommendation
Default to Option 1 for zero-config convenience; keep Option 2 as a fallback/explicit mode if users request tighter control.

