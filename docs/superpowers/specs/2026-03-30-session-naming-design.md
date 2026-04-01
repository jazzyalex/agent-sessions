# Show Claude Session Names

**Issue:** [agent-sessions#26](https://github.com/jazzyalex/agent-sessions/issues/26)
**Date:** 2026-03-30

## Problem

When a user renames a Claude Code session via `/rename`, the custom name is not shown in Agent Sessions. The app derives titles from transcript content (first user message), so all sessions display as ambiguous command fragments instead of the user-chosen name.

## Data Sources

Claude Code persists the `/rename` result in three locations:

| Location | Field | Persistence |
|---|---|---|
| JSONL `type: "custom-title"` | `customTitle` | Permanent, in transcript |
| JSONL `type: "agent-name"` | `agentName` | Permanent, in transcript |
| `~/.claude/sessions/{PID}.json` | `name` | Ephemeral, active sessions only |
| `sessions-index.json` entry | `name` | Permanent but currently always `null` |

## Design

### Title precedence (highest to lowest)

1. **Custom title** — from JSONL `custom-title` / `agent-name` records, or `sessions-index.json` `name` field
2. **Derived title** — existing logic (first user message, assistant fallback, etc.)

### Changes by file

#### `Session.swift`

- Add `customTitle: String?` stored property.
- Add it to both initializers (full and lightweight) with default `nil`.
- Add to `CodingKeys`.
- In the `title` computed property, return `customTitle` immediately when non-nil, before all existing fallback logic.

#### `ClaudeSessionParser.swift`

**Lightweight parser** (`lightweightSession` → `ingest` closure):
- Track a `var customTitle: String?` alongside existing metadata vars.
- In `ingest`, when `type == "custom-title"`, capture `obj["customTitle"]`.
- When `type == "agent-name"`, capture `obj["agentName"]` as fallback (only if `customTitle` still nil).
- Pass `customTitle` to Session constructor. When `customTitle` is non-nil, still derive `lightweightTitle` normally (for search/fallback) but `Session.title` will return `customTitle` first.

**Full parser** (`parseSession`):
- Same extraction logic scanning all JSONL lines. Last `custom-title` wins.
- Set `customTitle` on the returned Session.

#### `DB.swift`

- Add `custom_title TEXT` column to `session_meta` table.
- Migration guard: `if !tableHasColumn(db, table: "session_meta", column: "custom_title")` → `ALTER TABLE`.
- Schema migration key to trigger reindex so existing sessions pick up custom titles.

#### `SessionMetaRepository` (in DB.swift)

- Read `custom_title` in `fetchAll` / `fetchBySessionID` queries → map to `customTitle`.
- Write `custom_title` in upsert.

#### `SessionIndexer.swift`

- Thread `customTitle` through session merge/update paths (same pattern as `lightweightTitle`).

#### `ClaudeSessionDiscovery.swift` (sessions-index.json parsing)

- When parsing `sessions-index.json` entries, read the `name` field.
- If non-nil, pass it as `customTitle` on the discovered session. Future-proofs for when Claude Code populates this field.

### Edge cases

- **`/rename` mid-session:** The `custom-title` record may land in the middle of long JSONL files. The lightweight parser reads head (256KB) + tail (256KB). For typical sessions this covers the rename. On full parse, all lines are scanned — always found.
- **Multiple renames:** Last `custom-title` record wins. Tail scan naturally favors the latest.
- **No rename:** `customTitle` is nil → falls through to existing derived title. Zero behavior change.
- **`custom-title` vs `agent-name`:** Both records are emitted by Claude Code on rename. Prefer `custom-title` (more explicit). `agent-name` is fallback only.

### What stays the same

- UI display — `session.title` is already used everywhere in table views. No view changes needed.
- OpenCode sessions — untouched, already have their own `title` field.
- Codex sessions — untouched, use `codexPreviewTitle`.
- Search indexing — `session_search` already indexes the title; custom titles will be searchable automatically.
