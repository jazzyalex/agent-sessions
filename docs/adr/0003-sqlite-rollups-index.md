# 0003: SQLite Rollups Index for Sessions Analytics

Date: 2025-10-22
Status: Accepted

## Context

Analytics and search operate over large in‑memory arrays and sometimes need full transcript parsing. This leads to UI stalls and high CPU when opening Analytics or performing actions over thousands of sessions. We want a minimal, robust index to make Analytics and metadata‑level search fast without changing session file formats or the UI.

## Decision

Adopt a small SQLite database (system `sqlite3`) to persist:

- `files(path PK, mtime, size, source, indexed_at)` for incremental refresh.
- `session_meta(session_id PK, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title, messages, commands)` for fast startup and metadata filtering.
- `session_days(day, source, session_id, model, messages, commands, duration_sec, PK(day, source, session_id))` per‑session per‑day splits.
- `rollups_daily(day, source, model, sessions, messages, commands, duration_sec, PK)` derived from `session_days` for instant queries.
- Optional `rollups_tod(dow, bucket, messages)` for future heatmap.

Pragmas: `WAL` journal, `synchronous=NORMAL`.

Indexing runs in the background at `.utility` priority. On Refresh, the indexer scans current files, diffs against `files`, and reindexes only new/changed files. Codex JSONL files with `mtime` < 60s are treated as hot and skipped until stable.

## Rationale

- Minimal scope delivers maximum benefit: Analytics queries become O(1) over tiny rollup tables; no need for full transcript parsing at view time.
- Low risk: Local only, additive, keeps existing in‑memory paths as fallback.
- Efficient refresh: single transaction per file; day‑level recompute limited to affected days.
- Scale headroom: 100K sessions fits easily in `session_days` with small on‑disk footprint.

## Alternatives Considered

1. Full FTS5 with external‑content tables now – higher complexity, not required for Analytics; defer.
2. Rebuild in memory each launch – fast to implement but doesn’t solve beachballs/energy.
3. Batch‑on‑quit rollups – less predictable; users expect Refresh to reflect changes.

## Consequences

- First run builds the index in background; UI remains responsive. Analytics wiring will be switched to read from rollups in a subsequent change.
- Refresh runs are quick: only changed files reparse; per‑day rollups updated for affected days.
- Tests cover day split math, idempotency, and basic schema bootstrap.

## Migration / Rollout

No data migration needed. The database is created at `~/Library/Application Support/AgentSessions/index.db` on first use. Feature is guarded by isolated code paths; sessions list/search operate as before until analytics is rewired to use the index.

