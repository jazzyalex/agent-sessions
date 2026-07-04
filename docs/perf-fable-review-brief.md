# Architecture Review Brief — "Make Agent Sessions Instant" (for a fresh senior reviewer)

> **Your role.** You are a senior macOS/Swift performance architect doing an independent design review. Everything below is context so you can spend your effort **thinking**, not gathering. I (the implementing engineer) have a working plan and have shipped part of it; **I want you to pressure-test the whole approach and, if warranted, propose a fundamentally different architecture.** Do not just validate my plan. Assume I may be over-fitted to a local optimum. Concrete, opinionated redesigns welcome — even ones that throw away work already done, if they'd be materially better.

---

## 1. Product & mission

**Agent Sessions** is a local-first macOS app (SwiftUI + AppKit, single-process, no server) that indexes and browses AI-coding-agent session transcripts on disk (Codex, Claude Code, OpenCode, Cursor, Antigravity, Copilot CLI, etc.). Two dominant surfaces:

1. **The session list** — a `SwiftUI Table` of 3,000–40,000+ sessions (rows are lightweight `Session` structs; events lazy-loaded). Sortable columns, filters, live "active session" dots, subagent hierarchy (parent/child rows).
2. **The transcript view** — opens when you select a session. Default mode is a **terminal renderer**: a **single `NSTextView`** into which the whole session's events are coalesced → lines → one big `NSAttributedString`. Worst case: **619k lines / ~200 MB / ~30 s to open**.

**Mission:** every action feels **instant** — select a session, type in search, get results, sort, scroll, and while idle — at 3,000–40,000 sessions and multi-hundred-MB transcripts. Target budgets: sort < ~100 ms; search results < ~100 ms; select→first transcript content < 150 ms; idle returns to near-zero CPU/energy.

**Environment:** macOS 15.x, Apple Silicon, Swift 5, XCTest. Single app target `AgentSessions`, test target `AgentSessionsTests` (~1000 tests). Everything ships behind compile-time `FeatureFlags` (default off) and is parity-gated.

---

## 2. The four problems (all profiled, not guessed)

Profiling method that works here: `sample <pid> 30` **during a reproduced freeze**, plus a self-driving DEBUG bench harness (`AS_PERF_BENCH=<action>` drives the action on a timer; a `MainThreadStallMonitor` logs `[perf][STALL] main thread blocked ~Nms`; `Perf.begin/end` os_signpost spans). Short samples miss freezes (main idle in `mach_msg2_trap`) — you must sample *during* the stall.

### Problem A — Session-list SORT beachball. **SOLVED (shipped, measured).**
- **Symptom:** clicking a sort-column header froze the main thread **6.5–7.3 s** at ~3,300 rows.
- **Root cause (proven):** `sample` showed **16,097 / 20,208 main-thread samples (~80%)** in SwiftUI `Table`'s reorder-diff: `Update.dispatchActions → UpdateAppKitOutlineTableCoordinator.updateValue → AppKitOutlineTableCoordinator.update(…diffRows…) → RangeReplaceableCollection.remove(atOffsets:) → MutableCollection.halfStablePartitionByOffset → move(fromOffsets:toOffset:)` over `IndexSet` slices. This is **O(n²) in the number of moved rows**. My own `updateCachedRows` CPU was only ~100–150 ms — a red herring that had defeated every prior fix.
- **Fix:** when `cachedRows` is reassigned as a *wholesale reorder* (same id-set, ≥128 moved rows), bump a `tableReorderGeneration` fed into the `Table`'s `.id(...)`, forcing SwiftUI to **rebuild** the table (O(n)) instead of **diffing** the reorder (O(n²)). Small/incidental reorders fall through to SwiftUI's cheap diff (preserves scroll). Result: **~0.5 s** per sort, no residual multi-second stalls. Tradeoff: a big sort resets scroll to top (rebuild). `UnifiedSessionsView.swift`: `UnifiedTableIdentityPolicy.isLargeReorder`, `tableReorderGeneration`.
- **Residual (~0.5 s → target ~0.2 s):** 2× `updateCachedRows` per sort (~230 ms; the first is redundant), an O(n) table rebuild (~200 ms), `SubagentHierarchyBuilder.build` (~60–90 ms, does `URL(fileURLWithPath:)` per top-level session), HUD rebuild (~40 ms). **Open question for you:** is there a way to sort 3,300+ rows in a SwiftUI/AppKit list that's both O(n) *and* preserves scroll position, without dropping to a hand-rolled `NSTableView` datasource? Is the SwiftUI `Table` the wrong tool at this scale?

### Problem B — Transcript OPEN. **IN PROGRESS (this is the big one; see §3–§4).**
- **Profiled cost breakdown of opening a *hydrated* session:**
  | Stage | What | Cost |
  |---|---|---|
  | Model build | `SessionTranscriptBuilder.coalescedBlocks` + `TerminalBuilder.buildLines` | **~90% of open; 926 ms @ 5.7k lines; 30,653 ms @ 619k lines** |
  | Attr build | `buildAttributedString` | 10–40 ms @ 100k chars |
  | Set + layout | `setAttributedString` + TextKit | 20–50 ms @ 100k chars |
