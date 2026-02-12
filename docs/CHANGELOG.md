# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- Search fields (Unified global search + transcript Find): `Esc` now clears the active field directly when that field has focus, eliminating the system beep and making clear behavior consistent from the keyboard.
- Transcript Find (`Esc`): pressing `Esc` with an empty Find field now closes the Find bar again (`Close Find (⎋)`), restoring keyboard-only close behavior.
- Session view (Unified): table selection synchronization now keeps programmatic updates out of manual-selection handling, preventing auto-selection from being disabled by internal selection coalescing.
- Session view (Unified): Removed the transient "Selected session is hidden by the current search/filter" notice and its `Show in List` / `Keep Hidden` actions.
- Session view (Unified): Transcript tail-append now verifies the previous tail event content (not only ID), forcing a full rebuild when a live update rewrites the prior tail event in place.
- Session view (Unified): Transcript view now rebuilds on `eventCount`, `fileSize`, and `endTime` metadata updates for loaded sessions, so in-place live parsing changes without `events.count` growth no longer leave stale text.
- Session view (Unified): Transcript tail-append now writes appended output to the in-view build-key cache, preventing stale transcript regressions when switching modes during live updates.
- Session view (Unified): Active transcript tail-append updates now keep readiness state in sync with the current build key, so Unified Search auto-jump still triggers after append-only live updates.
- Session view (Unified): Transcript tail-append now requires render-option parity with the previously rendered buffer, so toggles like `Skip preamble` force a full rebuild instead of appending into stale formatting.
- Session view (Unified): User-triggered manual refreshes now always show loading feedback for the selected session, even when transcript text is already visible.
- Session view (Unified): Loading animation now stays visible when the selected session is still loading but the on-screen transcript buffer belongs to a different session, preventing stale-content flashes without feedback.
- Session view (Unified): Async transcript/JSON renders now persist the originating view mode in render state, preventing transcript-tail append from attaching to buffers built for another mode after mode switches.
- Sessions (Codex/Session view): Active-session transcript updates now append tail content in Session view instead of replacing the full rendered buffer on each monitor refresh, eliminating periodic flicker and preserving in-session reading/navigation context.
- Sessions (Codex): Focused monitor/background refresh reloads no longer surface loading overlays when transcript content is already visible, avoiding repeated loading flashes during near-live tail updates.
- Session view (Unified): Live transcript rendering now applies strict latest-generation gating across async rebuild paths, and Session mode now performs deterministic tail patching/signature checks to reduce stale or flickering text during rapid updates.
- Session view (Unified/Session mode): Terminal find/unified-find auto-scroll now runs only for explicit navigation requests (token-driven) so passive live refreshes no longer yank scroll position; canceled JSON rebuild tasks now reliably clear loading state for the active generation.
- Session view (Unified): Selected transcript content now keeps the last resolved session buffer during transient reindex gaps, and list-side programmatic selection updates are coalesced to avoid table reentrant delegate churn that could leave the transcript pane blank until reselection.
- Session view (Unified): Table-driven transient empty-selection events (during indexing/list churn) now preserve the active session selection instead of treating them as user deselects, and transcript host source/type now stays pinned to the last resolved selected session to prevent blank placeholder fallbacks.
- Stability: Hardened Claude indexing refresh state synchronization (refresh token, file-stat cache, prewarm signatures) and made progress throttling thread-safe to reduce intermittent `EXC_BAD_ACCESS` crashes during concurrent indexing tasks.
- Usage tracking/menu bar: Codex and Claude polling now continues when usage is visible (including active in-app strip visibility), while inactive/background polling remains tied to that specific agent being shown in the menu bar; Codex menu-background polling also now re-seeds to newer JSONL session files instead of stalling on an older file.
- Sessions (Codex): Active selected sessions now refresh tails faster (focused-file monitoring with adaptive 5s/15s cadence), and `Refresh Sessions` now forces a full reload of the selected Codex transcript so newest prompts/outputs appear without reselection.
- Sessions (Codex): Fixed a forced-reload dedupe race for active-session monitoring so follow-up tail reloads are not skipped when JSONL files change during parsing.
- Startup stability: Hardened launch-time observer/task lifecycle for analytics/onboarding and made updater-controller startup ownership explicit to reduce intermittent launch EXC_BAD_ACCESS crashes.
- Analytics: Kept the analytics-toggle observer active across main-window close/reopen so menu/shortcut toggles continue working for the full app session.
- Sessions (Unified): Closing one window no longer clears shared app-active/focused-session state for other open windows, and closing the last Agent Sessions window now clears shared focus/activity state so background monitor loops stop until a main window reopens; manual Codex refresh intent now survives coalesced refresh execution so selected-session force reload stays consistent.
- Sessions (Unified): Focused-session monitoring now tracks the key window per instance, preventing window-close races from leaving a stale focused session when another main window remains open.
- Crash reporting reliability: Launch recovery now keeps pending crash reports when email/export is canceled or fails, and launch deduplication now tracks all previously handled crash IDs to prevent repeat prompts for old reports.
- Crash reporting reliability: Launch crash scan now checks the full lookback window (not just an early truncated candidate slice), and seen crash-ID history now evicts by recency so recently handled crashes are not re-prompted after history capping.
- Crash reporting reliability: Launch recovery now uses a single queued crash-report model (newest-first), so successful sharing clears only that one pending report and cannot silently drop additional queued items.
- Crash reporting reliability: Crash IDs are now marked seen only when the pending report is actually handled/cleared, and queued report metadata now preserves app version/build from the crash file (not the currently running app).
- Crash reporting reliability: Clearing pending reports now marks every cleared crash ID as seen (not just the latest), preventing re-prompts from legacy or multi-entry pending stores.
- Crash reporting reliability: Seen-ID persistence now happens only after pending clear succeeds; failed/partial clear attempts no longer suppress future crash prompts.

