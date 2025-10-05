# Changelog

All notable changes to Agent Sessions will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2025-10-04

### Major Release - Unified Interface & Claude Code Support

Agent Sessions 2.0 is a **complete rewrite** with a unified interface for managing both Codex CLI and Claude Code sessions. This release includes advanced search capabilities, dual usage tracking, and significant performance improvements for large sessions.

### Added

- **Unified window** for Codex + Claude with source toggle (Both / Codex / Claude)
- **Claude Code support**: Full parsing, transcript rendering, unique usage tracking (5h/weekly), and Resume for Claude sessions (Terminal/iTerm, configurable in Preferences)
- **Inline toolbar Search**: Magnifying-glass button expands to search field; Option+Command+F opens and focuses instantly
- **Search progress strip** under sessions table showing phase and counters during two-phase pipeline
- **Context menu action**: "Open Session in Folder" for quick file reveal (works even when Finder hides system files)

### Changed

- **Search v2**: Cancellable, incremental, two-phase pipeline (small files first; large deferred), no preview text, strict source toggle enforcement
- **Default display** for not-yet-loaded sessions shows file size in Msgs column (instead of "Many")
- **Exclude filters** in Preferences now apply instantly (no app reload); "Skip agents.md lines" enabled by default for titles/initial view
- **Titles and transcript start** skip common preambles (agents.md and Claude "Caveat..." blocks); auto-scroll jumps to first conversational line

### Improved

- **Large session performance**: Lazy hydration, off-main parsing, defer-until-needed loading for ≥10 MB logs
- **Unified search UX**: Batch streaming of results, keystrokes cancel immediately, promote-on-open prioritizes clicked large session
- **Focus and keyboard flow**: Inline search auto-focuses on open, collapses when empty on click/tab away; no unexpected focus steals from list
- **Visual polish**: Tighter spacing, aligned usage strips and progress meters

### Fixed

- Prevented Find field from stealing focus when navigating list
- More reliable selection behavior during initial load and when switching rows
- Finder reveal now works for hidden session files

### Documentation

- Updated v2 notes and UI tooltips across Sessions, Transcript, and Preferences
- Clarified behaviors including Transcript vs Terminal and all Find controls

### UI

- Inline search with clear button that cancels search and collapses back to magnifying-glass
- Compact progress line communicates "Scanning small/large … x/y" during searches

---

## [1.2.2] - 2025-09-30

### Fixed
- App icon sizing in Dock/menu bar - added proper padding to match macOS standard icon conventions

## [1.2.1] - 2025-09-30

### Changed
- Updated app icon to blue background design for better visibility and brand consistency

## [1.2.0] - 2025-09-29

### Added
- Resume workflow to launch Codex CLI on saved sessions
- Transcript builder with plain/ANSI/attributed support
- Menu bar usage display with configurable styles
- "ID <first6>" button in Transcript toolbar for quick UUID copying
- Metadata-first indexing for large sessions (>20MB)

### Changed
- Simplified toolbar - removed model picker, date range, kind toggles
- Moved resume console into Preferences
- Switched to log-tail probe for usage tracking
- Search now explicit and on-demand

### Improved
- Performance optimization for large session loading
- Parsing of timestamps, tool I/O, streaming chunks
- Session parsing with inline base64 image sanitization

### Fixed
- Removed app sandbox preventing file access

[2.0.0]: https://github.com/jazzyalex/agent-sessions/compare/v1.2.2...v2.0.0
[1.2.2]: https://github.com/jazzyalex/agent-sessions/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/jazzyalex/agent-sessions/compare/v1.2...v1.2.1
[1.2.0]: https://github.com/jazzyalex/agent-sessions/releases/tag/v1.2
