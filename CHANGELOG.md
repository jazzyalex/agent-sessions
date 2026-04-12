# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Fresh-session validator for `scripts/agent_watch.py`: weekly staleness
  detection (`evidence.sample_freshness`) across all 7 agents and a new
  opt-in `--mode prebump` path with per-agent drivers for codex, claude,
  gemini, droid, and copilot. New recommendation `run_prebump_validator`
  blocks auto-downgrade to `bump_verified_version` when the newest local
  sample predates the installed CLI binary. Hybrid env-var-first auth
  with credential-copy hygiene gates (64 KiB / mode 0600 / 90-day
  warning). Copilot driver enforces a fail-closed sandbox-leak assertion
  overridable only via `--allow-real-home` per run.

## [3.6] - 2026-04-09

### Added
- Cursor: Cursor IDE/CLI added as 8th session provider — imports JSONL agent transcripts and SQLite chat databases from `~/.cursor/`. Supports session browsing, search, transcript viewing, subagent hierarchy, and resume command. No Cockpit support in this release.
- Discoverability: New-provider detection banner appears in the sessions view when a newly supported agent is found on disk but not yet enabled, prompting users to turn it on.
- Onboarding: Update tour now auto-generates a slide for newly available providers, so users see what's new without digging into preferences.
- Session sources: `versionIntroduced` and `featureDescription` metadata added to session source model for use in discoverability and onboarding flows.

### Fixed
- Cursor: Subagent metadata (`parentSessionID`, `subagentType`) now preserved during CursorSessionIndexer session merges.
- Reliability: Replaced unbounded `waitUntilExit` with bounded `Process.waitForExit` across CLI integrations (Codex, Gemini, Preferences), preventing potential hangs on unresponsive child processes.

### Maintenance
- Schema drift fixtures updated for Copilot `session.shutdown` and Claude `attachment` event types.
- Agent support matrix bumped for weekly format checks (2026-04-06).
- OpenCode fixture version bumped to 1.3.17.

## [3.5] - 2026-04-06

### Added
- Transcript toolbar: Export as Markdown button for saving session transcripts as `.md` files.

### Fixed
- Analytics: Index now auto-builds on view appear; suppressed probe cleanup double-refresh.
- Concurrency: Captured mutable vars as `let` before `MainActor.run` for Swift 6 strict concurrency compliance.
- Unified view: Restored `@ObservedObject` for Gemini indexer in `UnifiedSessionsView`.
- Thread safety: Added `NSLock` around cached date formatters in `ClaudeSessionParser` and `SessionIndexer`.
- Image Browser: Inline image click now handled in `mouseDown` for reliable open behavior.
- Preview.app: Use `/usr/bin/open` instead of `NSWorkspace` API to launch Preview reliably.

### Performance
- Analytics: Index building now derives from `session_meta` instead of file parsing, significantly reducing work.
- SwiftUI: Eliminated redundant body evaluations and cached date formatters to reduce CPU usage.

## [3.4.1] - 2026-04-03

### Changed
- Analytics: Index building is now explicit and on-demand. Opening Analytics no longer auto-starts indexing from the Unified toolbar; users can start, cancel, and manually update analytics index builds from the Analytics window.
- Performance: Analytics indexing work is decoupled from routine provider refresh paths so Unified/Cockpit stay responsive when Analytics is idle.
- Performance: Core session indexing now uses a lower-impact foreground execution profile, reduced focused-session monitor cadence, and no longer cancels in-flight refreshes when the app deactivates.
- Unified toolbar: Refresh indicator now explicitly represents core session indexing (not analytics), with clearer status/help copy to distinguish it from Analytics index builds.
- Performance: Automatic core refresh monitors now pause while the app is foreground/active and resume in background, reducing sustained CPU and avoiding near-continuous "indexing" status during active Unified use.
- Unified footer: Core indexing status now shows live session progress (`X/Y` and `%`) instead of a generic "refreshing" message.
- Unified filters: Toggling agent pills in the toolbar is now filter-only and no longer auto-triggers index refreshes.
- Indexing UX: Background monitor refreshes now surface as lightweight syncing status, while launch/manual indexing keeps stable progress messaging.
- Indexing reliability: Core indexers now persist their own per-source file-stat baselines and restore them on startup, preventing large false re-sync runs after restart when only a few sessions changed.
- Indexing reliability (Codex): Incremental refresh now force-includes recent files that exist on disk but are missing from the hydrated session snapshot, preventing newest sessions from being silently skipped when persisted file-stat baselines are ahead of session rows.
- Indexing reliability (Codex): `thread_name` side-channel overrides now apply only to verified `.../sessions` layouts and use stronger cache invalidation, preventing cross-root title mismatches and stale rename reuse.
- Agent Cockpit: `Go to Session` remains blocked for cwd-only fallback matches, but runtime-ID matches are now treated as navigable again.

### Added
- Analytics: Build lifecycle UI now includes not-built, building, canceled, failed, and stale states with visible progress details (percent, sessions processed, source progress, and indexed date span).
- Session list: Subagent sessions now show an `s` indicator in flat list view so they are identifiable without the hierarchy expanded. The indicator is hidden in hierarchy view where nesting already conveys subagent status.
- Agent Cockpit: Limits bar now auto-expands the detail panel when any quota indicator is amber/red and reset times no longer fit inline, so constrained usage is always visible without a hover.
- Codex: Session custom titles are now parsed from `session_index.jsonl` (`thread_name` field) using a lock-protected mtime/size/path cache and tail-read for large files.
- Copilot: Session custom titles are now parsed from `workspace.yaml` (`name` field), gated to directory-based layouts to prevent cross-session contamination.
- Claude: Custom session titles set via the `/rename` CLI command are now reliably restored after relaunch.

### Fixed
- Claude: Custom session titles set via the `/rename` CLI command were not restored after relaunch because `upsertSessionMetaCore` omitted `custom_title` from its `UPDATE SET`; non-NULL parsed values now update the DB while NULL preserves the existing title.
- Custom title scan in the lightweight parser now uses a chunked gap scan (64KB chunks, 8MB budget) so title records in the middle of large session files are no longer missed.

## [3.4] - 2026-03-30

### Added
- Session list: Codex subagent sessions now appear as nested children under their parent in the unified session list. A toggle shows or hides the hierarchy; `Cmd+H` controls visibility from the keyboard.
- Agent Cockpit: Active Codex subagent count badge added to HUD rows. `Cmd+Shift+S` toggles subagent display.

