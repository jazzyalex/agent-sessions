# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- **OpenCode Sessions**: Fixed missing conversation content in Plain/Color views for OpenCode storage schema `migration=2` by extracting message text from `storage/part/msg_<message-id>/prt_*.json` text parts (not just `summary.title/body`), so both user prompts and assistant responses render correctly.
- **Analytics (Codex)**: Count `web_search_call` and `custom_tool_call` (and their `*_output`) events as commands, improving tool-call totals and the “has commands” filter.
- **Gemini Sessions**: Added support for embedded `toolCalls` and `type=info` messages in newer Gemini CLI session JSON, improving transcript fidelity and preventing low-message filtering from being skewed by informational entries.
- **JSON View**: Prevent large tool outputs (e.g., recursive file listings) from truncating the entire JSON tab by replacing extremely large strings with compact previews.
- **Claude Sessions**: Split embedded `message.content` blocks (`thinking`, `tool_use`, `tool_result`) into separate events so transcripts remain accurate with modern Claude Code behavior.
- **Claude Sessions (Errors)**: Treat `tool_result` blocks marked `is_error=true` as errors only for runtime-ish failures (non-zero exit, generic `Error: ...`, and user-interrupted runs). User-rejected tool uses are suppressed by default, and “not found” failures remain tool output.
- **Claude Sessions (Errors)**: Prevent false-positive error highlighting when read-file tool output contains phrases like “exit code” alongside line numbers (common in Claude’s numbered file dumps).

## [2.8.1] - 2025-11-28

### Critical Fixes

- **Usage Tracking Refresh**: Hard probe actions (Codex strip/menu refresh) now route through hard `/status` probes, preventing older log snapshots from overwriting fresh limits. Stale checks honor hard-probe TTL for accurate freshness indicators.
- **OpenCode Sessions**: User messages now correctly extract from `summary.title` instead of `summary.body`, fixing incorrect assistant responses appearing in user messages for older OpenCode sessions. User messages are never dropped even if empty.

### Added

- **Per-CLI Toolbar Visibility**: New unified-pane toggles in Preferences → General to show/hide Codex, Claude, Gemini, and OpenCode session filters. CLIs automatically hide when unavailable.
- **Usage Display Mode**: New Preferences toggle to switch between "% left" and "% used" display modes across Codex and Claude usage strips and menu bar. Normalizes Claude CLI percent_left semantics for consistency.
- **Preferences → OpenCode**: New dedicated pane for OpenCode CLI configuration including Sessions Directory override to choose custom Claude sessions root (defaults to `~/.claude`).

### Improved

- **Gemini CLI Detection**: Enhanced Gemini binary detection via login-shell PATH fallback, matching other CLI probes. "Auto" detection now reliably finds the `gemini` binary (npm `@google/gemini-cli`).
- **Cleanup UX**: Claude auto-cleanup now shows non-intrusive flash notifications instead of modal dialogs for better user experience.


## [Unreleased]

## [2.8] - 2025-11-27

🦃 **My thanks to the OpenCode community - Agent Sessions now supports OpenCode!** (Resume and usage tracking are on the roadmap.)

### Added
- **OpenCode Support**: Full session browser integration with Claude Code OpenCode sessions, including transcript viewing, analytics, and favorites. Sessions appear in the unified list with source filtering.
- Preferences → Claude Code: Sessions Directory override to choose a custom Claude sessions root. The Claude indexer honors this path and refreshes automatically when changed. Defaults to `~/.claude` when unset.
- Preferences → Usage Probes: New dedicated pane consolidating Claude and Codex terminal probe settings (auto-probe, cleanup, and one‑click delete), with clear safety messaging.

### Changed
- Preferences → Usage Tracking: Simplified and HIG‑aligned. Added per‑agent master toggles (Enable Codex tracking, Enable Claude tracking) independent of strip/menu bar visibility. Moved all probe controls into the new Usage Probes pane. Reduced vertical scrolling and clarified refresh interval and strip options.
- Usage Tracking: Separate refresh intervals per agent. Codex offers 1/5/15 minutes (default 5m). Claude now offers 3/15/30 minutes (default 15m) and `/usage` probes no longer send user messages, so they don't consume tokens.
- Usage probes run directly on their configured cadence. The legacy `UsageProbeGate` visibility/budget guard has been removed so Claude and Codex refreshers no longer stall after 24 attempts.
- Website: Updated Open Graph and Twitter Card tags to use the `AS-social-media.png` preview so shared links render the large social image correctly.

### Fixed
- Usage Probes: Codex and Claude cleanup actions once again emit status notifications for disabled/unsafe exits and successfully delete Codex probe sessions that log their working directory inside nested payload data.
- Usage (Codex): Stale indicator now reflects the age of the last rate‑limit capture only. Recent UI refreshes or token‑only events no longer mask outdated reset times; the strip/menu will show "Stale data" until fresh `rate_limits` arrive.
- Claude Usage: Added a central probe gate that suppresses `/usage` probes when the menu bar limits are off and the main window isn't visible, or when the screen is inactive (sleep/screensaver/locked).
- Claude Usage Probes: Cleanup now verifies every session file's `cwd/project` matches the dedicated probe working directory, requires tiny (≤5 event) user/assistant-only transcripts, and aborts deletion when uncertain.

## [2.7.1] - 2025-11-26

### Critical Fixes

- **Codex Usage Tracking**: Added full support for new Codex usage backend format. The usage parser now handles both legacy local usage events and the new backend-based usage reporting system, ensuring accurate rate limit tracking across all Codex CLI versions. Automatic fallback to legacy format for older Codex versions.

### Technical

