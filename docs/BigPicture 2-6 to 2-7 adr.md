

⸻

Agent Sessions – Loading & Indexing Architecture Refactor

0. Scope & Principles

This document is about loading, indexing, and presenting sessions efficiently.
The goals:
	•	Make the app feel fast and predictable on large corpora.
	•	Avoid “blank screen” / “stuck spinner” / “trapped selection” states.
	•	Do this with minimal UI changes and localized code changes.

Important constraints for any implementation agent:
	•	Do not introduce new visual features, redesign the layout, or add fancy UI components.
Only allow:
	•	Small diagnostic labels or banners where explicitly described.
	•	Behavior fixes for selection, search, and filters.
	•	Do not change targets, bundle IDs, or app settings.
	•	Any concurrency change must be deterministic and bounded (no “spawn 1000 tasks” nonsense).

⸻

1. Current Loading / Indexing Model (Conceptual)

1.1 Main Data Flow (Today)

Roughly, the app works like this:

Disk JSONL logs
  │
  ▼
SessionDiscovery
  │ (per source: Codex / Claude / Gemini)
  ▼
[Per-source SessionIndexer]
  - Scan directories
  - Parse rollout-*.jsonl
  - Build SessionMeta / Session models
  - Optionally warm transcript cache
  - Optionally update analytics
  │
  ▼
UnifiedSessionIndexer
  - Orchestrates all sources
  - Refresh = Codex → Claude → Gemini (sequential)
  - Builds unified list
  │
  ▼
UnifiedSessionsView (SwiftUI Table)
  - Shows unified.sessions
  - BUT: if SearchCoordinator is running / has results,
    table uses search results instead

1.2 Search Path (Today)

User types search
  ▼
SearchCoordinator.start()
  - Take "allowed sessions" list (after filters)
  - Split into:
      nonLarge (< ~10MB)
      large   (>= ~10MB)
  - Process 100% of nonLarge first
  - Then process large
  - Throttle UI updates to ~10Hz
  - When FeatureFlags.lowerQoSForHeavyWork == true:
      sleep(10ms) in each large-queue iteration
  ▼
searchCoordinator.results
  ▼
UnifiedSessionsView
  - If search is running or results not empty:
      table data source = search results
  - Else:
      table data source = unified.sessions

1.3 Selection & Reload (Today)

User selects a session row
  ▼
SessionIndexer.reloadSession(id)
  - Single global background queue
  - A lock / guard:
      only one loadingSessionID
      isLoadingSession = true while any reload in progress
  - Any additional selections queue up
  ▼
UnifiedSessionsView
  - Table selection forced non-empty
  - Clicking whitespace re-selects previous row
  - If current row is slow to reload, user is effectively stuck on it

1.4 Transcript Cache & Analytics (Today)

On refresh:
  - TranscriptCache.generateAndCache(all sessions)
      - Iterates over entire sorted session list
      - Checks cache, sleeps periodically, yields to MainActor
      - Always O(N) over all sessions
  - AnalyticsIndexer may purge / rebuild analytics tables
      as part of the same refresh path

1.5 Filters & “Zero Rows” (Today)
	•	Filters include:
	•	Project filter
	•	Favorites-only
	•	Hide zero-message / low-message sessions
	•	Hide probe sessions
	•	These are persisted (e.g. via @AppStorage).
	•	It is possible to create a combination where every session is filtered out.
	•	When that happens:
	•	A warning is logged in the console.
	•	The UI still shows an empty table with no clear explanation.
	•	On next launch, the same filters are reapplied → still zero rows.

⸻

2. Proposed Loading / Indexing Model

The target architecture separates fast, lightweight hydration from heavy background processing and ensures per-source concurrency.

2.1 New High-Level Flow

Disk JSONL logs
  │
  ▼
SessionDiscovery
  │
  ▼
SessionMetaRepository / DB
  (per source)
  │
  ├─ Stage 1: Fast hydration
  │    - Read metadata (id, timestamps, project, counts)
  │    - Build lightweight Session rows
  │    - Publish to UnifiedSessionIndexer & UI asap
  │
  └─ Stage 2: Background enrichment
       - TranscriptCache: only for new/changed sessions
       - AnalyticsIndexer: aggregates, charts, etc.
       - Deep search index (if needed)
       (none of these block Stage 1)

2.2 Per-Source Indexing

UnifiedSessionIndexer.refreshAllSources()
  ├─ Task A: CodexSessionIndexer.refresh()
  ├─ Task B: ClaudeSessionIndexer.refresh()
  └─ Task C: GeminiSessionIndexer.refresh()
   (run concurrently, but each source internally serial)

As each source finishes Stage 1:
  - Publish its sessions to the unified model
  - UI updates immediately

