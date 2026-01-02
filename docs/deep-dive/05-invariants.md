# Invariants (Stage 0 guardrails)

This document lists the behaviors that must remain stable while refactoring architecture (indexing, search, caching, and UI orchestration).

If a change intentionally breaks an invariant, it must be treated as a product decision and accompanied by explicit migration/UX notes.

## Identity and stability

- A session’s identity must be stable across launches.
- When an authoritative in-file session ID exists (provider-specific), prefer it over filename-derived IDs.
- If an in-file ID is missing, fall back to a deterministic, filename-derived ID (not a random UUID).

## Lightweight session behavior

- Indexing should prefer a metadata-first (lightweight) parse for lists and initial load.
- Lightweight sessions must keep `events` empty until the user opens a transcript or an operation explicitly requests a full parse.
- Lightweight parsing may still compute summary fields (`eventCount`, time bounds, title/preview) without populating `events`.

## Sorting and filtering semantics

- Filtering must preserve the existing sort order of the source list (no implicit re-sorts inside the filter engine).
- Date-range filtering compares the “modified” reference time (end time if present, else start time).
- Query operators:
  - `repo:<value>` filters by `repoName` (case-insensitive substring).
  - `path:<value>` filters by `cwd` (case-insensitive substring).

## Search correctness and caching

- Search/list filtering should prefer prebuilt searchable text when available.
  - Today: transcript cache is a correctness aid (not a required dependency).
  - Future: SQLite FTS should be the default search path, with transcript generation only for display.
- If a transcript cache is used:
  - Cached transcript text is authoritative for “contains” matching.
  - If a transcript is missing and generation is allowed, generation may occur on-demand for correctness.
  - If generation is disallowed, filtering falls back to raw metadata/event fields (best-effort).

## Performance guardrails (observable outcomes)

- App launch should not require fully parsing every session file by default.
- Search should not require building full transcripts for all sessions as its primary mechanism.
- Background work must be cancelable/cooperative (typing/search activity should reduce contention).