### Fixed
- Agent Cockpit HUD: Codex active subagent badges now use the runtime `thread_spawn` state DB when available, so open worker agents stay counted even when their rollout files go quiet; passive rollout/`lsof` heuristics remain as a fallback.
- Agent Cockpit HUD: Codex runtime subagent counts now resolve the parent session before runtime edge lookup (even when the primary log path is a child rollout), and runtime state DB discovery now honors `CODEX_HOME`/`SessionsRootOverride` before falling back to `~/.codex`.
- Codex limits tracking: Visible usage surfaces now prefer auth-backed limits refresh first, fall back to CLI RPC and JSONL only when needed, and keep `/status` probing as a last resort. Preferences copy now reflects the new source order.
- Codex limits tracking: `/status` fallback snapshots now refresh their rate-limit buckets correctly, menu-background surfaces still run the preferred OAuth/CLI refresh chain, and partial live responses no longer leave the other bucket frozen as if the whole snapshot were authoritative.
- Performance: Eliminated a `repeatForever` animation CPU drain in session rows that caused sustained energy use even when sessions were idle.
- Security: SQL queries throughout the indexer are now fully parameterized; regex extraction is hardened against malformed input.
- Subagents: Subagent sessions are preserved in search results when hierarchy display is disabled, preventing sessions from going missing in filtered views.
- OpenCode: Parent ID query is guarded for older SQLite schemas that predate the `parent_id` column.
- Indexing: Reindex purge now runs after table creation in bootstrap, preventing failures on first-run with no prior DB.
- Launch/TCC: Session startup now avoids implicit repo filesystem probes while deriving row project names, reducing spurious Photos/Music permission prompts after rebuild/cold launch.
- Launch restore: `Saved Sessions` window now registers shared window-open routing callbacks, so menu-bar `Open Agent Sessions`/cockpit routing still works when only Saved Sessions is restored.
- Launch/TCC: Preferences agent status rows and OpenCode backend badges now use stored non-probing state under build tooling, avoiding extra PATH, root-directory, and SQLite checks during metadata extraction.

## [3.3.3.1] - 2026-03-26

### Fixed
- Codex: Reset countdown no longer exceeds the 5-hour window — reset times are now stored in ISO 8601 format, preventing a date-rollover bug that produced countdowns of up to 24 hours.

## [3.3.3] - 2026-03-26

### Added
- Agent Cockpit: Reduce transparency is now on by default for improved HUD readability in both docked and floating modes.

### Fixed
- Agent Cockpit: OpenCode sessions now participate in iTerm tab-title enrichment alongside Claude and Codex.
- Agent Cockpit: Hover tooltip columns now align consistently across Claude, Codex, and Copilot providers.
- Codex: Repaired fallback chain for limit tracking when sessions are stale or missing — percentages no longer get stuck.
- Codex: Preserved mtime cache on menu-background alt-source early return, preventing stale timestamps.
- Copilot: Fixed CLI session discovery for subdirectory workspace layouts.

## [3.3.2] - 2026-03-21

### Added
- Resume: Session resume support for GitHub Copilot CLI and Gemini CLI — right-click any active Copilot or Gemini session to copy the exact CLI resume command. Safe to skip this update if you don't use either agent.

## [3.3.1] - 2026-03-20

### Added
- Codex Usage: OAuth API and CLI RPC fallback for rate limits — when the Codex CLI hits a rate limit, usage tracking automatically falls back to the OAuth endpoint so token data keeps flowing without interruption.
- Resume: Copy Resume Command added to the context menu for Claude, Codex, and OpenCode sessions — right-click any active session to copy the exact CLI resume command to the clipboard.
- OpenCode: Session resume support — OpenCode sessions can now be resumed directly from the context menu, matching Claude and Codex.

### Fixed
- **Critical — Codex Usage:** Fixed a 0% token display bug and a blocking-pipe issue that prevented Codex usage tracking from working at all. **This update is required for Codex usage tracking to function correctly.**
- Resume (OpenCode): Corrected OpenCode CLI flags and inherit the user's iTerm preference when generating resume commands.
- Resume (Claude): Fixed Claude session ID resolution so Copy Resume Command produces the correct command for active Claude sessions.

## [3.3] - 2026-03-19

### Added
- Claude Usage: Multi-tier tracking with credential gating and Web API fallback. Reads live token usage via the OAuth endpoint (60-second refresh cycle), falls back to the tmux socket probe, and optionally fetches from the claude.ai Web API using a session cookie — with clear Full Disk Access guidance surfaced in Preferences when Web API mode is active.

### Changed
- Claude Usage: Unified the refresh-interval constant across all tracking tiers and hardened org UUID validation to prevent bad identifiers from poisoning the cache across sessions.
- Preferences: Usage Tracking pane layout overhauled — data-source picker converted to a popup menu, segmented controls fill available width without overflow, and strip-option toggles stacked vertically for consistency.

### Fixed
- Usage display: Codex auto-probe cooldown no longer masquerades as UI freshness. Cockpit and in-app usage surfaces now age data correctly after `/status` probes while still suppressing redundant background probes.
- Usage (Codex): Rollout logs that emit `token_count` events with `rate_limits: null` are now treated as limit-unavailable rather than reusing stale session-file percentages from before the last reset. This also re-enables the `/status` probe fallback for that newer Codex session format.
- Agent Cockpit: The pinned HUD limits footer now rebuilds from live usage-model updates the same way the main window footer does, preventing stale percentages from persisting after the underlying snapshot changes.
- Agent Cockpit: Weekly reset times in the hover-expanded limits footer now format consistently as `Day H:MM AM/PM` for both Codex and Claude.
- Agent Cockpit: Cockpit-only launch (including pinned mode) now runs the same one-time startup/bootstrap path as the unified window, so Claude session names resolve without needing the main window open first.
- Claude Usage: Safari cookie path corrected for both sandboxed and legacy macOS filesystem layouts; TCC Full Disk Access guidance now surfaces in Preferences when Web API mode is active.
- Claude Usage: Guarded system-preferences URL construction to eliminate a force-unwrap crash path.
- Claude Usage: Stale OAuth caches are invalidated on 401 responses; 429 rate-limit responses are now routed through the Web API fallback instead of blocking the refresh cycle.

## [3.2.1] - 2026-03-16

### Added
- Agent Cockpit HUD: Usage limits footer now shows Claude API reset time and rate-limit state, with idle reason classification surfaced on the status dot.
- Agent Cockpit HUD: Claude OAuth usage tracking with tmux socket fallback for probe-less environments.