2.3 Search Behavior (Proposed)
	•	Metadata-first search:
	•	Start by searching session metadata in memory or in a small DB.
	•	This is cheap and returns first results quickly.
	•	Streaming / incremental results:
	•	As soon as you have any hits, push them to searchResults.
	•	Do not wait for the full corpus to be scanned.
	•	Deep transcript search (optional):
	•	If needed, scan transcripts gradually (using cache) and append hits.
	•	Runs in the background; UI stays responsive.
	•	Safe list mode:
	•	If search query is empty → always show unified sessions.
	•	Leftover search flags must never blank the main list.

2.4 Selection & Reload (Proposed)
	•	Allow empty selection in the table.
	•	Replace the single loadingSessionID with a small pool:
	•	Up to N (e.g. 2–4) concurrent reloads within SessionIndexer.
	•	Each session’s reload is a separate Task.
	•	The detail pane:
	•	Shows existing cached data immediately if available.
	•	Shows a row-local ‘loading’ indicator only for that one session.
	•	The table selection:
	•	Clicking whitespace clears selection (no forced reselection).
	•	User can always escape a problematic row.

2.5 Transcript Cache & Analytics (Proposed)
	•	Delta-based prewarm:
	•	Compute which sessions are new or changed based on (id, file size, modification date) or a checksum.
	•	Run generateAndCache only on that set, not on every session.
	•	Priority:
	1.	Currently selected session.
	2.	Visible rows.
	3.	Recently accessed sessions.
	4.	Everything else in the background, in small batches.
	•	Analytics:
	•	Runs after UI hydration.
	•	Never blocks the main table; results appear when ready.

2.6 Filters & Zero-State (Proposed)
	•	Keep the existing filter prefs, but:
	•	Add a small diagnostics summary:
	•	totalSessions, visibleSessions, filteredByZeroMessages, filteredByProbes, etc.
	•	In the UI:
	•	If totalSessions > 0 && visibleSessions == 0:
	•	Show a clear message: “Filters are hiding all sessions.”
	•	Provide an explicit “Show all sessions” button that resets dangerous filters.
	•	On launch:
	•	If the last run ended in “filters hide everything” state, start with a safe preset (e.g. show all).

⸻

3. Bottlenecks & Fixes – Architectural Overview

Area	Current Problem	Fix Strategy
Refresh & Hydration	Everything (scan, transcripts, analytics) runs in one monolithic path. Long periods of “nothing”.	Split into Stage 1 (fast metadata hydration) and Stage 2 (background enrichment).
Per-source Indexing	Codex fully completes, then Claude, then Gemini. Others look broken while Codex is slow.	Run Codex / Claude / Gemini indexers in parallel; each publishes independently.
Search Pipeline	Full walk over nonLarge, then large; throttled; leftover state can blank UI.	Metadata-first search, streaming results, safe browsing vs search mode, no leftover blanking.
Transcript Cache	O(N) prewarm over all sessions each refresh, with sleeps and yields.	Delta-based prewarm; prioritize hot sessions; small background chunks.
Reload Concurrency	Single reload lane; selecting a slow session locks everything; selection can’t be empty.	Small pool of concurrent reloads; allow empty selection; per-row loading state only.
Filters & Zero Rows	Filters can hide everything silently; persisted across launches.	Diagnostics summary + visible banner; “Show all sessions” escape; safe defaults on launch.
Analytics	May purge/rebuild as part of refresh; slows first useful view.	Run analytics after Stage 1; never block main table hydration.
Feature Flags	Flags like lowerQoSForHeavyWork add sleeps that may worsen performance; coalescing can be off.	Flags should tune batch size and priority, not add arbitrary sleeps; coalescing always on in prod.


⸻

4. Code Guidelines for Any Implementation

These are rules you should give to any coding model or follow yourself.

4.1 General Behavioral Rules
	1.	No surprise UI changes
	•	Do not alter visual hierarchy, add new heavy views, or redesign the UnifiedSessionsView.
	•	Small text labels or simple banners for diagnostics are ok, but only as described.
	2.	Preserve existing preferences and semantics
	•	hideZeroMessage / probe filters must keep their current meaning.
	•	Do not change what is considered a “probe”, “lightweight session”, etc.
	3.	Backwards compatibility
	•	No migrations that break existing DB / index unless strictly necessary.
	•	If you add new fields (e.g. hashes), make them optional and robust to missing data.

