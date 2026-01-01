# Refactor Roadmap (maintainability, scale, and speed)

This is a plan, not code.

## Why refactor now (what the code is telling you)

You have a classic “successful prototype that became a product” situation:
- You already support many agents.
- You already ship releases.
- You already have performance workarounds (feature flags, throttling, transcript caching).

The cost you are paying (and will pay harder) is duplication and coupling.

### Observable duplication (examples)

Per-agent indexers repeat the same concepts:
- Progress throttler type (copied into almost every indexer)
- Similar `@Published` state surfaces (allSessions, sessions, isIndexing, progressText, etc.)
- Similar Combine filter pipelines
- Similar refresh patterns (enumerate files, parse, sort, merge archives, prewarm transcripts)

Evidence files:
- `AgentSessions/Services/SessionIndexer.swift` (Codex)
- `AgentSessions/Services/ClaudeSessionIndexer.swift`
- `AgentSessions/Services/GeminiSessionIndexer.swift`
- `AgentSessions/Services/OpenCodeSessionIndexer.swift`
- `AgentSessions/Services/CopilotSessionIndexer.swift`
- `AgentSessions/Services/DroidSessionIndexer.swift`

Search is coupled to “all indexers exist”:
- `AgentSessions/Search/SearchCoordinator.swift` depends on every indexer type to access caches and to parse “full” sessions.

UI files are carrying too much orchestration:
- `AgentSessions/Views/UnifiedSessionsView.swift` is both view and coordinator for selection, search, lazy loading, strip UI, focus coordination, agent enablement.
- `AgentSessions/Views/TranscriptPlainView.swift` is very large and mixes UI, rendering decisions, selection management, find, and AppKit bridging.

### The real risk
The risk is not “code style”. The risk is:
- Every new agent format change becomes a multi-file hunt.
- Every new feature requires touching view + multiple indexers + search coordinator.
- Bugs appear as “state drift” between per-agent sources and the unified view.

## Refactor goals (definition of “done”)

1) Add a new agent in 1–2 days, not 1–2 weeks
- New agent support should not require copying an entire indexer class.
- Parsing, discovery, indexing, and transcript building should be composable pieces.

2) Search and filtering must scale to:
- 10,000+ messages per session
- thousands of sessions across agents
- without “build entire transcript for everything” as the primary mechanism

3) UI files become boring again
- Views should mostly render state and route user intents.
- Coordination belongs in view models/services, not 1,000–2,000 line SwiftUI files.

4) Concurrency becomes understandable
- Reduce “GCD + Combine + Task + semaphore” hybrids.
- Use one consistent approach for background work and MainActor updates.

## Target architecture (high-level)

Think in three layers:

1) Core (pure-ish, test-heavy)
- Session model + normalized event model
- Per-agent parsers (light and full)
- Indexing orchestration (filesystem + DB)
- Search engine (FTS + metadata filters + optional transcript fallback)
- Transcript renderer

2) App services (Mac-specific integration)
- Launchers (Terminal/iTerm)
- Probes (tmux capture scripts) behind explicit user actions
- Update checks

3) UI
- Views + small view models
- One source-of-truth session store injected into views

Concrete: carve out a Swift package target `AgentSessionsCore` and migrate logic into it incrementally.

## Key abstraction: AgentAdapter

Define one adapter per agent/provider with a narrow surface:

- Identity:
  - `source` (Codex/Claude/etc.)
  - display name and branding (UI-only concerns optional)

- Discovery:
  - “where do sessions live?”
  - “what files represent sessions?”

- Parsing:
  - lightweight parse (metadata-first)
  - full parse (events)

- Optional capabilities:
  - resume launcher support (Terminal/iTerm)
  - usage tracking support
  - archive semantics (if any differ)

Everything else (filtering, sorting, caching, prewarm) becomes shared.

## Stepwise plan (incremental, low-risk)

### Phase 0: Baseline and guardrails (1–3 days)

Purpose: refactor without breaking user-visible behavior.

- Document invariants you will not break:
  - Session identity stability across launches (ID derivation rules)
  - “Lightweight sessions” behavior (events empty until opened)
  - Sorting and filtering semantics
  - Search correctness (especially across large sessions)
- Add missing “golden fixtures” per agent parser:
  - small session
  - large session
  - schema drift example
  - edge timestamps and multi-line tool output
- Add one performance benchmark harness (even minimal):
  - parse N files
  - search query over corpus
  - open a 10k-message session transcript

You already have tests; extend them in the same style.

### Phase 1: Consolidate shared primitives (2–5 days)

Purpose: stop copying the same helper classes.

Targets:
- Replace duplicated `ProgressThrottler` with a single shared type.
- Centralize “dateEq” logic and other repeated utilities.
- Extract `FilterEngine` out of `AgentSessions/Model/Session.swift` into a dedicated file and module.
- Convert `TranscriptCache` from `NSLock` + “MainActor runs lock” patterns into a clearly owned concurrency model (actor is the simplest).

Outcome:
- No behavior change, but duplication shrinks.

### Phase 2: Introduce a shared Indexer core (5–10 days)