### Changed
- Preferences/About: Added a new Diagnostics section for crash reporting with local pending queue controls (`Email Crash Report`, `Export Report`, `Clear Pending`) and a direct support email link.
- Crash reporting: Crash diagnostics are queued locally on launch and shared only through an explicit pre-filled email draft action; no automatic startup/background upload occurs.
- Crash reporting UX: Crash capture is always on (toggle removed), and when a new crash report is detected at launch the app now prompts to either `Email Crash Report` or `Export + Open GitHub Issue`.

## [2.11.2] - 2026-02-09

### Fixed
- Startup stability: Prevented a launch-time crash by removing early `NSApp.isActive` reads during Codex/Claude usage model singleton initialization and syncing app-active state after UI startup.

### Changed
- Preferences/Updates: Added an `Auto-Update` checkbox in Settings → About (next to `Check for Updates...`) and enabled Sparkle auto-update by default for new installs while keeping user opt-out.

## [2.11.1] - 2026-02-08

### Fixed
- Session view UI polish: Real user prompts now use the same narrative font as other blocks, remove side accent strips, keep inverted contrast in dark mode, and use a dark gray (`white: 0.20`) bubble with white text in light mode.
- Session view UI polish: Removed the synthetic “Conversation starts here” divider line, and the Images toolbar pill now shows icon + count while remaining visible/disabled until images are detected.
- CPU spikes optimization: Global Search now stays on fast indexed results while typing (Return still triggers deep scan), reducing long CPU bursts during active search.

### Performance
- Sessions/Search: Gemini, Copilot, Droid, and OpenClaw indexing now use the same power-aware idle execution profiles as Codex/Claude (lower-priority slices and deferred non-critical work on battery/background).
- Sessions/Search: Global Search no longer generates transcripts on-demand during scans; it searches cached transcripts when available and otherwise falls back to raw event fields to avoid multi-minute CPU bursts.
- Sessions/Indexing: Codex and Claude transcript prewarm runs now cancel previous runs and cap per-refresh work to reduce sustained post-refresh energy spikes.
- Sessions/Indexing: Non-manual refresh work is deferred while the app is inactive and replays on foreground activation to avoid background energy warnings.
- Codex Usage: Automatic tmux `/status` fallback probes now run with stricter stale/no-recent gates, longer cooldown, and lighter file-tail scans to reduce background energy spikes.

