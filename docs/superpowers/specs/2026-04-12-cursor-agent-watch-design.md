# Cursor Agent-Watch Monitoring

**Date:** 2026-04-12
**Status:** Approved
**Scope:** Add Cursor as the 8th monitored agent in the agent-watch system

## Problem

Cursor is fully integrated into Agent Sessions as a session provider (v3.2), with a
parser, indexer, discovery, and UI. But agent-watch does not monitor it — there's no
entry in `agent-watch-config.json`, no matrix/ledger tracking, and no fixtures for
schema drift detection. If Cursor changes its transcript format, we won't know until
users report broken sessions.

## Decisions

- **Fingerprint scope:** JSONL transcripts only for schema fingerprinting; SQLite chat
  databases get a lightweight health probe (table exists, metadata parseable), not deep
  schema tracking.
- **Discovery contract:** Transcripts only —
  `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` (includes subagents).
- **Version tracking:** Date-based (`2026.04.12`) since Cursor doesn't embed a version
  in transcripts. `version_field: "not_logged"`.
- **No prebump driver:** Cursor lacks a headless `cursor -p "prompt"` mode. Weekly
  monitoring with fresh transcripts is sufficient for v1.
- **No upstream feed:** No public release API for Cursor CLI versions. `upstream: []`.
- **`cursor --version` returns null:** The Cursor CLI is installed but without the IDE it exits non-zero ("No Cursor IDE installation found"). `agent_watch.py` already handles non-zero exit by setting `installed = None`, so this is the expected steady state — not a monitoring failure. `verified_version` will still be populated from the matrix.

## Cursor JSONL Schema

Cursor transcripts use `role` as the top-level discriminator (not `type` like other
agents). Each line is:

```json
{"role": "user|assistant", "message": {"content": [...]}}
```

Content block types observed across all local transcripts (64 lines, 7 files):

| Content type | Keys |
|---|---|
| `text` | text, type |
| `tool_use` | input, name, type |

Additional types supported by the parser but not yet observed locally:
`tool_result`, `thinking`, `tool-use`, `tool-call`.

Top-level keys are uniform: `role`, `message` (both roles).

## Design

### 1. New Fingerprinting Function

`_cursor_transcript_schema_fingerprint()` in `agent_watch.py`:

- Reads JSONL lines, normalizes `role` value before bucketing:
  `user`/`human` → `user`, `assistant`/`model` → `assistant`, `system` → `system`,
  anything else → `assistant`. This matches the normalization in
  `CursorSessionParser.swift:187-193` so the monitor and parser agree on role names.
- For each line, also walks `message.content[]` and buckets content block keys by their
  `type` value (prefixed as `content.text`, `content.tool_use`, etc.)
- Returns the standard `type_keys` / `type_counts` / `parse_errors` dict

Example output:
```json
{
  "type_keys": {
    "user": ["message", "role"],
    "assistant": ["message", "role"],
    "content.text": ["text", "type"],
    "content.tool_use": ["input", "name", "type"]
  },
  "type_counts": {"user": 30, "assistant": 34, "content.text": 50, "content.tool_use": 14}
}
```

This lets the standard `_schema_diff()` function detect:
- New top-level keys on user/assistant (structural drift)
- New content block types (e.g. `content.image`)
- New keys within content blocks (e.g. `tool_use` gaining a `callId` field)

### 2. SQLite Probe Script

New script `scripts/cursor_sqlite_probe.py`:

1. Glob for `~/.cursor/chats/*/*/store.db`, pick newest by mtime
2. Open with sqlite3, check `meta` table exists
3. Read key="0" row, hex-decode the value, parse as JSON
4. Verify expected keys present: `agentId`, `name`, `createdAt`
5. Output JSON report: `{"ok": true/false, "db_path": "...", "meta_keys": [...], "error": null}`

Exit codes: 0 = ok, 1 = no db found, 2 = meta table missing/unreadable, 3 = unexpected schema.