- **Key finding:** the whole-session **model build** dominates; the single `NSTextView`'s attr-build + TextKit layout are cheap. The build already runs off-main (`Task.detached(.userInitiated)` in `TranscriptPlainView.rebuild`), so it's **latency, not a main-thread freeze** — but 30 s to content is unacceptable.
- **Separate cold-parse wall:** selecting a session whose events aren't in memory calls `reloadSession` → **`parseFileFull` parses the *entire* file before any events exist** (`SessionIndexer.swift`). The 30 s build number is measured *after* hydration; the parse is additional and unwindowed. There's a **Phase-1 guardrail** (shipped): above a size/message threshold, auto-hydration is gated behind a "Show full transcript" affordance so a monster session can't hang the app.

### Problem C — Idle CPU / "Using Significant Energy."
- Live-session polling: `CodexActiveSessionsModel` is `@MainActor`; its poll loop (`refreshOnce`, every ~2 s foreground) does registry disk reads (`loadPresences`), ps/lsof/AppleScript output parsing, merge/dedup/classify **on the main actor** (no `Task.detached` anywhere; only the process *wait* hops off via `withCheckedContinuation`). For this user's state it's cheap (~2 active presences ⇒ `refreshPublish` ~8 ms), but the **Cockpit HUD rebuild** (`AgentCockpitHUDDerivedStateModel.rebuildIfReady` → `makeRowsSnapshot`) fires ~**35 ms every poll tick** (same-runloop coalesce only, no time-debounce). That steady ~35 ms/2 s is the visible idle-energy driver.
- Publishing is already well-guarded: `activeMembershipVersion` bumps only on real membership/live-state/metadata change (not every tick). I added a "cheap path": on a live-dot tick with Active-only filtering off, only the fallback-presence map is rebuilt (~13 ms) instead of the full 3,300-row `updateCachedRows`.

### Problem D — Search.
- The FTS (`session_search`) corpus is **empty** — the ingest was removed in a prior commit, so every search runs a **legacy linear scan**. A two-tier design (instant FTS + deep-scan-on-Return) exists in `SearchCoordinator` but is unwired. Not started this pass.

---

## 3. The transcript solution I've committed to (windowed build) — and what's built

**Locked decisions (made earlier with the product owner, profile-driven):**
- **Window the model build into the *existing* single `NSTextView`.** Keep renderer/attr/layout untouched (they're cheap). On open, build lines for only the **last window** of whole coalesced blocks; scroll-near-top prepends the previous window; live-tail appends. This is AV/streaming-log model, not per-block view virtualization (profile said attr/layout are cheap, so virtualizing the *view* wouldn't help; the *model build* is the cost).
- **Window unit = whole coalesced blocks.** The coalescer merges assistant/tool deltas *across events* into single `LogicalBlock`s, so windowing the post-coalesce `[LogicalBlock]` array by index is inherently boundary-safe (never cuts a merge chain). Coalescing runs once over all events (cheap text-append); only the expensive line-**build** is windowed.
- **Stable global identities (required substrate).** So a prepended older window never renumbers existing lines and inline images stay attached. `TerminalLine.id = globalBlockIndex * STRIDE(1_000_000) + lineOrdinalWithinBlock`; `blockIndex = globalBlockIndex`; `eventIndex` populated. Synthetic/meta lines (system-reminder/interrupt) get stable negative ids `-(gbi*STRIDE+ord)-1`.
- **Selection / Find / features operate on the loaded window;** reaching off-window content loads more. Accepted tradeoff.
- **Cold monster sessions:** out of scope for the windowed *build*; handled by the guardrail; true cold-instant needs **tail/partial parse** (a named follow-on phase — parse only recent events).

**Built & committed so far (all behind `FeatureFlags.transcriptWindowedBuild`, default OFF, parity-gated; ~50 focused commits on branch `perf/search-quick-wins`):**
- **Phase 2 — global-identity substrate (complete, parity-gated):** `TerminalLineID` encoding; `globalBlockIndex`/`firstEventIndex` stored on each `LogicalBlock` (assigned once in `coalesce`); `TerminalBuilder.buildLines` derives global ids when the flag is on / byte-identical local ids when off; inline-image mapper keyed by `globalBlockIndex`; `SessionTerminalView.buildRebuildResult` index maps joined on global ids. Verified: whole terminal/transcript/image/golden suite passes *identically* with the flag flipped on (70+ tests), then reverted; full 1025-test suite green flag-off.
- **Phase 3 Tasks 1–3 — slice build (complete):** window-size policy constants; `TranscriptWindow` value type (pure block-index window math: `lastWindow`, `expandedOlder/Newer`, `coversTop/Bottom`); **slice-aware `TerminalBuilder.buildLines(from:blockRange:)`** — because `globalBlockIndex` is *stored on the block*, building over `Array(blocks[range])` preserves global, stitchable ids with **no offset param needed** (a simplification over the written plan). Flag-aware parity tests prove a window == the matching slice of the whole build, and older+tail windows have disjoint, concatenation-consistent ids. Two adversarial-review-found latent slice bugs fixed (tool-group fallback key used a slice-local index; synthetic ids used a per-call counter that would collide across prepended windows).