4.2 Concurrency & Performance
	1.	One serial actor/queue per source
	•	Codex indexer, Claude indexer, Gemini indexer each maintain an internal serial actor or queue for disk IO and DB writes.
	•	UnifiedSessionIndexer orchestrates these concurrently, but doesn’t bypass their serialization.
	2.	UI updates only from main actor
	•	All @Published properties that drive SwiftUI must be updated on the main actor.
	•	Use @MainActor where appropriate.
	3.	No unbounded Task spawning
	•	Any concurrency should be bounded:
	•	e.g. at most N reloads in parallel.
	•	Avoid Task storms over thousands of sessions.
	4.	No arbitrary sleeps unless absolutely necessary
	•	Replace Task.sleep(10_000_000) patterns with:
	•	batch processing + yielding to main actor, or
	•	relying on task priorities and chunk sizes.
	•	If you must throttle, do it via batch size and explicit yields, not blind sleep loops.

4.3 Structure & Testability
	1.	Keep heavy logic out of SwiftUI views
	•	Views should consume view models and publish state.
	•	Indexing / searching / caching logic should live in services.
	2.	Keep new behavior localized
	•	If you change refresh behavior, keep it in UnifiedSessionIndexer and per-source indexers.
	•	If you change selection behavior, keep it in UnifiedSessionsView and maybe SessionIndexer.
	3.	Add minimal, explicit diagnostics
	•	For perf debugging:
	•	Add minimal logging or os_signpost around:
	•	refresh start/end
	•	search start/end
	•	transcript prewarm loops
	•	but keep it lightweight and compile-time guarded if needed.

⸻

5. Step-by-Step Plan (with Tests After Each Step)

The idea: small, reversible steps with concrete tests.

Step 1 – Instrumentation & Baseline

What to change
	•	Add minimal timing/instrumentation to:
	•	UnifiedSessionIndexer.refresh (start, end, per-source durations).
	•	SessionIndexer.refresh (Stage 1 vs Stage 2).
	•	SearchCoordinator.start (time to first hit, time to completion).
	•	TranscriptCache.generateAndCache (total sessions processed, time).
	•	Use either:
	•	Lightweight logging with print or a small logger, or
	•	os_signpost if you already use it.
	•	Do not change behavior yet. Only add measurement.

How to test
	1.	Start the app with a large corpus.
	2.	Measure (with logs or Instruments):
	•	Time from launch to first rows visible in the main table.
	•	Time from pressing Refresh to first rows visible.
	•	CPU/I/O during the first 30–60 seconds.
	3.	Run a search:
	•	Measure time from keystroke to first visible result.
	4.	Record these numbers somewhere.
These are your baseline metrics to compare later steps.

⸻

Step 2 – Fast Hydration Path (Stage 1 vs Stage 2)

What to change
	•	In per-source SessionIndexer (Codex/Claude/Gemini):
	•	Identify the minimal “metadata” subset you need to show a row:
	•	id, file path, timestamps, project, basic counts.
	•	Implement Stage 1:
	•	Load metadata from SessionMetaRepository / DB (or quickly parse header of JSONL if needed).
	•	Build lightweight Session rows.
	•	Publish to allSessions / unified model as soon as possible.
	•	Implement Stage 2:
	•	Transcript prewarm (still full for now; delta comes later).
	•	Analytics updates.
	•	Any heavy operations.
	•	In UnifiedSessionIndexer.refresh:
	•	Trigger Stage 1 for all sources (Codex/Claude/Gemini).
	•	UI should display rows as soon as Stage 1 per-source is done.
	•	Stage 2 work must not block Stage 1 completion.

How to test
	1.	Repeat the baseline tests:
	•	Time from launch to first visible rows.
	•	Time from Refresh to first visible rows.
	2.	Compare to baseline:
	•	You should see “first useful paint” significantly earlier, even if background work still runs.
	3.	Confirm:
	•	While Stage 2 (transcripts/analytics) runs, the table remains scrollable and usable.
	•	No crashes from updating @Published properties off main actor.

⸻

Step 3 – Per-Source Parallel Refresh

What to change
	•	In UnifiedSessionIndexer.refresh:
	•	Instead of refreshing Codex → Claude → Gemini sequentially:
	•	Use withTaskGroup or equivalent to refresh three sources in parallel.
	•	Each source still uses its own serial queue/actor internally.
	•	As each source completes Stage 1:
	•	Publish its sessions to the unified model.
	•	UI should show those sessions immediately, even if other sources are still loading.

How to test
	1.	Use a corpus where:
	•	Codex has many sessions (slow).
	•	Claude has just a few (fast).
	2.	Run Refresh.
	3.	Confirm:
	•	Claude sessions appear quickly in the UI while Codex is still indexing.
	•	Gemini, if present, behaves similarly.
	4.	Verify:
	•	No cross-source data races (wrong sessions in wrong tabs).
	•	No deadlocks / stuck spinners.

⸻

Step 4 – Search Safe Mode & Browsing/Search Modes