### Changed
- Onboarding: Added a visible “Help improve Agent Sessions” feedback card on the first slide (below session/agent counters) that links to the short feedback form and clarifies that Agent Sessions is local-only with no telemetry.
- Onboarding: Fixed overlap in the “Sessions by Agent” weekly chart, split usage limit tracking into separate Claude/Codex cards, and removed onboarding slide scrolling by fitting all slides within the onboarding window.
- Preferences: Added an OpenClaw pane after the other agent panes with Binary Source and Sessions Directory controls, matching the other CLI agent preference sections.
- Preferences: Added a sidebar divider between Droid and OpenClaw, and added per-agent `Update...` actions that detect install manager, check latest versions, and run updates with confirmation.
- Preferences: Improved per-agent `Update...` detection to resolve package-manager binaries from common PATH locations and infer npm package names from the installed binary path (fixes false "manager not detected" and OpenClaw package-name mismatches).

## [2.11] - 2026-02-06

### Major Updates

- OpenClaw sessions: Added OpenClaw (clawdbot) session support, including Advanced visibility for deleted transcripts.
- Images: Expanded image workflows across both Session view (inline thumbnails) and Image Browser (cross-agent browsing, filters, and actions).

### Major Bug Fixes

- Search completeness: Reduced missing/incomplete search results for some sessions with incremental changed-file indexing, search backfill paths, and stale-row cleanup.
- Energy spikes: Reduced Energy Warning spikes by replacing always-on idle refresh with app-activation/event-driven behavior and power-aware probing/indexing cadence.

### Fixed

- Performance: Removed high-frequency idle background work (Codex warmup loop and archive sync timer) and switched to activation/event-driven refreshes to reduce steady-state battery impact.
- Session view: Removed a QoS inversion path in terminal view cleanup by avoiding lower-priority observer teardown work from interactive code paths.
- Transcript (Session view): Treat `<turn_aborted>` blocks embedded in user prompts as system notices so they don’t render as user prompts.
- Transcript (Session view): Render Codex `<image name=[Image #…]>` markers as `[Image #…]` for cleaner copy/paste.
- Transcript (Session view): Inline image thumbnails ignore data URL strings that are not part of `image_url` payloads, preventing empty placeholders.
- Transcript (Session view): Tool output blocks now use a monospaced font to preserve formatting.
- Session view: Inline image thumbnails now open the Image Browser on single click and include an “Open in Image Browser” context menu action.
- Session view: Shift-clicking an inline image no longer opens the Image Browser, preserving selection behavior.
- Session view: Inline image thumbnail clicks are more reliable immediately after scrolling or transcript updates.
- Sessions: Preserve OpenClaw project metadata after opening a session so the Project column stays consistent.
- Windows: Image Browser and auxiliary windows now follow system light/dark changes immediately when using System appearance, and update instantly when switching Light/Dark in Settings or the View menu.
- Image Browser: Bottom status bar no longer shows “Scanning …” after scanning completes.
- Image Browser: Project scan progress no longer reports “224/224” while the final session is still scanning.
- Image Browser: Project scope now always includes the selected session to avoid missing images when project grouping is incomplete.
- Image Browser: OpenClaw sessions with inline images no longer show “No images” due to a stale cached index.
- OpenClaw: Session view hides the verbose “[media attached: …]” hint text when an inline image payload is present.
- OpenClaw: Tool outputs from `exec` are formatted like other shell outputs and include exit codes when available.
- OpenClaw: Tool outputs that return `{text,type}` block arrays now render as plain text (preserving newlines) instead of showing the wrapper.

### Changed