### Fixed
- Agent Cockpit HUD: Eliminated transient "—" flash when iTerm2 probe returns an empty result.
- Agent Cockpit: Three probe stability fixes — tmux socket leak on teardown, excessive re-probe on focus change, and HUD visibility loss after backgrounding.
- Agent Cockpit HUD: Three display fixes — stale session titles after tab switch, empty-state flash on first load, and wrong-tab focus on direct open.
- Session discovery: Prevent two processes sharing the same working directory from claiming the same session log.
- Session discovery: Infer Claude session log from project directory when `lsof` socket lookup misses it.
- Session discovery: Assign distinct sessions to multiple presences in the same workspace.
- Session discovery (Claude Code): Improved Cockpit HUD session matching for Claude Code processes.
- Session discovery (Claude Code): Use `fullReconcile` on Cockpit-only launch to surface sessions that skipped the normal indexing path.
- Agent Cockpit HUD: Bootstrap indexers from Cockpit and show a spinner while usage limits are loading.
- Usage probe: Parse ISO 8601 reset timestamps correctly and display reset time even when the limit data is stale.
- Usage probe: Enforce a 5-minute minimum on `429 Retry-After` to prevent rapid retry loops.

## [3.2] - 2026-03-13

### Added
- OpenCode: Added read-only SQLite backend support for OpenCode v1.2+, including automatic detection between `~/.local/share/opencode/opencode.db` and legacy per-file JSON session storage. Preferences → OpenCode now shows the detected backend.

### Changed
- Agent Cockpit / Menu Bar: OpenCode live sessions now participate in shared active/waiting summaries, background session lookup, and iTerm-based presence detection alongside Codex and Claude.

### Fixed
- OpenCode: Main-window session rows now show live-state dots for active and waiting OpenCode sessions.
- OpenCode: iTerm busy-state detection is more reliable, reducing false idle/open classification while a session is still working.
- OpenCode: Search hydration and direct session-directory overrides now work correctly for SQLite-backed storage.
- OpenCode: Raw JSON previews are capped at `8 KB` with valid-JSON truncation to avoid oversized payload rendering.

## [3.1] - 2026-03-12

### Changed
- Onboarding: Session visible/hidden counts now refresh on any live session-data update (not just total-count deltas), and DB snapshot fallback now evaluates session visibility with the same active filter logic used by onboarding counts.
- Window restoration: Relaunch now restores the primary `Agent Sessions` window reliably even when its autosave name was already set, and auto-reopens `Agent Cockpit` when it was pinned.
- Agent Cockpit: Major stability update. Fixed the Cockpit CPU/energy leak, eliminating long-run resource creep while pinned or backgrounded, while also reducing full-list/partial-row flicker and improving handling for disappearing probe rows.
- Agent Cockpit: Follow-up CPU stabilization now suppresses redundant HUD snapshot invalidations, pauses idle-dot pulse animation while the app is inactive, and applies stable-cycle pinned-background cadence backoff up to `5s` to reduce long-run CPU accumulation without changing foreground responsiveness.
- Agent Cockpit: Navigation and pinned-window behavior are more reliable after relaunch and while backgrounded, including correct `Open Agent Sessions` routing and tooltip layering above the HUD.
- Menu Bar: Added a dedicated `Show Active/Waiting sessions` toggle plus a `Show menu bar icons` setting so live session dots can be shown independently from usage meters.
- Preferences: Added an `Advanced` toggle to hide the Dock icon by switching Agent Sessions into accessory app mode; default remains off.
- Preferences: `Hide Dock icon` now keeps a reopen path by auto-enabling the menu bar item, and app activation policy falls back to Dock-visible mode if no persistent reopen affordance is available.
- Menu Bar: `Open Agent Cockpit` now routes by the cockpit window identifier only, avoiding false matches against unrelated untitled windows.
- Agent Cockpit: Non-active live sessions now use `Waiting` terminology, grouped headers stay single-line, compact pinned mode keeps its toolbar visible, and long-waiting projects are visually deprioritized.
- Menu Bar / Agent Cockpit: Live active/waiting counts and quick actions are surfaced more clearly, and follow-up fixes restored hidden menu bar items and unresolved Codex live presences.

## [3.0.1] - 2026-03-04

### Fixed
- Sessions (Agent Cockpit): Active green live-status dots now render through a strictly static path so they no longer pulse in cockpit rows; idle amber dots remain animated.
- Sessions (Agent Cockpit): Compact mode no longer auto-resizes on every row-count change by default; it now uses a stable default height (`Medium`, 4 rows) with internal scrolling, preserves user-resized compact height when toggling full↔compact and across app restarts, and adds compact-size controls (`Small/Medium/Large`) in Settings plus optional auto-fit re-enable.

## [3.0] - 2026-03-04

### Features
- Agent Cockpit (Beta) is now the primary live command center for active iTerm2 Codex CLI and Claude Code sessions.
- Onboarding was redesigned around cockpit-first workflows so new and upgrading users reach live session controls faster.
- Cockpit gained direct row actions (`Go to Session`, terminal focus, log/workdir reveal, and copy helpers) for quick workflow handoffs.

### Improvements
- Live session tracking now better reflects real activity with clearer active vs idle states and steadier HUD indicators.
- Gemini session discovery now supports newer named project folder layouts under `~/.gemini/tmp`, restoring full indexing for recent Gemini CLI data structures.
- Cockpit compact/full behavior, subtitles, sizing, and toolbar ergonomics were refined for faster scanning and less layout churn.

### Bug Fixes
- Claude usage probe CPU spikes were reduced by hardening tmux cleanup/socket-liveness handling and probe lifecycle management.
- Cockpit window behavior is more stable: unpin restore, subtitle retention, ordering consistency, and compact/full transition reliability were fixed.
- Unified session view refresh and live-state joins were hardened to reduce transient empty flashes, ghost rows, and stale live indicators.