### 3. Config Entry

Add to `agent-watch-config.json`:

```json
"cursor": {
  "cadence": { "daily": false, "weekly": true },
  "installed_version_cmd": ["cursor", "--version"],
  "verified_version_source": "docs/agent-support/agent-support-matrix.yml#agents.cursor.max_verified_version",
  "upstream": [],
  "risk_keywords": {
    "schema": ["session", "transcript", "json", "jsonl", "agent-transcripts", "format", "tool_result", "thinking"],
    "usage": []
  },
  "weekly": {
    "local_schema": {
      "kind": "cursor_transcript_newest",
      "roots": ["~/.cursor/projects"],
      "glob": "**/agent-transcripts/**/*.jsonl",
      "max_lines": 2500
    },
    "freshness_window_days": 30,
    "discovery_path_contract": {
      "description": "Cursor transcripts under ~/.cursor/projects/*/agent-transcripts/*/*.jsonl",
      "patterns": ["/\\.cursor/projects/.+/agent-transcripts/.+\\.jsonl$"]
    },
    "probes": [
      {
        "kind": "script",
        "label": "cursor_sqlite_probe",
        "argv": ["./scripts/cursor_sqlite_probe.py"],
        "timeout_seconds": 30,
        "parse": "cursor_sqlite_json"
      }
    ]
  }
}
```

### 4. Fixtures

Create under `Resources/Fixtures/stage0/agents/cursor/`:

**`small.jsonl`** — Minimal 4-line transcript:
- 1 user (text only)
- 1 assistant (text only)
- 1 user (text only)
- 1 assistant (text + tool_use)

**`large.jsonl`** — Richer 10-12 line transcript:
- Multiple user/assistant turns
- Content types: text, tool_use, tool_result, thinking
- Covers all content-type keys the parser supports
- Note: `tool_result` and `thinking` are synthetic (not yet observed in local transcripts) — this is aspirational baseline coverage, not evidence-derived. The fingerprinter will register them as baseline types so future appearance in live sessions does not trigger false drift.

**`schema_drift.jsonl`** — Starts empty or with a single placeholder line. Updated
when future drift is detected.

**`subagent/parent.jsonl`** + **`subagent/subagents/child.jsonl`** — Exercises the
subagent discovery path (`agent-transcripts/<parentUUID>/subagents/<uuid>.jsonl`)
that `CursorSessionParser.swift:360` explicitly supports. Minimal (2-3 lines each).
The fingerprinter treats these identically to top-level transcripts (same schema
shape), so this is primarily a contract test for the discovery glob, not a separate
schema bucket.

All fixtures redacted per guardrails in SKILL.md §7 (no real prompts, short
placeholders, preserve key structure).

### 5. Wiring in `agent_watch.py`

Three dispatch points must be updated:

**a) `verified_map` (line ~1544):** Add `"cursor": matrix_versions.get("cursor")` so
version comparisons drive severity/bump decisions. Without this, Cursor never
participates in `installed_newer_than_verified` / `upstream_newer_than_verified`.

**b) Weekly local-schema dispatcher (line ~1684):** The existing `kind` branch only
recognizes `jsonl_newest`, `gemini_session_json_newest`, and
`opencode_storage_latest_session`. Add a new branch:
```python
elif kind == "cursor_transcript_newest":
    max_lines = int(local_schema_cfg.get("max_lines") or 2500)
    newest = _newest_file(roots, glob)
    if newest:
        local_fp = _cursor_transcript_schema_fingerprint(newest, max_lines=max_lines)
```
Without this, Cursor falls through to `local_schema.error = "no_files_found"`.

**c) Matrix-key evidence mapping (line ~1670):** Add `"cursor": "cursor"` to the dict
that maps config agent names to matrix YAML keys.

**d) `_baseline_type_keys_for_agent`:** Since Cursor uses role-based bucketing, the
baseline must also use `_cursor_transcript_schema_fingerprint` for Cursor fixtures.
Add a branch so fixture fingerprinting matches live fingerprinting.

