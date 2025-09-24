# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]
- Added: Resume workflow to launch Codex CLI on any saved session, with quick Terminal launch, working-directory reveal shortcuts, configurable launch mode, and embedded output console.
- Added: Transcript builder (plain/ANSI/attributed) and plain transcript view with in‑view find, copy, and raw/pretty sheet.
 - Changed: Simplified toolbar — removed model picker, date range, and kind toggles; moved kind filtering to Preferences. Default hides sessions with zero messages (configurable in Preferences).
- Improved: Parsing of timestamps, tool I/O, and streaming chunks; search filters (kinds) and toolbar wiring.
- Docs: Added codebase review document in `docs/codebase-0.1-review.md` and updated to reflect simplified filters.
 - Docs: Added `docs/session-images-v2.md` covering image storage patterns and the V2 plan for image rendering.
 - UI: Removed custom sidebar toggle to avoid duplicate icon; added clickable magnifying‑glass actions for Search/Find; gear button opens Settings via a reliable Preferences window controller.
 - Docs/Data: Added session storage format doc (`docs/session-storage-format.md`) and introduced a minimal JSON Schema for normalized `SessionEvent` (`docs/schemas/session_event.schema.json`). See ADR 0001.
 - Docs: Documented Codex CLI `--resume` behavior and integration strategy in `docs/codex-resume.md`; cross‑linked from `docs/session-storage-format.md`.
 - Fixed: Removed app sandbox that was preventing file access; documented benign ViewBridge/Metal debug messages in `docs/viewbridge-errors.md`.