### Added
- Agent Cockpit (Beta): Agent Cockpit is now the primary live command center for iTerm2 Codex/Claude sessions, with grouped active/idle visibility and one-click focus workflows.
- Onboarding (v3): New-user onboarding now introduces `Agent Cockpit (Beta)` as the third slide immediately after `Connect Your Agents`.
- Onboarding (v3 updates): Upgrade onboarding is now a focused two-slide flow with an `Agent Cockpit (Beta)` how-it-works explainer followed by a feedback/community-support slide.
- Sessions (Unified): Added an Agent Cockpit toolbar icon button in the main window for one-click access to the cockpit window.
- Sessions (Agent Cockpit): Added a row context menu with `Go to Session`, `Focus in iTerm2`, `Reveal Log`, `Open Working Directory`, `Copy Session ID`, `Copy Tab Title`, and `Copy Working Directory Path`.
- Cockpit: Added a Cockpit window for active Codex sessions with iTerm2 focus, plus active-session indicators in the Unified sessions list.
- Sessions (Cockpit/Unified): Live session detection now includes Claude in addition to Codex, with mixed-source live rows in Cockpit and source-aware live filtering in Unified Sessions.
- Sessions (Unified): Added a small active-status dot in the `CLI Agent` column for live Codex sessions.
- Sessions (Unified): Added a blue-dot toolbar filter toggle (dot-only control) before the agent toggles to show only active sessions in the list.
- Sessions (Cockpit/Unified): Codex live-session status now distinguishes `active` (working) from `open` (idle). Active rows use a pulsing dot and open rows use a solid dot.
- Sessions (Cockpit): Added a live-session filter segmented control with `Both`, `Active`, and `Open`; default is `Both`.
- Sessions (Unified): Added `CLI Agent` cell double-click terminal focusing in the Sessions list (same focus path as `Focus in iTerm2`), with explicit alert feedback when no focusable live terminal is available.