- Sessions: Added an app-active foreground monitor (60s cadence) for Codex and Claude new-session detection, replacing always-on idle polling.
- Claude Usage: Automatic background `/usage` probes now run only on AC power; on battery and Low Power Mode, refresh is manual-only.
- Codex Usage: Preserved periodic updates while reducing per-tick filesystem/parsing work when source files are unchanged.
- Sessions/Search: Codex and Claude refresh now use incremental changed-file indexing with batched slices, limited worker concurrency, and deferred non-critical work in inactive/battery modes to reduce burst energy spikes.
- Menu: Removed the separator between Image Browser and Saved Sessions, and renamed “Saved Sessions…” to “Saved Sessions”.
- Preferences: Added a Session View toggle for “Show inline image thumbnails in Session view”.
- Sessions: Added OpenClaw (clawdbot) session support when the OpenClaw/clawdbot CLI is installed; deleted sessions can be shown via an Advanced toggle.
- Session view: Inline image thumbnails now support hover popover previews and click open in the Image Browser (auto-selecting the clicked image); the inline thumbnail context menu includes Open in Preview and omits Navigate to Session.
- Session view: Added an Images toolbar pill to toggle inline images and jump between prompts that contain images.
- Session view: Inline image thumbnails now support Claude Code sessions.
- Session view: Inline image thumbnails now support OpenCode sessions.
- Session view: Inline image thumbnails now support Gemini and Copilot sessions.
- Image Browser: Double-click opens the selected image in Preview; Space opens Quick Look.
- Image Browser: Now supports Claude Code sessions.
- Image Browser: Now supports OpenCode sessions.
- Image Browser: Now supports Gemini and Copilot sessions.
- Image Browser: OpenClaw images appear only when OpenClaw is explicitly selected; “All Agents” is now “All Coding Agents”.
- Image Browser: Added Project and Agent filters, a larger preview pane, and user prompt context for each image when available.
- Image Browser: Thumbnail right-click menu and preview Actions menu now include Open in Preview, Copy Image, Copy Image Path, Save to Downloads, and Save….
- Image Browser: Caches image indexes and thumbnails for faster open and to avoid reprocessing previously seen sessions.
- Image Browser: Prompt context is loaded from already-parsed sessions only (no file scanning) to keep browsing fast.
- Session view: Inline image thumbnails now support OpenClaw sessions.

- Transcript (Session view): User prompt text now uses semibold weight.
- Images: Codex sessions with embedded base64 images now show an Image Browser in the main toolbar that opens a thumbnail gallery with preview, save actions, and optional project-wide scope.
- Images: Navigating to a session from the image browser now focuses the main window and jumps to the related user prompt.
- Images: Navigating to a session now brings the main window forward, highlights the image prompt, and restores Tab focus cycling.
- Images: The Image Browser moved to the main toolbar and View menu, and image thumbnails now support Copy Image from the context menu.
- Images: Opening the Image Browser for a session with no images now shows an empty-state message in the browser instead of blocking the window.
- Images: Image thumbnails now include a separate “Copy Image Path” action for terminal/CLI pasting.

## [2.10.2] - 2026-01-24

### Fixed

- OpenCode: Auto-detection now works for npm-installed CLIs and checks common pip/pipx install locations on macOS (including `~/Library/Python/*/bin`).
- Filters: “Hide 1–2 message sessions” no longer hides 0-message sessions when “Hide 0-message sessions” is off.
- Onboarding: “Sessions Found” counts now reflect current filter settings; filter labels are now consistently “Hide …”.
- Claude probes: Auto-delete now removes failed/empty probe sessions, not just successful ones.
- Claude probes: Cleanup now requires validated probe evidence (marker or content) before deleting a project, and cleanup messaging is clearer about protecting normal sessions.
- Usage Tracking: Disabling Codex/Claude tracking now also disables their probes/refresh actions and hides them from the menu bar.

### Changed

- Transcript: Tool calls and outputs now render as readable text blocks (commands, paths, stdout, stderr) instead of JSON wrappers.
- Transcript: Tool call/output navigation now groups paired blocks, tool outputs no longer repeat the tool label, and tool/error blocks have consistent padding.
- Layout: New installs default to the vertical split layout.
- Onboarding: The tour now opens in a standard window with a close button.
- Transcript (Session view): User prompts no longer use semibold text; emphasis comes from the accent strip.
- Transcript (Session view): Accent strips now align to their block padding.
- Transcript (Session view): Block accents no longer bleed into inter-block spacing.
- Transcript (Session view): Accent strips now sit outside text bounds.
- Transcript (Session view): User prompts use the base system font size with matching left/right accent strips; the system preamble keeps a single left strip.
- Transcript (Session view): Reduced the user prompt Optima font size bump from +2pt to +1pt.
- Preferences (Usage Probes): Moved “Show system probe sessions for debugging” to the bottom of the pane.
- Onboarding: Onboarding counts now use the system font.


## [2.10.1] - 2026-01-19

### Fixed

- Onboarding: Prevent a crash that could occur for some users.

## [2.10] - 2026-01-16

### TL;DR