What to change
	•	In UnifiedSessionsView:
	•	Introduce a simple enum ListMode { case browsing, searching }.
	•	Drive it strictly from:
	•	Search query string:
	•	If query is empty → listMode = .browsing.
	•	If query is non-empty → listMode = .searching.
	•	Data source rule:
	•	browsing → use unified sessions.
	•	searching → use searchResults.
	•	Remove any logic like:
	•	if searchCoordinator.isRunning || !results.isEmpty { use searchResults } else { unified }.
	•	Do not change the deep search algorithm yet. Only how the view decides what to show.

How to test
	1.	Hydrate with a known corpus.
	2.	Type a search term that yields results.
	3.	Clear the search field completely.
	4.	Confirm:
	•	The unified sessions list reappears every time.
	•	Leftover search state does not keep the table empty.
	5.	Quit and relaunch:
	•	Confirm that an empty search field always shows the unified list, never a blank search results state.

⸻

Step 5 – Filters Diagnostics & “Show All” Escape

What to change
	•	In SessionIndexer:
	•	Add a SessionFilterDiagnostics struct and @Published var filterDiagnostics: SessionFilterDiagnostics?.
	•	Compute:
	•	totalSessions = count before filters.
	•	visibleSessions = count after filters.
	•	Optionally counts for each filter dimension (zero messages, probes, favorites, project).
	•	Set filterDiagnostics after each refresh.
	•	In UnifiedSessionsView:
	•	Read filterDiagnostics.
	•	If totalSessions > 0 && visibleSessions == 0:
	•	Display a small banner (Text + Button) above the table:
	•	“Filters are hiding all sessions.”
	•	Button: “Show all sessions”.
	•	“Show all sessions” implementation:
	•	Programmatically relax filters (e.g. uncheck hide-zero / hide-probes, turn off favorites-only).
	•	Trigger a small refresh / recomputation of filtered rows.
	•	Keep the banner logic minimal and non-invasive.

How to test
	1.	Load a corpus with known sessions.
	2.	Manually activate filters so no sessions are visible:
	•	Hide zero-message, hide probes, favorites-only with no favorites, etc.
	3.	Confirm:
	•	Banner appears saying filters are hiding everything.
	•	“Show all sessions” resets filters to a state where rows are visible again.
	4.	Quit and relaunch:
	•	Confirm the app doesn’t come up stuck in a “zero visible rows” state with no escape (thanks to the button).

⸻

Step 6 – Transcript Cache Delta-Only & Priority

What to change
	•	In SessionMetaRepository / DB:
	•	Store enough information to detect changes:
	•	File size and modification timestamp per session (and/or a simple hash).
	•	In TranscriptCache.generateAndCache:
	•	Accept a subset of sessions to prewarm.
	•	Compute diff:
	•	Sessions that are new or have changed and don’t already have a cached transcript.
	•	Only prewarm this subset.
	•	Prioritize:
	1.	Selected session(s).
	2.	Visible rows (use an approximation, like top N sessions).
	3.	Recently accessed sessions.
	4.	Everything else (optional, small batches).
	•	Remove global O(N) loops over all sessions on every refresh.

How to test
	1.	With a large corpus:
	•	Measure time spent in generateAndCache before and after.
	2.	Refresh:
	•	Confirm the time to first rows is unchanged or better.
	•	Ensure the main thread remains responsive during transcript prewarm.
	3.	Open several sessions:
	•	Confirm transcripts appear correctly and are cached.
	•	No missing or stale transcripts after file changes.

⸻

Step 7 – Reload Concurrency & Selection Escape

What to change
	•	In SessionIndexer:
	•	Replace single loadingSessionID and isLoadingSession with:
	•	Set<SessionID> or small pool of active reloads (up to N).
	•	Each reload request:
	•	If the session is already in the active set, ignore the duplicate.
	•	Otherwise, spawn a Task that loads data and then removes itself from the active set.
	•	In UnifiedSessionsView:
	•	Allow the table selection to be empty.
	•	Clicking whitespace clears selection.
	•	Optionally show a minor per-row loading indicator when that row is being reloaded.

How to test
	1.	Quickly click through many sessions in the table (including large ones).
	2.	Confirm:
	•	UI remains responsive; selection updates as expected.
	•	Detail view doesn’t freeze entirely on one session.
	3.	Click whitespace:
	•	Selection becomes empty.
	•	App does not auto-select a row again.
	4.	No crashes/asserts due to concurrency in reload logic.

⸻

After these 7 steps, you should have:
	•	Fast, incremental loading.
	•	Per-source parallel refresh.
	•	Non-destructive search.
	•	Visible and recoverable filter states.
	•	Smarter transcript prewarming.
	•	Non-blocking selection/reload behavior.

And you can implement all of it without redoing the UI or changing what a “session” means.