### Fixed
- Sessions (Agent Cockpit): Full-mode subtitles now prefer custom iTerm window titles when session naming is set to default job labels (for example `codex`), so configured window-label subtitles are no longer dropped.
- Sessions (Agent Cockpit): Unpin now reliably restores normal window stacking behavior, cockpit tab subtitles now show only cleaned custom tab/window labels (default CLI suffixes are hidden), and row typography/spacing was tightened so idle titles stay readable in both compact and full modes.
- Sessions (Agent Cockpit): HUD row status dots now use the same shared renderer as the main Sessions list, so active (green) dots remain steady in both compact and full cockpit modes.
- Sessions (Agent Cockpit): Active green status dots now opt out of parent row animations, preventing perceived pulsing/flicker and keeping cockpit active-dot behavior aligned with the main Sessions list.
- Sessions (Agent Cockpit): Compact mode now includes a dedicated tab/window subtitle column after `Agent`, defaults to a narrower first-run compact width (so session titles truncate earlier), auto-hides compact header controls when unfocused unless the mouse is hovering the cockpit, collapses/expands compact window height with toolbar visibility, balances top/bottom compact spacing for short unfocused lists, and now auto-fits focused compact height to visible sessions up to 10 rows before vertical scrolling.
- Sessions (Agent Cockpit): Grouped compact mode no longer over-shrinks on focus loss; when toolbar hides it now subtracts only header height (not extra row delta), so manually sized grouped views no longer clip bottom rows.
- Sessions (Agent Cockpit): Compact/full toggles now preserve user-resized frame dimensions in both directions, cockpit-visible background probing now remains warm even when unpinned (preventing intermittent `No active sessions` flicker while unfocused), and grouped `Idle` pills now use the same amber palette as idle status dots.
- Sessions (Agent Cockpit): Switching from compact mode back to full mode now reliably restores normal titled-window chrome, including title text and traffic-light controls.
- Sessions (Agent Cockpit): Full-mode iTerm subtitle rows now preserve tab/window title metadata through live-row dedupe so subtitle text no longer disappears unexpectedly.
- Sessions (Agent Cockpit/Unified): `Go to Session` navigation from cockpit now auto-reveals hidden target sessions in the main list by relaxing restrictive filters when needed.
- Sessions (Agent Cockpit/Unified): `Go to Session` navigation now uses a pending request handoff with retries, preventing dropped navigation when the Agent Sessions window/view is still initializing; auto-reveal now also clears `Saved Only` filtering so non-favorite targets can be selected.
- Agent Cockpit: Removed the in-app `Legacy Cockpit` window scene so only `Agent Cockpit` is available at runtime.
- Agent Cockpit: Full-mode row recency now reflects session write activity (`sessionLogPath`/presence source file mtime) instead of heartbeat timestamps; compact mode hides the recency token.
- Agent Cockpit: Full-mode rows can now show iTerm tab title as an optional muted subtitle under the agent label, with long titles truncated and full text available on hover.
- Agent Cockpit: iTerm subtitle detection now falls back to the iTerm window title when a tab/session title is empty, so full-mode subtitle rows remain informative in minimal-tab setups.
- Agent Cockpit: iTerm subtitle refresh now prioritizes current iTerm tab titles (including post-launch tab-title edits), resolves titles by iTerm session GUID when TTY metadata is missing, keeps subtitle lookup in a single guarded iTerm scan so one inaccessible tab variable does not blank all rows, and avoids refresh stalls from per-session `osascript` loops on large iTerm setups.
- Agent Cockpit: Full-mode subtitle discovery now reads iTerm tab titles through the native tab `title` property, so tab-only custom titles remain visible even when window title is empty.
- Preferences (Agent Cockpit): Added `Show tab subtitle under agent name` for full-mode cockpit rows (default on).
- Sessions (Agent Cockpit): Idle HUD rows now keep the session display name in the main text column, `Last active ... ago` messaging was moved to a compact elapsed column (for example `16s`), active status dots now render as solid green indicators, and idle status dots now pulse amber with a larger size after 10 minutes idle.
- Sessions (Unified): `CLI Agent` live-state styling now matches Agent Cockpit: active sessions use a solid green dot, idle sessions use a pulsing amber dot that grows slightly after 10 minutes idle, and idle source cells are visually dimmed.
- Sessions (Agent Cockpit/Unified): Idle amber status-dot pulses now brighten at peak size (instead of dimming), making animation more visible in both Cockpit and the main Sessions list.
- Sessions (Agent Cockpit): Filter controls now use three single-select pills (`All N`, `Active N`, `Idle N`), with `Active` pill accent in amber and `Idle` pill accent in green for clearer state while preserving compact cockpit styling.
- Sessions (Agent Cockpit): Compact mode now uses chrome-less window styling (no titlebar controls), no longer forces compact height on every refresh, and now sizes compact list height with group/divider layout units to avoid hidden rows.
- Sessions (Agent Cockpit): Grouped compact mode now reserves extra bottom spacing so the last row is not cramped/clipped, and switching from compact back to full mode now preserves the current window size (no automatic full-mode resize).
- Sessions (Agent Cockpit): Compact window sizing now also recalculates while live mode is disabled and reserves space for the disabled-state callout, preventing compact clipping in the disabled state.
- Sessions (Agent Cockpit): Agent label, project name, and session name row typography/colors now align with the main Session list style (source-accent agent text and monospaced session/project text).
- Sessions (Agent Cockpit): Agent-column labels now render as plain text (pill removed) and use the same standard Codex/Claude accent colors as the main Sessions list.
- Sessions (Agent Cockpit): Removed persistent row-selection highlighting and removed up/down row navigation; cockpit row actions now use direct mouse clicks plus shortcut jumps (`Cmd+1...9`, `Cmd+0` for row 10).
- Sessions (Agent Cockpit): Compact mode keeps the filter pills visible in the toolbar, removes the keyboard-shortcut badge column, and tightens compact height math so extra top/bottom blank bands are not reserved around the session rows.
- Sessions (Agent Cockpit): Compact mode no longer reserves a titlebar-sized blank strip above the toolbar; compact rows now start at the top edge of the HUD content area.
- Sessions (Agent Cockpit): Removed the active/idle split divider between rows in compact/full list rendering, and hardened HUD window configurator wiring to remain click-through for controls/rows.
- Preferences: Reordered the Settings sidebar so `Agent Cockpit` appears directly after `General`.
- Sessions (Agent Cockpit/Codex live detection): Pinned `Agent Cockpit` now uses a faster background refresh cadence (`3s`), foreground-return iTerm live-state probing now ramps in bounded batches to flatten short CPU spikes, and iTerm session discovery now reuses a single session-list fetch for Codex+Claude.
- Sessions (Agent Cockpit/Codex live-state): Codex ambiguous non-prompt iTerm tails now fall back to log-write heuristics (instead of immediately forcing idle), and background iTerm probing is now deferred unless the app is foregrounded or a pinned cockpit is visible.
- Sessions (Gemini): Session discovery now accepts named Gemini project directories under `~/.gemini/tmp` (for example `radio4j`), while still supporting both `chats/session-*.json` and direct `session-*.json` layouts.
- Usage tracking (menu bar): The menu bar quota tracker now shows an in-progress spinner while Codex or Claude usage probes are running, matching the in-app usage strip behavior even when reset indicators are hidden.
- Sessions (Cockpit): Selected-row text/dot colors now switch to selection-aware foreground styling and use the main Sessions-list selection accent/table style, improving readability when a Cockpit row is selected.
- Session view (Unified): Selected transcript rendering now keeps the last non-empty session snapshot when refresh churn briefly republishes lightweight/empty data for the same session ID, preventing flicker/empty transcript flashes during live updates.
- Sessions (Cockpit): Cockpit now hides only low-confidence unresolved live placeholders (missing join keys and fallback identity signals like tty/pid/source/workspace), preventing ghost rows while keeping valid fallback-detected live sessions visible.
- Sessions (Unified/Cockpit): Unified session-list live-status dots now refresh on Codex active-membership updates even when `Active sessions only` is off, keeping active/open indicators aligned with Cockpit state transitions.
- Claude usage probe: Login-shell path and `PATH` resolution now strips injected OSC escape sequences (for example from iTerm2 shell integration), respects custom Claude binary overrides, and hardens tmux startup/trust-prompt handling to avoid false `tmux_not_found` and premature probe failures.
- Claude usage probe: Probe tmux cleanup now removes managed socket files at script exit and classifies socket liveness before issuing tmux commands, eliminating stale-label cleanup churn that caused high sustained CPU when Claude tracking was enabled.
- Cockpit/Sessions (Unified): Active Codex sessions are now joined by Codex internal `session_id` when log-path metadata is unavailable, restoring active indicators and Focus-in-iTerm2 availability.
- Sessions (Unified): `Active-only` filtering now immediately applies during in-flight searches and re-seats selection when the previously selected row drops out of the filtered list.
- Sessions (Unified): Agent toolbar filter pills now show a clear enabled/disabled state in monochrome mode.
- Sessions (Codex active indicators): Active-session path normalization now uses cached canonical (symlink-aware) paths so equivalent roots (for example `/var/...` and `/private/var/...`) still join correctly, process fallback probing now shifts to slower completeness sweeps when registry data is already present, and background polling/probing now backs off while the app is inactive.
- Sessions (Codex active indicators): Active-session polling visibility now tracks Unified/Cockpit consumers per window instance, so closing one of multiple open windows no longer drops refresh cadence for the windows that remain visible.
- Sessions (Codex active indicators): Re-enabling active-session detection now preserves existing visible-window consumer registrations, so polling/probing immediately returns to foreground cadence without requiring window reopen.
- Sessions (Codex active indicators): Active lookups now avoid event-derived session-id fallback on row render paths, codex internal-id hint backfill now progresses in rotating background batches (instead of a fixed small cap), and active-only list rendering skips redundant per-row active checks.
- Sessions (Codex active indicators): iTerm tail classification now ignores stale historical `Worked for` output and only treats near-tail live markers as active; transient iTerm tail-capture failures now default to `open` instead of promoting sessions to false-active via mtime fallback.
- Sessions (Codex active indicators): Cockpit/Unified now reconcile tty-only iTerm fallback presences with existing keyed presences by TTY before publishing rows, preventing duplicate live-session rows in mixed registry/process + iTerm discovery flows.
- Sessions (Cockpit/Unified): Claude/OpenCode command fallback detection now matches executable command positions only (argv0/wrapper target/shell `-c` head), preventing argument/path-name false positives from creating phantom live rows.
- Sessions (Unified): Claude/OpenCode live fallback matching now assigns up to `N` newest candidate sessions for `N` unresolved presences (workspace-scoped or source-scoped), so concurrent same-repo terminals stay visible in live dots and `Live sessions only`.
- Sessions (Unified): Claude/OpenCode fallback ranking now excludes sessions already directly joined by `sessionId`/log path, preventing mixed direct+fallback states from dropping valid live dots and `Live sessions only` rows.
- Sessions (Unified): Claude/OpenCode fallback presence caching now keys by source + session ID, preventing cross-provider ID collisions from showing incorrect live dots or `Live sessions only` rows.
- Sessions (Cockpit): Unresolved registry-only placeholders are now hidden unless they are focusable or workspace-joinable, preventing ghost sub-agent rows (for example `Active Codex CLI session` with empty project).
- Sessions (Cockpit): Unresolved `subagent` presences are now always suppressed before join-key checks, preventing ghost rows that inherited `session_id` or `session_log_path`.
- Sessions (Claude/OpenCode live-state): iTerm tail probing now remains eligible when a TTY is present even if terminal metadata reports wrappers like `tmux`, reducing false `open` classifications caused by skipped probes.
- Sessions (Cockpit/Codex): Cockpit now hides unresolved Codex placeholders unless they join to an indexed session, preventing Cockpit-only ghost Codex rows while leaving Sessions list behavior unchanged.
- Sessions (Claude/OpenCode live-state): Generic iTerm tail classification now treats strong near-bottom live markers (for example `Esc to interrupt`) as authoritative, while prompt-at-bottom clears only stale/weak markers; weak busy markers are limited to near-bottom output to avoid sticky false-`active` dots.
- Sessions (Claude live-state): Claude now uses a dedicated iTerm-tail classifier and a wider mtime fallback window (`15s`) so active sessions are less likely to be shown as open when terminal output is active but JSONL writes are sparse.
- Sessions (Claude live-state): Claude iTerm probing now uses iTerm session flags (`is processing` / `is at shell prompt`) before tail heuristics, and tail parsing now strips ANSI escape sequences so active markers (for example styled `Esc to interrupt`) are detected reliably.
- Sessions (Cockpit/Claude/OpenCode): Unresolved non-Codex placeholders now require iTerm-backed focus identity (iTerm GUID/reveal URL or iTerm terminal metadata) or workspace joinability; `tmux`/TTY-only unresolved rows are suppressed to prevent Cockpit ghost sessions.
- Sessions (Claude live-state): Claude fallback prompt detection now recognizes zsh-style `%` prompt lines (for example `user@host %`) while still treating percentage status lines (for example `78%`) as non-prompt output.
- Sessions (Claude live-state): Claude probe conflict handling now prefers `is processing` over prompt metadata when both are true, and no-flag tails now classify as `active` only when no prompt markers are present near the bottom.
- Sessions (Cockpit/Claude/OpenCode): Unresolved non-Codex TTY-only rows are now hidden unless they have direct join keys (`session_id`/log path), workspace joinability, or explicit iTerm identity (GUID/reveal URL/`TERM_PROGRAM` iTerm), reducing `tmux` ghost rows.
- Sessions (Claude live-state): Claude tail classification now reserves `active` for strong live markers (for example `Esc to interrupt` / reconnect) so generic lexical history near a prompt does not stick sessions in false-active state.
- Sessions (Claude live-state/Cockpit): TTY-backed Claude rows are now iTerm-attempt eligible even when `TERM_PROGRAM` reports wrappers like `tmux`; Claude tail classification now treats near-bottom weak busy markers as active when no prompt is present, and mtime fallback now uses registry `sourceFilePath` writes when `sessionLogPath` is missing.
- Sessions (Claude live-state): iTerm probe metadata now emits/parses a real tab delimiter for processing/prompt flags, and Claude prompt matching now recognizes `❯ (No obvious next step)` style idle prompts to reduce false-active states.
- Sessions (Cockpit/Claude/OpenCode): Cockpit unresolved fallback assignment now uses the same one-to-one workspace/source mapping as Unified Sessions, so concurrent same-workspace sessions no longer collapse to a single Cockpit row.
- Sessions (Cockpit): Duplicate-row resolution for the same joined session now prefers freshest presence telemetry over stale `active` state, reducing sticky active dots until window reopen.
- Sessions (Unified/Cockpit): Manual refresh now also triggers an immediate live-session probe refresh (bypassing probe throttle), so active/open state transitions update without waiting for background cadence.
- Sessions (Unified): `CLI Agent` live-status cells now rebind on active-membership version changes so active/open dots repaint immediately even when the session row data itself is unchanged.
- Session view (Unified): Session list refresh now holds the prior selection/rows during transient empty publishes while indexing/search churn is in flight, preventing momentary blank transcript placeholder flashes.
- Claude usage probe cleanup: orphaned `as-cc-*` tmux label cleanup is now processed in bounded batches with delayed follow-up passes to avoid large single-pass CPU spikes, and cleanup now excludes the currently active probe label.
- Sessions (Cockpit/Unified/Claude): Cockpit now suppresses unresolved live placeholders that are neither focusable nor joinable to indexed workspace sessions, dedupes unresolved rows by stable tty/workspace identity, and its `Refresh` action now refreshes both live presence and provider indexes; Claude refresh now auto-escalates recent-scope drift to full reconcile, and manual refreshes in both Unified and Cockpit now run Claude full reconcile so newly opened Claude sessions appear reliably in the main Sessions list.