**e) Probe parse handler:** Add `"cursor_sqlite_json"` parse handler for the SQLite
probe output.

### 6. Matrix / Ledger / Tracking Updates

**`agent-support-matrix.yml`:**
```yaml
cursor:
  max_verified_version: "2026.04.12"
  version_field: "not_logged"
  evidence_fixtures:
    - "Resources/Fixtures/stage0/agents/cursor/small.jsonl"
    - "Resources/Fixtures/stage0/agents/cursor/large.jsonl"
    - "Resources/Fixtures/stage0/agents/cursor/schema_drift.jsonl"
    - "Resources/Fixtures/stage0/agents/cursor/subagent/parent.jsonl"
    - "Resources/Fixtures/stage0/agents/cursor/subagent/subagents/child.jsonl"
```
The subagent fixtures have the same schema shape as top-level transcripts and contribute no additional keys, but including them in `evidence_fixtures` ensures the baseline fingerprinter exercises the subagent path via `_baseline_type_keys_for_agent` and keeps the fixture list consistent with what the discovery glob finds.

**`agent-support-ledger.yml`:** New entry with initial Cursor verification.

**`agent-json-tracking.md`:** Log entry documenting initial Cursor monitoring setup.

### 7. Skill Doc Updates

**`skills/agent-session-format-check/SKILL.md`:**
- Add Cursor row to §4 Discovery Path Contracts table
- Add brief §3-style section on Cursor storage (dual backend, JSONL + SQLite)

**`.claude/skills/agent-session-format-check.md`:**
- Add Cursor row to the discovery contracts quick-reference table

## Files Changed

| File | Action | Description |
|---|---|---|
| `scripts/agent_watch.py` | Modify | Add `_cursor_transcript_schema_fingerprint()`, wire into weekly/baseline dispatchers, add `cursor_sqlite_json` parse handler |
| `scripts/cursor_sqlite_probe.py` | Create | Lightweight SQLite meta-table health check |
| `docs/agent-support/agent-watch-config.json` | Modify | Add `cursor` agent entry |
| `docs/agent-support/agent-support-matrix.yml` | Modify | Add `cursor` agent |
| `docs/agent-support/agent-support-ledger.yml` | Modify | Initial Cursor entry |
| `docs/agent-json-tracking.md` | Modify | Log entry |
| `Resources/Fixtures/stage0/agents/cursor/small.jsonl` | Create | Minimal fixture |
| `Resources/Fixtures/stage0/agents/cursor/large.jsonl` | Create | Rich fixture |
| `Resources/Fixtures/stage0/agents/cursor/schema_drift.jsonl` | Create | Drift placeholder |
| `Resources/Fixtures/stage0/agents/cursor/subagent/parent.jsonl` | Create | Subagent parent fixture |
| `Resources/Fixtures/stage0/agents/cursor/subagent/subagents/child.jsonl` | Create | Subagent child fixture |
| `docs/agent-support/workflow.md` | Modify | Update "all seven agents" → "all eight agents" |
| `skills/agent-session-format-check/SKILL.md` | Modify | Add Cursor sections |
| `.claude/skills/agent-session-format-check.md` | Modify | Add Cursor to contracts table |

## Testing

After implementation:
1. Run `./scripts/agent_watch.py --mode weekly` — Cursor should appear with `severity=none`, `schema_matches_baseline=true`
2. Verify `verified_version` is populated (not `null`) — confirms `verified_map` wiring
3. Verify discovery contract passes (finds a `.jsonl` transcript)
4. Verify SQLite probe returns `ok=true`
5. Verify role normalization: if a fixture uses `"role": "human"`, the fingerprinter should bucket it as `user` (not create a separate `human` bucket)
6. Verify subagent fixture is reachable by the discovery glob
7. Run Xcode tests to confirm fixtures parse correctly