- Apple Notes-style Unified Search across all sessions and inside a session, compatible with filters.
- SQLite-backed search plus richer instant indexing for faster results and better recall.
- Incremental analytics refresh and faster startup with immediate hydrated lists.
- Session view (formerly Color view) is now a colored timeline with improved formatting.
- Unified Search navigation and local Find are more consistent and responsive.
- Cockpit-style status UI and refreshed session list typography with live counts.
- Onboarding tour refreshed and always shows supported agents.

### Major Changes

- Search: Unified Search is now Apple Notes-style: fast across all sessions, within a specific session, and compatible with all filters.
- Search: Use SQLite full-text indexing to speed up global search after analytics indexing completes.
- Search: Instant search now indexes full tool inputs and outputs for recent sessions (last 90 days), reducing the need to wait for background scanning.
- Search: Tool output indexing now redacts embedded base64/data URL blobs to keep search responsive and the index compact.
- Search: Instant search now uses token-prefix matching by default (for example, `magic` behaves like `magic*`) to improve identifier and structured-text recall without trigram/substr indexing.
- Search: Background scanning of large tool outputs is now opt-in by default, keeping Instant search more responsive (Settings → Advanced).
- Search: Instant indexing now samples long assistant messages and tool inputs (head + middle + tail) to reduce false negatives without indexing the full transcript.
- Search: Instant indexing now captures more of long tool outputs (head + middle + tail slices) and keeps active Codex sessions searchable while they are updating.
- Search: Multi-word Unified Search queries now behave like phrase searches (for example, `exit code`) to match transcript navigation and avoid accidental boolean parsing.
- Search: Unified Search highlights now use token-phrase matching across punctuation/newlines, and Session view reports visible vs total match counts when role filters are active.
- Search: Global search now accepts quoted `repo:` and `path:` filters, and background deep scans run at low priority with on-demand prewarming for opened sessions.
- Search: The Search Sessions menu item and ⌥⌘F shortcut now reliably focus the global search field.
- Search: Unified Search highlights matches in the selected transcript and jumps to the first match when switching sessions.
- Indexing: Analytics refresh is now incremental (skips unchanged files and removes deleted ones) to reduce startup work and keep search data current.
- Startup: When Codex sessions are already indexed, the app now shows the hydrated list immediately while scanning for newly created sessions in the background.
- Transcript: Replace the read-only search box with a Unified Search navigation pill that appears only when Unified Search has a free-text query.
- Transcript: Find in Transcript (⌘F) now opens a local find bar with its own query and navigation.
- Transcript: Unified Search now auto-jumps to the first match after typing or switching sessions, and local Find uses a solid blue current-match marker aligned with the match.
- Transcript: Session view now auto-scrolls to the last user prompt by default, with a Unified Window setting to choose first vs last user prompt.
- Transcript: Color view is now called Session view and presents a colored timeline with improved formatting.
- Transcript (Session view): Use system font for narrative blocks; keep tool call blocks monospaced.
- Transcript (Session view): Blocks now render as rounded cards with subtle tints and left accent borders.
- Transcript (Session view): User prompts now use a thicker accent rail, slightly brighter tint, and semibold first-line text for readability.
- Transcript (Session view): Assistant blocks now use per-agent brand tints and the role legend matches transcript accents.
- Transcript (Session view): Find highlights now mark matched substrings and add a line indicator for easier scanning.
- UI: Consolidate unified-window status indicators into a single cockpit-style footer.
- UI: In dark mode, the cockpit footer now uses a transparent HUD style with crisp borders instead of a solid fill.
- UI: Menu bar usage now uses the same monospace, logo-forward cockpit styling as the footer.
- UI: Persist split-view divider positions per layout mode (horizontal vs vertical) so switching layouts doesn’t reset pane sizes.
- UI: Session list typography now uses monospaced text with softer timestamp gray, taller rows, lighter message counts, and footer-blue selection accents.
- UI: Increase session list row height to 48px for easier scanning.
- UI: Codex now uses a blue brand accent distinct from the cockpit footer tint; the transcript toolbar spacing is tighter, and the terminal view adds a subtle top border.
- Onboarding: Replaced the onboarding flow with a four-slide tour covering sessions, agent enablement, workflow tips, and usage tracking.
- Onboarding: Show all supported agents and discovered sessions in the tour regardless of Sessions toolbar filters; disabled agents appear as inactive.

