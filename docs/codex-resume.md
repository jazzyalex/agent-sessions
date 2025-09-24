# Codex CLI Resume Behavior (v0.34)

This document records how `codex --resume` and `--continue` work in Codex CLI 0.34, based on source review. It guides how Agent Sessions should mirror and integrate with the official flow.

## Flags and UX
- `--resume`: opens a TUI picker of recorded sessions instead of starting fresh.
- `--continue`: resumes the most recent recorded session without showing the picker. Implemented but may be hidden from `--help` in some builds.
- The picker shows recent sessions newest-first with a one-line preview derived from the first “real” user message (IDE scaffolding/instructions stripped).

## Session Source and Layout
- Root: `$CODEX_HOME/sessions` (or `~/.codex/sessions`).
- Sharding: `YYYY/MM/DD/` subfolders.
- File naming: `rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl` (one file per session).

## Listing and Sorting
- Order: newest-first by timestamp parsed from the filename; stable secondary sort by the UUID (both descending).
- Not based on file mtime.
- Scope: global across all repos; no cwd/repo filter is applied by Codex.

## Pagination
- Page size: 25 entries per fetch.
- Scan cap: 100 files per fetch maximum. If the cap is hit before filling a page, the picker exposes pagination via a cursor.
- Cursor: `{ ts, id }` derived from the last listed entry (filename timestamp and UUID). Left/Right (or `a`/`d`) page through.

## Row Preview Logic
- For each file, the picker reads only the first N records (N = 10).
- It extracts the first plain user message and strips surrounding IDE/instruction wrappers for the preview line.

## Resume Handoff
- Selecting a row yields the absolute JSONL path.
- The engine calls its conversation manager to load the entire JSONL history and respawn the agent with full prior context (a true resume; not a partial replay).

## Hidden Config Override
- Undocumented config key: `experimental_resume: <absolute .jsonl path>`.
- If present, the CLI resumes that session directly on startup, bypassing the picker.

## Implications for Agent Sessions
- Default list: show “Recent (global)” newest-first using filename timestamps; do not assume repo scoping.
- Title/preview: replicate the head-parse behavior to surface the first real user message.
- Repo column and filter: allowed as an app-level convenience using `SessionMeta.cwd`, but not part of Codex’s picker semantics.
- Pagination: optional “Load more” in the UI; cursor-based paging is compatible.
- Resume in Codex: provide an action that launches Codex with the override, e.g.:
  - Primary flow: `codex resume <session-id>` (requires CLI ≥0.39).
  - Fallback for older sessions or CLI failures: `codex -c experimental_resume=/absolute/path/to/rollout-2025-09-12T16-41-03-<uuid>.jsonl`.
  - Agent Sessions first issues the `resume <id>` command and, if it exits non-zero, retries automatically with the experimental override.

## Notes
- Behavior documented here reflects 0.34; future releases may change flags, help text, or pagination details.