### Changed
- Sessions (Agent Cockpit): HUD rows now remove the visible row-number column, keep `⌘1...⌘9` shortcut badges bound to visual order, and apply one-shot highlight washes for newly added rows.
- Sessions (Agent Cockpit): Row order now stays stable while the window is visible and only re-sorts after hide/minimize when membership changed while hidden; quick hide/show without row churn keeps order unchanged.
- Sessions (Agent Cockpit): Compact/full window sizing now persists per mode across restarts, compact defaults to six rows on first use (minimum three rows), and session add/remove no longer auto-resizes the window.
- Sessions (Agent Cockpit): Added explicit empty states (`No active sessions` in full mode, `No sessions` in compact mode) and enabled overflow scroll indicators in compact mode.
- Sessions (Agent Cockpit/Unified): Live-status visual hierarchy now emphasizes idle sessions (stronger amber pulse) while active sessions use a calm static green dot; all live dots now render at 7pt and idle row dimming is slightly reduced for readability.
- Sessions (Agent Cockpit): Agent badges, preview text, elapsed-time text, and grouped idle-count chips now use higher-contrast light/dark palettes for improved scanability.
- Sessions (Agent Cockpit): Full and compact HUD modes now both surface vertical scroll indicators for overflow lists.
- Sessions (Agent Cockpit): Full HUD mode now allows long session names to wrap to two lines in the main row text, while compact mode keeps names single-line.
- Sessions (Agent Cockpit): Compact HUD mode now hides the window title text while preserving user-controlled window height.
- Sessions (Agent Cockpit): Replaced the `Agent Cockpit` window UI with the new floating HUD layout (chips, inline filter, grouped mode, compact mode, pin mode, and keyboard row shortcuts) while keeping Legacy Cockpit available and reusing existing live-session backend logic.
- Sessions (Agent Cockpit): Window title now includes the currently shown session count (`Agent Cockpit (N)`), the in-content `AGENT COCKPIT` label and footer row (`Session List` + freshness) were removed, and focused-window blue list focus ring styling was removed for a cleaner HUD appearance.
- Menu/Cockpit windows: Renamed the existing Cockpit window/menu item to `Legacy Cockpit` (defaulting to the `Live` filter), added a new single-instance `Agent Cockpit` window/menu item, moved `⌘⌥⇧C` to `Agent Cockpit`, and removed the Legacy shortcut.
- Menu/Cockpit windows: Removed `Legacy Cockpit` from the `View` menu so only `Agent Cockpit` is exposed in the primary window menu.
- Menu/Cockpit windows: Removed `Legacy Cockpit` from the macOS `Window` menu while keeping the legacy scene code path available.
- Preferences (Advanced): Reordered sections so `Saved Sessions` appears above `Search`.
- Preferences (Advanced): Reordered sections so `Git Context` appears at the bottom, and renamed `Live Sessions + Cockpit` to `Live Sessions + Cockpit BETA`.
- Preferences (Advanced): Live-session/Cockpit controls are now consolidated under `Live Sessions + Cockpit (Beta)` in Settings → Advanced as the single feature toggle location.
- Sessions (Live/Cockpit): OpenCode active/open session detection is temporarily disabled for this release; live-state scope is now Codex + Claude only.
- Cockpit/Sessions (Live controls): When `Live Sessions + Cockpit (Beta)` is disabled, Cockpit and live-filter controls remain visible but disabled with explanatory help text.
- Sessions (Cockpit): Cockpit header controls now show only `Active` and `Live` filters (removed `Cockpit`/`Show` text); `Live` includes both active and idle sessions.
- Sessions (Cockpit): Cockpit window layout no longer uses a fixed content frame; rows scale naturally with window resizing, with per-mode frame persistence and no session-count auto-resize.
- Preferences (Unified Window): Reordered sections so `Columns` and `Filters` appear before `Rich Transcript`.
- Preferences (OpenClaw): Moved `Include deleted OpenClaw sessions` from Advanced to the OpenClaw pane as a standalone checkbox.
- Preferences: Added a dedicated `Agent Cockpit` pane and moved Live Sessions + Cockpit settings there from `Advanced`; compact mode now includes a `Show agent name in compact mode` toggle (default on).
- Sessions (Unified): Removed the leading dot from agent pill toggles in the main toolbar.
- Sessions (Unified): `Active sessions only` now filters to live Codex sessions (`active` + `open`) instead of only actively working sessions.
- Sessions (Unified): `Active sessions only` now filters to live Codex and Claude sessions (`active` + `open`).
- Sessions (Cockpit): Removed `Copy Session ID` from Cockpit row context menus; session ID copy remains available in the Sessions list.
- Sessions (Unified): `CLI Agent` live-status dots now render before the agent name for improved column alignment.
- Cockpit: `View > Cockpit` now always opens/focuses a single Cockpit window instance.