**Design/plan docs in the repo (read for detail):** `docs/perf-master-plan.md` (index + priority), `docs/superpowers/specs/2026-06-29-transcript-progressive-windowed-build-design.md` (the design), `docs/superpowers/plans/2026-06-30-transcript-windowed-build-INDEX.md` + `-phase2/3/4/5-*.md` (per-phase task plans), `docs/perf-session-list-beachball-handoff.md` (the sort investigation).

---

## 4. What's still planned (not yet built)

- **Phase 3 Tasks 4–8 (the view integration — the hard, delicate part):** in `SessionTerminalView` (a ~5k-line state machine), build the *last window* on open when the flag is on; hold the loaded-block window in `@State`; `loadOlder()` prepend on near-top with O(1) dedupe by global block id + **scroll-anchor restore** (capture a stable global top-line id + offset before prepend, restore after); keep live-tail append; reset the window on session/filter change; recompute the `RebuildResult` index maps over the slice; full parity regression + QA gate. **Scroll-anchor preservation on prepend is the finicky UX-correctness risk.**
- **Phase 4 — Find:** a model-level text scan over `Session.events` (cheap, text-only) up front for accurate total match count + each match's global block/ordinal; next/prev loads older *or* newer windows to bring the target on-screen; explicit wrap semantics.
- **Phase 5 — tail/partial parse:** the cold-instant piece. Parse only recent events on open (`isPartiallyParsed`, `parsedFromLineIndex`, `parseMoreOlder`); a per-provider parser change. This is what actually makes a *cold* 619k-line session open fast; the windowed build alone only fixes *hydrated* opens.
- **Other workstreams:** poll offload off `@MainActor` (Problem C); HUD debounce + `SubagentHierarchyBuilder` result cache (residuals); FTS re-wire (Problem D).

---

## 5. Where I most want you to think (challenge the architecture)

1. **Is windowing the model-build the right frame at all?** I kept the single `NSTextView` and window *what gets built into it*, because profiling said attr-build + TextKit layout are cheap and the model build is 90%. But that forces a whole prepend/scroll-anchor/window-reset state machine into a 5k-line view, and Find/selection/features only see the loaded window. **Is there a categorically simpler design** — e.g. a lazy per-block/AppKit `NSTextView`-per-block or `NSCollectionView`/`NSTableView` of block cells with on-demand line building; a rope/piece-table text model; a `TextKit 2` viewport-based layout; or precomputed/persisted rendered line data — that gets instant-open *and* whole-session Find/selection without the windowing bookkeeping?
2. **The cold-parse wall is the real monster.** The windowed build only helps *already-hydrated* sessions; a cold 619k-line open still pays `parseFileFull`. Tail/partial parse (Phase 5) is a big per-provider parser rewrite. **Is there a better architecture for the parse+model layer overall** — e.g. a persistent on-disk index/cache of coalesced blocks or built lines (built once at index time, memory-mapped/paged on open); streaming/incremental parse with a byte-offset index per event; or storing transcripts in SQLite/FTS and rendering from queries? Would that collapse Problems B *and* D into one indexing story?
3. **Global-id scheme.** `globalBlockIndex * 1_000_000 + ordinal` assumes < 1M lines/block (asserted in DEBUG). Any block over that aliases. Is a composite/tuple id or a different encoding safer, given a pathological single huge tool-output block? Does the whole "stable global int id" approach have a cleaner formulation?
4. **The live-session polling model (Problem C).** A `@MainActor` model polling the filesystem + spawning ps/lsof/AppleScript every 2 s, publishing `@Published` changes that fan out to multiple views. Is polling-on-the-main-actor fundamentally the wrong shape? Would an actor-isolated background poller publishing immutable diff snapshots (or FS events / `DispatchSource` file watching instead of polling) be strictly better, and what breaks?
5. **The list at 40k rows.** SwiftUI `Table` needed a rebuild-not-diff hack to sort in O(n). At 40k rows is `Table` viable at all, or should the list be an `NSTableView`/`NSDiffableDataSource` under a thin SwiftUI wrapper? What's the cleanest path to sort/scroll/filter all being instant at 40k?

**Deliverable I want from you:** for each of B (transcript) and — if you see it — the cross-cutting indexing/parse story, either (a) endorse the current windowed-build direction with specific risk-reduction, or (b) propose a concretely different architecture, with enough detail (data model, control flow, what to keep vs discard, migration/parity path) that I could evaluate and start building it. Prioritize correctness-at-scale and "instant on every action" over minimizing churn. Tell me what I'm getting wrong.