- **Usage Format Migration**: Enhanced `CodexUsageParser` with dual format support to seamlessly transition between Codex usage reporting systems without requiring user intervention or configuration changes.

## [2.7] - 2025-11-23

### Major Features

- **New Color View**: Terminal-inspired view with CLI-style colorized output, role-based filtering (User, Agent, Tools, Errors), and navigation shortcuts. Replaces the old "Terminal" mode with enhanced visual hierarchy and interactive filtering.
- **Enhanced Transcript Modes**: Renamed "Transcript" to "Plain" view for clarity. Added improved JSON viewer with syntax highlighting and better readability for session inspection.
- **View Mode Switching**: Quick toggle between Plain, Color, and JSON views with Cmd+Shift+T keyboard shortcut.

### Critical Fixes

- **Claude Usage Tracking**: Fixed compatibility with Claude Code's new usage format change ("% left" vs "% used"). The usage probe now supports both old and new formats with automatic percentage inversion, ensuring accurate limit tracking across all Claude CLI versions.
- **Script Consolidation**: Unified usage capture scripts via symlink to prevent future divergence. Single source of truth in `AgentSessions/Resources/`.

### Improvements

- **Color View Navigation**: Added role-specific navigation buttons with circular pill styling and tint-aware colors. Jump between user messages, tool calls, or errors with keyboard shortcuts.
- **NSTextView Renderer**: Implemented high-performance text rendering with native macOS text selection and smooth scrolling.
- **JSON View**: Redacted `encrypted_content` fields for cleaner inspection. Improved syntax coloring stability across mode toggles.
- **Debug Mode**: Added `CLAUDE_TUI_DEBUG` environment variable for troubleshooting usage capture issues with raw output dumps.

### Technical

- **Flexible Pattern Matching**: Usage probe now tries multiple patterns ("% left", "% used", "%left", "%used") with fallback to any "N%" format. Future-proofed against CLI format changes.
- **Enhanced Testing**: Comprehensive test suite for both old and new Claude usage formats with validation of percentage inversion logic.

## [2.6.1] - 2025-11-19

### Performance
- Dramatically improved loading and refresh times through optimized session indexing
- Eliminated UI blocking during session updates with background processing
- Reduced indexing contention to prevent launch churn
- Enhanced Analytics dashboard responsiveness for smoother interaction

## [2.5.4] - 2025-11-03

### Fixed
- Sessions: Manual refresh now scans filesystem for new session files even when loading from database cache. Previously, the refresh button would load cached sessions and skip filesystem scan, causing new VSCode Codex sessions to remain invisible until background indexer ran.
- UI: Progress indicator now remains visible throughout entire refresh operation, including transcript processing phase. Previously, the spinner would disappear prematurely while heavy transcript cache generation continued in background, leaving users with unresponsive UI and no feedback.

## [2.5.3] - 2025-11-03

### Fixed
- Release packaging: v2.5.2 tag pointed to wrong commit, missing project filter feature. This release includes all intended 2.5.2 changes.

## [2.5.2] - 2025-11-02

### Added
- Analytics: Project filter dropdown in Analytics window header to drill down into per-project metrics (sessions, messages, duration, time series, agent breakdown, heatmap). Works alongside existing date range and agent filters.

### Fixed
- Analytics: Session counts now match Sessions List by properly applying filter defaults (HideZeroMessageSessions and HideLowMessageSessions both default to true). Previously Analytics counted all sessions including noise (0-2 messages), inflating counts by up to 79%.
- Analytics: Simplified UserDefaults reading in AnalyticsRepository to use consistent pattern with AnalyticsService.
- Analytics: Project filter list now excludes projects with only empty/low-message sessions, matching Sessions List behavior.

## [2.5.1] - 2025-10-31

### Added
- Codex 0.51-0.53 compatibility: Full support for `turn.completed.usage` structure, `reasoning_output_tokens`, and absolute rate-limit reset times
- Usage tooltip: Token breakdown now displays "input (non-cached) + cached + output + reasoning" on hover
- Test fixtures for Codex format evolution (0.50 legacy through 0.53)

### Changed
- Rate limit parsing: Absolute `resets_at`/`reset_at` timestamps (epoch or ISO8601) now preferred over relative calculations
- Token tracking: Added `lastReasoningOutputTokens` field to usage snapshots for extended thinking models

### Fixed
- Backward compatibility: Gracefully handles `info: null` in `token_count` events from older Codex versions
- Parser resilience: Ignores unknown event types (e.g., `raw_item`) without crashing

## [2.5] - 2025-10-30

### Added
- Indexing: SQLite rollups index with per-session daily splits and incremental Refresh. Background indexing runs at utility priority and updates only changed session files.
- Git Inspector (feature-flagged): Adds "Show Git Context" to the Unified Sessions context menu for Codex sessions; opens a non-blocking inspector window with current and historical git context.
- Advanced Analytics: Visualize AI coding patterns with session trends, agent breakdown, time-of-day heatmap, and key metrics via Window → Analytics.

### Fixed
- Usage (Codex): Reset times no longer show "Stale data" when recent `token_count` events are present. Now anchors `resets_in_seconds` to `rate_limits.captured_at` and accepts absolute `resets_at`/`reset_at` fields (including `*_ms`), with flexible timestamp parsing for old/new JSON formats.
- Analytics/Git Inspector: System theme updates immediately; stable session IDs for Claude/Gemini; aligned window theme handling.
- Sessions/Messages totals: Respect HideZeroMessageSessions/HideLowMessageSessions preferences in dashboard cards.
- Avg Session Length: Exclude noise sessions when preferences hide zero/low message sessions.

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