## [2.12] - 2026-02-24

### Fixed
- Onboarding (updates): Auto-onboarding is now suppressed for upgrades from `2.11.x` to `2.12`; update onboarding continues for users upgrading from older major/minor versions.
- Codex usage tracking: JSONL backward scans now continue extracting token-usage fields while searching for the preferred `codex` rate-limit stream, preventing stale token values when newer non-codex limit buckets are present.
- Sessions (OpenClaw): Tool format scanning now recognizes underscore/case variants for tool-call and tool-result blocks, and `is_error` tool-result flags are now classified as errors in transcript events.
- Transcript (Session view): Code-fence opening detection now requires line-start fences, preventing inline triple-backtick snippets from consuming later fenced blocks and misclassifying narrative text as code.
- Transcript (Session view): Codex review-card parsing now skips malformed fenced JSON candidates and continues scanning later candidates, so one invalid payload block no longer suppresses a valid review summary.
- Transcript (Session view): `path:line:column` file references now preserve their column target when linkified, avoiding overlap with `path:line` parsing that could drop column navigation.
- Transcript (Session view): Opening file links in Cursor/VS Code no longer blocks transcript interaction while the editor CLI starts; CLI launches now run asynchronously with fallback behavior preserved.
- Transcript (Session view): Multiple Cursor/VS Code file-link opens now run concurrently, so slow/unavailable editor CLIs no longer serialize later clicks behind earlier timeout waits.
- Session view (Unified): Jump-to-latest arrow visibility is now driven by transcript position for every agent/session type, so it appears whenever the viewport is away from the end (including immediately after switching sessions) and no longer depends on active-session refresh paths.
- Session view (Unified): The floating jump-to-latest control now uses a smaller compact circle and now appears immediately after session selection whenever the transcript is not at the tail (no initial scroll required).
- Session view (Unified): Clicking the floating jump-to-latest control now hides it immediately after programmatic scroll-to-end, without requiring additional manual up/down scrolling.
- Session view (Unified/Codex): When new output arrives while reading away from the tail, a floating down-arrow now appears in Session/Text modes to jump to the latest transcript output and resume sticky follow-to-bottom behavior.
- Sessions (Unified): Key-window resign no longer clears focused session state, preventing missed active-transcript updates after returning to the app/window.
- Sessions (Unified): Focused active-session monitoring is now capability-driven per source, with one key-window-selected session monitored at high cadence and deterministic stop/start behavior across window/app activation changes.
- Sessions (Gemini/OpenCode/Copilot/Droid/OpenClaw): Focused-session reloads now use in-flight dedupe, unchanged-file fast-skip, and monitor-safe reload behavior that avoids loading-overlay flicker for already-rendered transcripts.
- Session view (Unified): Replaced the table-selection bridge with canonical ID-driven selection so transient row churn no longer clears active transcript selection, and transcript host routing now stays pinned to canonical source resolution.
- Session view (Unified): Active session selection now stays sticky during background refresh/search churn, preventing transient table-selection clears from detaching the transcript pane and showing the empty placeholder while the session still exists.
- Search fields (Unified global search + transcript Find): `Esc` now clears the active field directly when that field has focus, eliminating the system beep and making clear behavior consistent from the keyboard.
- Transcript Find (`Esc`): pressing `Esc` with an empty Find field now closes the Find bar again (`Close Find (⎋)`), restoring keyboard-only close behavior.
- Claude Usage: tmux `/usage` probes now use a larger runtime timeout envelope (derived from script boot timeout) so successful but slower probes no longer fail with premature `Script timed out` (`exitCode 124`) errors.
- Session view (Unified): table selection synchronization now keeps programmatic updates out of manual-selection handling, preventing auto-selection from being disabled by internal selection coalescing.
- Session view (Unified): Removed the transient "Selected session is hidden by the current search/filter" notice and its `Show in List` / `Keep Hidden` actions.
- Session view (Unified): Transcript tail-append now verifies the previous tail event content (not only ID), forcing a full rebuild when a live update rewrites the prior tail event in place.
- Session view (Unified): Transcript view now rebuilds on `eventCount`, `fileSize`, and `endTime` metadata updates for loaded sessions, so in-place live parsing changes without `events.count` growth no longer leave stale text.
- Session view (Unified): Transcript rebuild triggering is now keyed off a stable session render signature (`id`, `eventCount`, `events.count`, `fileSize`, `endTime`, `isFavorite`) so same-ID live updates and favorite toggles always re-evaluate rendering.
- Session view (Unified): Transcript rendering now keeps the last non-empty resolved session snapshot when refresh briefly republishes the same session ID as lightweight/empty, preventing transient blank transcript drops during live refresh.
- Session view (Unified): Transcript tail-append now writes appended output to the in-view build-key cache, preventing stale transcript regressions when switching modes during live updates.
- Session view (Unified): Active transcript tail-append updates now keep readiness state in sync with the current build key, so Unified Search auto-jump still triggers after append-only live updates.
- Session view (Unified): Transcript tail-append now requires render-option parity with the previously rendered buffer, so toggles like `Skip preamble` force a full rebuild instead of appending into stale formatting.
- Session view (Unified): User-triggered manual refreshes now always show loading feedback for the selected session, even when transcript text is already visible.
- Session view (Unified): Loading animation now stays visible when the selected session is still loading but the on-screen transcript buffer belongs to a different session, preventing stale-content flashes without feedback.
- Session view (Unified/Terminal): Loading overlay now remains until the first terminal render completes, preventing brief blank panes and 0/0 navigation states on large sessions.
- Session view (Unified/Terminal): Transcript toolbar semantic navigation now detects code/diff content inside tool-output blocks, and semantic counter totals no longer collapse to `0/0` from semantic-filter state alone.
- Session view (Unified/Terminal): Transcript toolbar now hides navigation chips with no matching items (errors/images/code/diffs/reviews), uses compact marker+count chips when labels cannot fit, and on very narrow widths moves extra chips into a chevron overflow menu.
- Session view (Unified/Terminal): Toolbar fit mode now re-evaluates on width/layout transitions, preventing stale compact/overflow rendering after switching split layouts.
- Session view (Unified): Removed loading spinners from the transcript UI to avoid spinner-on-empty states while sessions load.
- Session view (Unified): Async transcript/JSON renders now persist the originating view mode in render state, preventing transcript-tail append from attaching to buffers built for another mode after mode switches.
- Sessions (Codex/Session view): Active-session transcript updates now append tail content in Session view instead of replacing the full rendered buffer on each monitor refresh, eliminating periodic flicker and preserving in-session reading/navigation context.
- Sessions (Codex): Focused monitor/background refresh reloads no longer surface loading overlays when transcript content is already visible, avoiding repeated loading flashes during near-live tail updates.
- Session view (Unified): Live transcript rendering now applies strict latest-generation gating across async rebuild paths, and Session mode now performs deterministic tail patching/signature checks to reduce stale or flickering text during rapid updates.
- Session view (Unified/Session mode): Terminal find/unified-find auto-scroll now runs only for explicit navigation requests (token-driven) so passive live refreshes no longer yank scroll position; canceled JSON rebuild tasks now reliably clear loading state for the active generation.
- Session view (Unified): Selected transcript content now keeps the last resolved session buffer during transient reindex gaps, and list-side programmatic selection updates are coalesced to avoid table reentrant delegate churn that could leave the transcript pane blank until reselection.
- Session view (Unified): Table-driven transient empty-selection events (during indexing/list churn) now preserve the active session selection instead of treating them as user deselects, and transcript host source/type now stays pinned to the last resolved selected session to prevent blank placeholder fallbacks.
- Sessions (Codex/Claude): Active-session transcripts no longer flash empty during periodic auto-refresh when a lightweight pass temporarily replaces fully parsed session data.
- Stability: Hardened Claude indexing refresh state synchronization (refresh token, file-stat cache, prewarm signatures) and made progress throttling thread-safe to reduce intermittent `EXC_BAD_ACCESS` crashes during concurrent indexing tasks.
- Usage tracking/menu bar: Codex and Claude polling now continues when usage is visible (including active in-app strip visibility), while inactive/background polling remains tied to that specific agent being shown in the menu bar; Codex menu-background polling also now re-seeds to newer JSONL session files instead of stalling on an older file.
- Sessions (Codex): Active selected sessions now refresh tails faster (focused-file monitoring with adaptive 5s/15s cadence), and `Refresh Sessions` now forces a full reload of the selected Codex transcript so newest prompts/outputs appear without reselection.
- Sessions (Claude): Focused selected sessions now use the same focused-file monitor path as Codex, forcing selected-session reloads when the active JSONL changes so live Claude output keeps the transcript pane populated.
- Sessions (Unified/Codex/Claude): Focused-session monitor cadence is now source-aware (Codex faster than Claude) with distinct active/inactive and AC/battery intervals, and monitor interval policy is now defined for every agent source to simplify future focused-monitor support expansion.
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
- Transcript (Session view): Added semantic transcript rendering for plans, code blocks, diffs, and Codex review summaries, including distinct block accents and improved block grouping boundaries.
- Transcript (Session view): Added clickable local file references (for example `Foo.swift:56`, `Foo.swift#L56`) with configurable editor open behavior (System default, Cursor, VS Code) and optional CLI path override.
- Preferences (Unified Window): Added Rich Transcript controls for review cards, file linkification, code/diff line numbers, and preferred editor target.
- Preferences/About: Added a new Diagnostics section for crash reporting with local pending queue controls (`Email Crash Report`, `Export Report`, `Clear Pending`) and a direct support email link.
- Crash reporting: Crash diagnostics are queued locally on launch and shared only through an explicit pre-filled email draft action; no automatic startup/background upload occurs.
- Crash reporting UX: Crash capture is always on (toggle removed), and when a new crash report is detected at launch the app now prompts to either `Email Crash Report` or `Export + Open GitHub Issue`.

## [2.11.2] - 2026-02-09

### Fixed
- Startup stability: Prevented a launch-time crash by removing early `NSApp.isActive` reads during Codex/Claude usage model singleton initialization and syncing app-active state after UI startup.

### Changed
- Preferences/Updates: Added an `Auto-Update` checkbox in Settings → About (next to `Check for Updates...`) and enabled Sparkle auto-update by default for new installs while keeping user opt-out.

### Fixed
- Cockpit: Active Codex session detection now keeps mixed registry/probe sessions visible, and Focus in iTerm2 is only enabled when iTerm-targetable metadata is present.

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