Purpose: remove per-agent indexer duplication.

Design:
- One generic “indexer engine” that:
  - hydrates from DB if available
  - scans filesystem
  - maintains `allSessions` + `sessions` (filtered view)
  - handles lazy full parsing on selection
  - optionally prewarms transcripts (bounded, cancelable)

Each agent provides only:
- how to discover files
- how to parse lightweight/full
- any special metadata extraction quirks

Migration approach:
- Do not rewrite everything at once.
- Start with one “simpler” agent (OpenCode or Gemini) and migrate to the shared indexer.
- Keep the old indexer temporarily, compare outputs in debug builds, then delete the old implementation.

Definition of done:
- At least 2 agent indexers use the shared core.
- Adding a third is mostly wiring, not rewriting.

### Phase 3: Decouple SearchCoordinator from concrete indexers (3–6 days)

Purpose: search should not know about each agent class.

Replace:
- `SearchCoordinator(codexIndexer:…, claudeIndexer:…, …)`

With:
- `SearchCoordinator(sessionStore: SessionStore)` or `SearchCoordinator(searchService: SearchService)`

That service should expose:
- fetch candidates (metadata only)
- parse full session on-demand
- access searchable text (prefer DB/FTS, fall back to transcript)

This makes “add new agent” not require edits in SearchCoordinator.

### Phase 4: Make SQLite the search backbone (FTS) (5–14 days, can be parallel)

You already have SQLite (`AgentSessions/Indexing/DB.swift`) and `session_meta`.
Next step: add a dedicated search table:
- Normalize and store “search text” per session (or per event chunk) and index it with FTS.
- Update incrementally by file mtime/size (you already track these in `files`).

Benefits:
- Drastically lower CPU and memory pressure vs. transcript prewarm
- “Instant search” even for 10k-message sessions
- You can do fast prefiltering by repo/time/model without parsing full files

Keep transcript rendering separate:
- You still need to parse full sessions when opening the transcript view, but search should not require it.

### Phase 5: UI decomposition (ongoing, 1–2 weeks)

Goal: reduce mega-file views and improve testability.

Targets:
- Split `UnifiedSessionsView` into:
  - a view model (selection, lazy load, search restarts, focus coordination)
  - small views (toolbar, strips, table)
- Split `TranscriptPlainView` into:
  - rendering pipeline (string/attributed building)
  - view (AppKit bridging)
  - find/highlight controller

Definition of done:
- The “main view” files stop being the only place where behavior lives.
- Most logic moves into testable types.

## Cross-cutting: performance and reliability for very long sessions

These are requirements, not optional polish:

- Chunked transcript rendering and incremental display updates
- Aggressive cancellation for any background work when the user is typing/searching
- Avoid unbounded in-memory caches (use LRU or DB-backed caches)
- No “full parse everything” by default; do metadata-first + on-demand

You already started this direction (feature flags and throttling). The refactor should turn that into architecture, not toggles.

## Risk register (be honest)

- “Big-bang refactor” risk: UI regressions and broken edge-case parsing. Mitigation: phased migration + golden fixtures.
- Xcode project churn: moving files/targets can break builds. Mitigation: small moves, always keep CI green.
- Feature creep during refactor: it is tempting to redesign everything. Mitigation: explicit non-goals.

## Non-goals (what not to do during refactor)

- Do not build a full “Crystal/Claude Squad” clone inside Agent Sessions.
- Do not add embeddings/cloud sync until the local search and memory model is excellent.
- Do not invent an elaborate plugin system before the adapter boundary exists.

## Deliverable checklist (what future-you will thank you for)

- A documented “Add new agent” checklist
- A single shared indexer core
- Search service that does not depend on concrete indexer classes
- SQLite-backed search (FTS) that makes scale boring
- Smaller, testable view models instead of mega-view orchestration

## Appendix A: what you already have (and why it matters)

This repo already contains the beginnings of the right architecture. The issue is duplication and “two pipelines”.

### Existing DB schema and hydration

You already have:
- An SQLite actor wrapper and schema in `AgentSessions/Indexing/DB.swift`
  - `files` (path, mtime, size, source, indexed_at)
  - `session_meta` (session_id, source, path, time bounds, model, cwd/repo/title, messages, commands)
  - `session_days` and `rollups_daily` (analytics rollups)
- A DB-to-UI hydration adapter in `AgentSessions/Indexing/SessionMetaRepository.swift`
- UI indexers that try to hydrate from `session_meta` before scanning the filesystem, then scan for “new files” not seen by DB
  - Codex example: `AgentSessions/Services/SessionIndexer.swift`
  - Claude example: `AgentSessions/Services/ClaudeSessionIndexer.swift`

This is good: it’s the foundation for instant startup and scalable search.

### Existing background indexer (and the duplication)

You also have `AgentSessions/Indexing/AnalyticsIndexer.swift`, which:
- enumerates files for each source
- parses sessions fully
- writes `files`, `session_meta`, and day rollups

But there are two important problems to solve in the refactor:

1) Two pipelines parse the world
- The per-agent UI indexers parse (lightweight now, full on selection/search).
- The analytics indexer parses again to populate the DB.

2) The analytics parser call graph is not “core-first”
- For Codex, it instantiates `SessionIndexer()` just to call its parsing (`AnalyticsIndexer.parseSession`).
- This couples analytics to UI state and makes it harder to extract a clean core module.

Refactor implication:
- Make “parsing” a core library concern (pure-ish), and make both UI and analytics call that core.
- Decide whether “the DB indexer” becomes the primary pipeline and UI becomes mostly a DB reader, or whether UI remains primary and DB is derived. Right now you are doing both.

## Appendix B: SQLite FTS search proposal (concrete, implementable)

If you want “thousands of sessions” to feel instant, you need to stop relying on transcript prewarm as the primary search mechanism.

### Proposed schema (example)

Add a searchable text table plus FTS index:

```sql
CREATE TABLE IF NOT EXISTS session_text (
  session_id TEXT NOT NULL,
  source TEXT NOT NULL,
  mtime INTEGER NOT NULL,
  size INTEGER NOT NULL,
  text TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(session_id, source)
);

CREATE VIRTUAL TABLE IF NOT EXISTS session_text_fts
USING fts5(text, content='session_text', content_rowid='rowid');
```

Then update `session_text` whenever a file changes (using your existing `files` table as the guard), and rebuild the FTS row for that session.

### What goes into “text”

Do not store the full transcript as-is. Store a normalized search body that is:
- user prompts (high value)
- assistant messages (high value)
- tool names and commands (high value)
- selected tool outputs (bounded, and possibly truncated)
- extracted metadata (repo, cwd, model, title)

You can keep full transcripts for display, but search text should be optimized for speed and memory.

### Expected product wins

- Search does not need to fully parse large sessions.
- Search is stable and fast regardless of session size.
- You can add new filters cheaply (date/model/repo) because metadata is in `session_meta`.

## Appendix C: proposed module/target layout (future-dev friendly)

This is the cleanest path to long-term velocity:

1) `AgentSessionsCore` (Swift package)
- Models: SessionSummary/SessionDetail/SessionEvent
- Parsers: one per agent, behind an adapter protocol
- Indexing: DB + filesystem, incremental
- Search: metadata filters + FTS
- Transcript rendering: plain/ANSI/attributed builders

2) `AgentSessions` (macOS app target)
- SwiftUI views
- AppKit bridging (text view, selection)
- Preferences UI

3) Optional: `agentsessions` CLI (cross-platform)
- Export context packs
- Export HTML/Markdown reports
- Useful for Linux/Windows users and as a growth channel

Even if you never ship the CLI, this separation makes the app safer and easier to test.

## Appendix D: “Add a new agent” checklist (after refactor)

The goal is that “new agent support” becomes a checklist, not a rewrite.

1) Implement `AgentAdapter` for the new agent
- discovery (where files live, how to enumerate)
- lightweight parse (metadata only)
- full parse (events)

2) Add fixtures and tests
- at least one “small” and one “large” sample
- a schema drift sample if the tool is known to change formats

3) Register the adapter
- add to an agent registry (single list)
- ensure enablement toggles exist (Preferences)

4) Ensure DB indexing supports it
- write `session_meta`
- write `session_text` search body (FTS)

5) Wire UI affordances
- source filter in toolbar
- icon/label (optional)
- resume integration if supported

## Appendix E: performance plan for 10k+ message sessions (make it boring)

The current approach (single large text view + big strings) can be made to work, but it becomes fragile as sessions grow.
Treat “very large sessions” as a first-class product case, not an edge case.

### Problem 1: rendering a giant monolithic string
Risk factors:
- huge allocations
- highlight ranges and attributed styling get expensive
- scrolling and selection work becomes O(n) in worst cases

Architecture options (in order of long-term robustness):

1) Block-based transcript rendering (recommended)
- Represent the transcript as a list of blocks (user, assistant, tool call, tool output, error).
- Render as a virtualized list (SwiftUI `List` or AppKit list) with per-block views.
- Only render what is visible; keep raw text separately.

2) Chunked text storage for NSTextView
- Keep NSTextView, but store text in chunks and append incrementally.
- Make find/highlight operate on chunk boundaries (avoid rescanning everything).

3) “External viewer” fallback
- For extremely large sessions, offer a one-click export/open in an external editor.
- This is a reliability escape hatch and reduces support burden.

### Problem 2: search should not require transcript generation
This is where the SQLite FTS plan matters:
- searching should operate on `session_text_fts` or metadata, not on fully rendered transcripts
- transcript generation is for display, not filtering

### Problem 3: caches must be bounded
Transcript caches should have:
- a size cap (LRU)
- a “drop on memory pressure” path
- preferably a disk-backed option for very large corpora

### Problem 4: incremental indexing and file watching
If you want the app to feel alive without burning CPU:
- add filesystem watching (FSEvents) per provider root
- index incrementally using the `files` table guard (mtime/size)
- debounce updates while the user is typing/searching

The goal is to eliminate “full rescans” as the default mental model.