### Minor Changes

- Onboarding: Refine tour icon and primary button colors to better match native macOS accents.
- Sessions: Hide housekeeping-only sessions (no assistant output and no real prompt content) by default; use “Show housekeeping-only sessions” in Settings → General to reveal them.
- Sessions: Show a live session count in the unified list that updates while indexing and when filters/search change.
- Preferences: The Menu Bar pane now groups label options into sections and aligns toggles consistently.
- Transcript: Removed the duplicate Jump to First Prompt control from the transcript toolbar.
- Sessions list: The Size column can now be sorted.
- Search: Tooltips now include keyboard shortcuts for search fields and navigation arrows.
- Analytics: The By Agent card now auto-scales rows and falls back to an internal scroll when space is tight.
- Menu Bar: Reset menu items now include weekday; menu bar label can hide reset indicators per provider.
- Menu Bar: Removed pill backgrounds from the menu bar label for a cleaner, more native look.
- Usage: Time-only reset strings now roll forward to the next day to avoid showing stale "<1m" countdowns.
- Transcript: Toolbar controls now use monospaced typography to match the session list.
- Sessions list: Added a context menu action to copy the session ID to the clipboard.
- Sessions: Resume context menu actions now include the selected terminal app (for example, Terminal or iTerm2).

### Critical Fixes

- Search: Prevent missing results while the search index is still warming by falling back to legacy matching for unindexed sessions.
- Search: Backfill missing per-session search data during incremental refresh so sessions don’t remain “not yet indexed” indefinitely.
- Search: Claude sessions now keep transcript match highlights in sync with the active search query.
- Transcript: Remove the ghost control inside the Unified Search navigation pill.
- Transcript (Session view): Match counts now update when Unified Search is active.
- Transcript (Session view): Search markers now appear only on matching wrapped lines and replace the block accent for that line.
- Sessions: Auto-select the first session on launch so the transcript pane isn’t blank.
- Sessions: Stabilize message counts for large sessions while full parsing completes to reduce list row jumps.
- Copilot: Normalize tool output newlines when logs include escaped `\\n` sequences.
- Parsing: Preserve non-zero exit codes in Gemini/OpenCode tool outputs and classify them as errors for error navigation.
- Parsing: Droid stream-json now handles numeric timestamps, tool call IDs, and error flags in tool results.
- Parsing: Treat Claude Code `queue-operation` and `file-history-snapshot` events as metadata so new versions don’t pollute transcripts or inflate message counts.
- Parsing: Gemini sessions now account for `model`/`tokens`/`thoughts` fields in newer chat logs.
- Parsing: Treat Copilot `assistant.turn_start/end`, `tool.execution_start`, and `session.truncation` events as metadata so they don’t clutter transcripts.
- Transcript: Clearing Find now immediately clears match highlights.
- Transcript: Terminal view no longer leaves a stale find highlight when the Find query is empty.
- Transcript: Toolbar filters now use dot + count labels with compact navigation chevrons.
- Transcript (Session view): Render Codex review blocks as labeled Review meta entries instead of user prompts.
- Transcript (Session view): Split system reminder and local-command caveat blocks into meta lines so user prompts stay visible.
- Transcript (Session view): Treat Claude local-command tag-only blocks as Local Command meta lines.
- Transcript (Session view): Local Command meta blocks now render with a thin blue accent strip.
- Transcript (Session view): Request interrupted-by-user markers now use a thin blue strip and regular text.
- Parsing: Ignore empty JSONL lines during scanning for improved robustness.
- Parsing: Surface Codex thread rollback events with readable text in timelines.
- Claude: Avoid UI stalls when opening sessions with embedded base64 blobs (for example, Chrome MCP screenshots).
- Claude Usage: Detect the Claude Code first-run terms prompt and surface a “Setup required” state instead of timing out silently.
- Toolbar: Keep action icons visible and overflow actions accessible when a project filter is active.
- Toolbar: Refined agent tabs and icon groups, updated the layout/theme controls, and tightened toolbar button sizing and hover states.
- UI: Update Codex and Claude brand accents to blue and warm brown for clearer agent recognition.
- Transcript: Rename view mode buttons to Session/Text/JSON, align them with HIG-style leading padding, and space the session ID control.
- Menu Bar: When usage data is stale, reset indicators now show “n/a” instead of an incorrect countdown.
- Claude Usage: Refresh usage automatically after wake when the usage strip or menu bar label is visible.
- Menu Bar: Show an updating spinner next to reset indicators while probes run.
- Search: Unified Search now accepts quoted repo/path filters with spaces.
- Claude/Codex Usage: Add a conservative startup sweep for probe tmux servers and harden cleanup/timeouts to avoid orphaned CLI processes after stalled probes or restarts.

