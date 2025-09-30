# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.2] - 2025-09-29

### Added
- Resume workflow to launch Codex CLI on any saved session, with quick Terminal launch, working-directory reveal shortcuts, configurable launch mode, and embedded output console.
- Transcript builder (plain/ANSI/attributed) and plain transcript view with in-view find, copy, and raw/pretty sheet.
- Menu bar usage display with configurable styles (bars/numbers), scopes (5h/weekly/both), and color thresholds.
- "ID <first6>" button in Transcript toolbar that copies the full Codex session UUID with confirmation.
- Metadata-first indexing for large sessions (>20MB) - scans head/tail slices for timestamps/model, estimates event count, avoids full read during indexing.

### Changed
- Simplified toolbar - removed model picker, date range, and kind toggles; moved kind filtering to Preferences. Default hides sessions with zero messages (configurable in Preferences).
- Moved resume console into Preferences → "Codex CLI Resume", removing toolbar button and trimming layout to options panel.
- Switched to log-tail probe for usage tracking (token_count from rollout-*.jsonl); removed REPL status polling.
- Search now explicit, on-demand (Return or click) and restricted to rendered transcript text (not raw JSON) to reduce false positives.

### Improved
- Performance optimization for large session loading and transcript switching.
- Parsing of timestamps, tool I/O, and streaming chunks; search filters (kinds) and toolbar wiring.
- Session parsing with inline base64 image payload sanitization to avoid huge allocations and stalls.

### Fixed
- Removed app sandbox that was preventing file access; documented benign ViewBridge/Metal debug messages.

### Documentation
- Added codebase review document (`docs/codebase-0.1-review.md`).
- Added session storage format doc (`docs/session-storage-format.md`) and JSON Schema for `SessionEvent`.
- Documented Codex CLI `--resume` behavior in `docs/codex-resume.md`.
- Added `docs/session-images-v2.md` covering image storage patterns and V2 plan.

### UI
- Removed custom sidebar toggle to avoid duplicate icon; added clickable magnifying-glass actions for Search/Find.
- Gear button opens Settings via reliable Preferences window controller.
- Menu bar preferences with configurable display options and thresholds.
