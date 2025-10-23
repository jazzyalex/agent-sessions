# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Indexing: SQLite rollups index with per-session daily splits and incremental Refresh. Background indexing runs at utility priority and updates only changed session files. (No UI changes yet.)

## [2.4] - 2025-10-15

### Added
- Automatic updates via Sparkle 2 framework with EdDSA signature verification
- "Check for Updates..." button in Preferences > About pane
- Star column toggle in Preferences to show/hide favorites column and filter button

### Changed
- App icon in About pane reduced to 85x85 for better visual balance

## [2.3.2] - 2025-10-15

### Performance
- Interactive filtering now uses cached transcripts only; falls back to raw session fields without generating new transcripts.
- Demoted heavy background work (filtering, indexing, parsing, search orchestration) to `.utility` priority for better cooperativeness.
- Throttled indexing and search progress updates (~10 Hz) and batched large search results to reduce main-thread churn.
- Gated transcript pre-warm during typing bursts, increased interactive filter debounce, and debounced deep search starts when typing rapidly.
- Built large transcripts off the main thread when not cached, applying results on the main thread to avoid beachballs.

### Documentation
- Added `docs/Energy-and-Performance.md` summarizing performance improvements, current energy behavior, and future options.

## [2.3.1] - 2025-10-14

### Fixed
- Search: auto-select first result in Sessions list when none selected; transcript shows immediately without stealing focus.

## [2.3] - 2025-10-14

### Added
- Gemini CLI (read-only, ephemeral) provider:
  - Discovers `~/.gemini/tmp/**/session-*.json` (and common variants)
  - Lists/opens transcripts in the existing viewer (no writes, no resume)
  - Source toggle + unified search (alongside Codex/Claude)
- Favorites (★): inline star per row, context menu Add/Remove, and toolbar “Favorites” filter (AND with search). Persisted via UserDefaults; no schema changes.

### Changed
- Transcript vs Terminal parity across providers; consistent colorization and plain modes
- Persistent window/split positions; improved toolbar spacing

### Fixed
- “Refresh preview” affordance for stale Gemini files; safer staleness detection
- Minor layout/content polish on website (Product Hunt badge alignment)

## [2.2.1] - 2025-10-09

### Changed
- Replace menubar icons with text symbols (CX/CL) for better clarity
- CX for Codex CLI, CL for Claude Code (SF Pro Text Semibold 11pt, -2% tracking)
- Always show prefixes for all source modes
- Revert to monospaced font for metrics (12pt regular)

### Added
- "Resume in [CLI name]" as first menu item in all session context menus
- Dynamic context menu labels based on session source (Codex CLI or Claude Code)
- Dividers after Resume option for better visual separation

### Fixed
- Update loading animation with full product names (Codex CLI, Claude Code, Agent Sessions)

### Removed
- Legacy Window menu items: "Codex Only (Unified)" and "Claude Only (Unified)"
- Unused focusUnified() helper and UnifiedPreset enum

## [2.2] - 2025-10-08

### Performance & Energy
- Background sorting with sortDescriptor in Combine pipeline to prevent main thread blocking
- Debounced filter/sort operations (150ms) with background processing
- Configurable usage polling intervals (1/2/3/10 minutes, default 2 minutes)
- Reduced polling when strips/menu bar hidden (1 hour interval vs 5 minutes)
- Energy-aware refresh with longer intervals on battery power

### Fixed
- CLI Agent column sorting now works correctly (using sourceKey keypath)
- Session column sorting verified and working

### UI/UX
- Unified Codex CLI and Claude Code binary settings UI styling
- Consolidated duplicate Codex CLI preferences sections
- Made Custom binary picker button functional
- Moved Codex CLI version info to appropriate preference tab

### Documentation
- Refined messaging in README with clearer value propositions
- Added OpenGraph and Twitter Card meta tags for better social sharing
- Improved feature descriptions and website clarity

## [2.1] - 2025-10-07

### Added
- Loading animation for app launch and session refresh with smooth fade-in transitions
- Comprehensive keyboard shortcuts with persistent toggle state across app restarts
- Apple Notes-style Find feature with dimming effect for focused search results
- Background transcript indexing for accurate search without false positives
- Window-level focus coordinator for improved dark mode and search field management
- Clear button for transcript Find field in both Codex and Claude views
- Cmd+F keyboard shortcut to focus Find field in transcript view
- TranscriptCache service to persist parsed sessions and improve search accuracy

### Changed
- Unified Codex and Claude transcript views for consistent UX
- HIG-compliant toolbar layout with improved messaging and visual consistency
- Enhanced search to use transcript cache instead of raw JSON, eliminating false positives
- Mutually exclusive search focus behavior matching Apple Notes experience
- Applied filters and sorting to search results for better organization

### Fixed
- Search false positives by using cached transcripts instead of binary JSON data
- Message count reversion bug by persisting parsed sessions
- Focus stealing issue in Codex sessions by removing legacy publisher
- Find highlights not rendering in large sessions by using persistent textStorage attributes
- Blue highlighting in Find by eliminating unwanted textView.textColor override
- Terminal mode colorization by removing conflicting textView.textColor settings
- Codex usage tracking to parse timestamp field from token_count events
- Stale usage data by rejecting events without timestamps
- Usage display to show "Outdated" message in reset time position
- Version parsing to support 2-part version numbers (e.g., "2.0")
- Search field focus issues in unified sessions view with AppKit NSTextField
- Swift 6 concurrency warnings in SearchCoordinator

### Documentation
- Added comprehensive v2.1 QA testing plan with 200+ test cases
- Created focus architecture documentation explaining focus coordination system
- Created search architecture documentation covering two-phase indexing
- Added focus bug troubleshooting guide

## [2.0] - 2025-10-04

### Added
- Full Claude Code support with parsing, transcript rendering, and resume functionality
- Unified session browser combining Codex CLI and Claude Code sessions
- Two-phase incremental search with progress tracking and instant cancellation
- Separate 5-hour and weekly usage tracking for both Codex and Claude
- Menu bar widget with real-time usage display and color-coded thresholds
- Source filtering to toggle between Codex, Claude, or unified view
- Smart search v2 with cancellable pipeline (small files first, large deferred)
- Dual source icons (ChatGPT/Claude) in session list for visual identification

### Changed
- Migrated from Codex-only to unified dual-source architecture
- Enhanced session metadata extraction for both Codex and Claude formats
- Improved performance with lazy hydration for sessions ≥10 MB
- Updated UI to support filtering by session source

### Fixed
- Large session handling with off-main parsing to prevent UI freezes
- Fast indexing for 1000+ sessions with metadata-first scanning

## [1.2.2] - 2025-09-30

### Fixed
- App icon sizing in Dock/menu bar - added proper padding to match macOS standard icon conventions.

## [1.2.1] - 2025-09-30

### Changed
- Updated app icon to blue background design for better visibility and brand consistency.

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