## [2.9.2] - 2026-01-01

### Improvements

- Dates: Normalize timestamps (usage reset times, session dates, analytics labels, and transcript timestamps) to follow system locale and 12/24-hour settings.
- Appearance: Add a toolbar toggle for Dark/Light mode and View menu actions for Toggle Dark/Light and Use System Appearance.
- Preferences: Add quick links to Security & Privacy and License in Settings → About.
- Preferences: Make the Settings → About updates section more compact.
- Preferences: Droid pane now includes binary detection and a version check, consistent with other agents.

## [2.9.1] - 2025-12-29

### Added

- **Droid Support**: Import Droid (Factory CLI) sessions (interactive store and stream-json logs) with a dedicated Preferences pane, toolbar filter, and Analytics support.

### Improvements

- **Color View**: Increased role contrast and added block spacing so user prompts stand out near tool calls.
- **Color View**: Removed bold styling for Codex/Droid preamble blocks so system prompts are visually distinct from real user prompts.
- **Onboarding**: Updated full and update tours to include Droid support and reflect the current agent lineup.

## [2.9] - 2025-12-23

**Agent Sessions 2.9 Christmas Edition**

### New Features

- **Onboarding Tours**: Interactive onboarding for new installs and a skippable update tour for major/minor releases. Reopen anytime from Help → Show Onboarding.
- **Copilot CLI Support**: Full session browser integration for GitHub Copilot CLI sessions. Includes Preferences pane and toolbar filter (⌘5).
- **Saved Sessions Window**: New dedicated window (View menu) for managing archived sessions with delete, reveal, and diagnostics.
- **Keyboard Navigation**: Option-Command-Arrow shortcuts to jump between user prompts, tool calls, and errors in transcripts.

### Improvements

- **Preferences**: Reorganized CLI agent controls. Disabling an agent now hides it everywhere (toolbar, Analytics, menu bar) and stops background work.
- **Improved Focus**: Transcript Find controls stay out of Tab navigation unless explicitly opened, preventing stuck focus states.

### Fixed

- **Saved Sessions**: Archive backfill and reveal actions now work reliably. Pinning no longer blocks the UI.
- **Claude Sessions**: Better parsing for modern Claude Code format, session titles, and error detection.
- **OpenCode Sessions**: Fixed missing content in Plain/Color views for migration=2 storage schema.
- **Clipboard**: Fixed intermittent issue where full transcripts could overwrite clipboard.

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


## [2.8] - 2025-11-27

**My thanks to the OpenCode community - Agent Sessions now supports OpenCode!** (Resume and usage tracking are on the roadmap.)

### Added
- **OpenCode Support**: Full session browser integration with Claude Code OpenCode sessions, including transcript viewing, analytics, and favorites. Sessions appear in the unified list with source filtering.
- Preferences → Claude Code: Sessions Directory override to choose a custom Claude sessions root. The Claude indexer honors this path and refreshes automatically when changed. Defaults to `~/.claude` when unset.
- Preferences → Usage Probes: New dedicated pane consolidating Claude and Codex terminal probe settings (auto-probe, cleanup, and one‑click delete), with clear safety messaging.

### Changed
- Preferences → Usage Tracking: Simplified and HIG‑aligned. Added per‑agent master toggles (Enable Codex tracking, Enable Claude tracking) independent of strip/menu bar visibility. Moved all probe controls into the new Usage Probes pane. Reduced vertical scrolling and clarified refresh interval and strip options.
- Usage Tracking: Separate refresh intervals per agent. Codex offers 1/5/15 minutes (default 5m). Claude offers 3/15/30 minutes (default 15m). Note: Claude `/usage` probes launch Claude Code and may count toward Claude Code usage limits.
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
