# Performance Master Plan — Make Every Action Feel Instant

> Priority order superseded by `docs/superpowers/plans/2026-07-01-perf-instant-master-plan.md` (post-review).
>
> **Task 4 measurement gate (2026-07-01, after quadratic fixes 71617017/e9123bfc/6979bff9):**
>
> | Session | transcriptCoalesce | transcriptModelBuild (incl. coalesce) | Prior baseline |
> |---|---|---|---|
> | Monster (49,432 events) | 4,226–4,465 ms | **26,939–27,762 ms** | 30,653 ms |
> | Mid-size (3,497 events) | 253–309 ms | 1,160–1,205 ms | ~926 ms @ 5.7k lines (different metric) |
>
> **W2 outcome (2026-07-02):** search ingest re-wired (SearchIngestService + triggers + prune, commits 42aa4ffc..20b3711f); corpus backfilled ~3.7k sessions at .utility with zero user-visible contention; Enter-search verdict from owner: "not instant, but good enough" — W2 gate PASSED, residual latency accepted. Transcript program outcome: cold 49k-event/200MB open 30s+beachball → ~200ms to content (tail-first paint + windowed build, defaults ON). Remaining snappiness target: click-to-focus latency (W3: poll merge off main actor).
>
> **Gate verdict: TRIPPED** (≥ 15 s). The Workstream-0 quadratics were real but not dominant. New findings: (a) coalesce alone is ~4.4 s at 49k events — the "coalescing is cheap text-append" design premise is false at scale (suspect per-event JSON work: `renderToolCallLabel`/`compactJSONOneLine`, `ToolTextBlockNormalizer.exitCode(from: rawJSON)`, `PrettyJSON`, `normalizeCodexInlineImageMarkers` locale-aware scans); (b) coalesce ran ~7× for the same session in one open (inline-image mapper, event-ID lookups, rebuild all re-coalesce). Action: re-profile with `sample` to attribute the ~23 s buildLines remainder; add a per-session coalesced-blocks cache; fix attributed hot spots (Task 4b) BEFORE Task 9's two-stage open — otherwise even the windowed first paint pays the full coalesce.

**Goal:** Agent Sessions should feel **instant on every action** — selecting a session, typing in search, getting results, sorting, scrolling, and while idle — even at 3,000–40,000+ sessions and multi-hundred-MB transcripts.

**Status:** Handoff for a dedicated overall-performance pass. Some pieces are shipped, some specced-and-planned, one (the session-list beachball) is the biggest unresolved lever. This doc is the single index + priority order; each workstream links to its detailed plan/spec.

**Branch:** `perf/search-quick-wins`. **Dataset for testing:** ~3,300–3,425 sessions; worst-case transcripts up to ~619k lines / 200 MB.

---

## The "instant" contract (acceptance, per action)

| Action | Target | Today |
|---|---|---|
| Type in search | No dropped characters; caret smooth | Fixed (edit-guard) |
| Search results appear | < ~100 ms after a pause | Legacy scan (FTS ingest removed) |
| Select a session -> transcript | First content < 150 ms; scroll smooth; memory bounded by viewport | Guardrail prevents hang; windowed build not built |
| Sort a column | Reorder < ~100 ms | Instant on filtered lists; the full list beachballs (see W1) |
| Idle with live sessions | No stalls; live dots update smoothly | Multi-second beachball (W1) |
| After a simple action settles | CPU/energy returns to near-idle; no persistent "Using Significant Energy" | User-observed Battery menu keeps AgentSessions under "Using Significant Energy" after transcript load/search/sort |

---

## Root-cause map (from profiling, not guesses)

Three independent dominant costs, each on the **main thread**:

1. **Live-session poll churn** (`CodexActiveSessionsModel`, `@MainActor`) — filesystem discovery plus refresh merge/dedup/enrich/classification glue run on the main actor every poll interval, then publish changes that cascade into full re-renders. The heavy process/iTerm probes already offload some work via continuations; the remaining main-actor orchestration and publish cascade are still dominant. **Dominant cost of the list beachball** (245–313/426 samples during a reproduced freeze). Sorting/scrolling piles a rebuild on an already-saturated main thread. → **W1**
2. **Transcript model build** (`SessionTranscriptBuilder.coalescedBlocks` + `TerminalBuilder.buildLines`) — builds the *whole* session events→lines on open (~90% of open time; 30.6 s / 1.3 GB on a 619k-line session). Plus a cold-parse wall (`parseFileFull`). → **W2**
3. **Empty FTS corpus** — the `session_search` ingest was removed (commit `31f6a619`), so every search runs the legacy linear scan. → **W3**

Secondary (real but not dominant): expensive computed getters (`listTitle`/`rowRepoDisplay`/`messageCount`), Cockpit HUD rebuild, Runway title filesystem scan, `SubagentHierarchyBuilder.build` details, and NSTableView reload/reentrancy. Note: the monolithic ~3,300-row `updateCachedRows` rebuild and cheap diffability (`Session.==`/`modifiedAt`) are W1 enablers, not late polish. Persistent post-action CPU/energy is a first-class symptom of the same problem family: background work must drain or back off after transcript load, search, sort, and idle ticks.

---

## Workstreams (priority order)

### W1 — Session-list responsiveness (HIGHEST LEVER; unblocks "instant everywhere")
The beachball is why sort, scroll, and idle all feel slow. **Do NOT chase this with superficial view-side list optimizations** — signature gates, coalescing, event-injection decouple, reentrancy deferral, and naive skipping of `updateCachedRows` were all tried and reverted; they don't move the needle (some risk stale live dots). Details + profiling evidence: **[docs/perf-session-list-beachball-handoff.md](perf-session-list-beachball-handoff.md)**.

Real levers (in order):
0. **Add measurement before fixes.** Add DEBUG `os_signpost` intervals (or equivalent file/console timings) around `refreshOnce`, `performRefreshDiscovery`, `classifyLiveStatesAsync`, `updateCachedRows`, `rebuildCachedFallbackPresences`, `SubagentHierarchyBuilder.build`, HUD rebuilds, and long-lived detached/background tasks. Add a simple main-thread hang/frame-time probe if practical. For every repro action, capture both the hot interval and the post-action idle window (for example 30-60 s after transcript load/search/sort) so persistent CPU/energy churn is visible. Do not judge W1 by feel alone; each lever needs before/after numbers.
1. **Split `updateCachedRows` into cheap and expensive paths.** Today membership ticks, sort clicks, and live-dot changes all pay the same monolithic path: fallback-presence rebuild + sort/reorder + hierarchy build + full table reload. Create a cheap path for unchanged session sets (sort-only reorder, live-dot/fallback-presence refresh, selection reconciliation) and reserve the expensive path for actual set/hierarchy changes. This is W1 lever #2 and the W4 residual in one refactor. Preserve cross-workspace fallback dots; naive skipping already failed in reverted "C5".
2. **Cheapen diff prerequisites.** Before relying on set/diff checks, make sure the equality/versioning used by `onChange(of: unified.sessions)` and the new cheap path is cheap enough. `Session.==` currently touches event edges and `modifiedAt` allocates; avoid making diffing itself the new O(n) stall.
3. **Investigate idle membership flapping.** The visible row count has been observed changing at idle (for example 3249 <-> 3330). Use the new signposts/logging to identify what actually flips `membershipChanged` (TTL, transient empty publishes, probe races, empty overwrite) before treating churn as unavoidable.
4. **Offload `CodexActiveSessionsModel.refreshOnce` main-actor work.** After the cascade is measured and reduced, move the remaining discovery/merge/classify orchestration off the main actor with immutable snapshots in and small result diffs out. Preserve `refreshInFlight`/generation guards. Anchor by symbols, not line numbers: `CodexActiveSessionsModel`, `startPollingIfNeeded`, `performRefreshDiscovery`, `classifyLiveStatesAsync`, `refreshOnce`, `activeMembershipVersion`.
5. **Debounce `AgentCockpitHUDDerivedStateModel.scheduleRebuild`.**
6. **Move the Runway title scan off-main / cache it** (`ClaudeDesktopSessionTitles`, `ClaudeRunwaySnapshotLoader`).
7. **Poll-cadence backoff** while the window is busy / the user is interacting (`pollIntervalSeconds`).

**Acceptance:** build succeeds; no multi-second stall on sort/scroll/idle at 3,300+ sessions; live dots and fallback dots still update; main thread is not 100% busy on a poll tick; a 30 s sample during a reproduced sort/idle stall no longer shows `CodexActiveSessionsModel.performRefreshDiscovery` / `classifyLiveStatesAsync` or `UnifiedSessionsView.updateCachedRows` dominating the main thread; after a transcript load/search/sort settles, Agent Sessions returns to near-idle CPU/energy instead of remaining in the Battery menu's significant-energy list.

### W2 — Transcript open (windowed build)
Already: **Phase 1 guardrail + TL-1 shipped** (commit `6b72fb2e`) — a monster session can't hang the app. Next: the windowed build so transcripts open truly instantly. Fully planned:
- **[Plan INDEX + cross-phase contract](superpowers/plans/2026-06-30-transcript-windowed-build-INDEX.md)** (read first).
- Phase 2 global identities → Phase 3 windowed build → Phase 4 Find/jump → Phase 5 tail parse. Build order 2 → 3 → (4 ∥ 5). Spec: **[design](superpowers/specs/2026-06-29-transcript-progressive-windowed-build-design.md)**.

**Acceptance:** hydrated 619k-line session opens < 150 ms, memory bounded by viewport; Find/jump/live-tail/images/links/Copy/export preserved; once landed, the Phase 1 interstitial relaxes/retires.

### W3 — Search speed (FTS index re-wire)
The FTS corpus is empty (ingest removed). Re-wire it so instant search uses FTS, not the legacy scan; the existing two-tier design (instant FTS + deep-scan-on-Return) already exists in `SearchCoordinator`. Spec: **[search responsiveness + FTS index design](superpowers/specs/2026-06-29-search-responsiveness-and-index-design.md)** (Phase A). Includes re-materializing transcript text at index time (incl. Cursor), additive migrations (no full wipes), and a background backfill for existing sessions.

**Acceptance:** a query matching any source (incl. Cursor) returns from FTS < ~100 ms; no per-search transcript tokenization on the hot path.

### W4 — Sort (mostly resolved by W1)
Done: **comparator Schwartzian fix** (`ead051e0`) and **sort decoupled from the filter pipeline** (`f7b8a62c`) — sort no longer re-filters all rows. Residual: on the *full* list, `updateCachedRows` re-runs the set-dependent rebuild (presences / side-chat contexts / derived state) even though a sort only reorders. This is now folded into W1's `updateCachedRows` split: sort-only changes should use the cheap path.

### W5 — Secondary polish (after W1–W3)
- **Memoize expensive row getters** per session+version: `listTitle`, `rowRepoDisplay` (project classifiers/path normalization/event scans), `messageCount` (computed from events). Used in sort keys, hierarchy, and cells.
- **`SubagentHierarchyBuilder.build`**: avoid `URL(fileURLWithPath:)` per session (~60–90 ms/full rebuild).
- **NSTableView reentrancy**: the full `cachedRows` reassignment reloads all rows with an "NSTableView reentrant operation" warning (selection mutation during reload) — investigate incremental/diffed updates.

---

## Cross-cutting principles (apply everywhere)
1. **Keep the main actor free.** No filesystem/process/parse/tokenize/O(n) work on `@MainActor`. Background-compute, publish small diffs.
2. **Publish diffs, not full rebuilds.** A live-dot change must not re-render 3,300 rows; a sort must not re-filter; an appearance toggle must not re-color a whole document.
3. **Window / lazy everything O(document) or O(all-sessions).** Render the viewport, index a bounded corpus, parse the tail, memoize derived values.
4. **Profile a *reproduced* freeze** (`sample <pid> 30` during the stall) before optimizing — a short sample misses it and shows main idle in `mach_msg2_trap`. Don't guess; several confident view-side guesses here were wrong.
5. **Prove quiescence after actions.** Search, transcript build, sort, prewarm, indexing, and live polling must have clear finish/cancel/backoff behavior. A simple user action should not leave orphaned work, tight polling, or repeated full rebuilds running after the UI appears idle.

---

## Sequencing

1. **W1 (measure + cascade split + poll offload)** — highest felt impact; makes sort/scroll/idle instant and is the current #1 pain. Start here.
2. **W2 (transcript windowed build, Phases 2→3→4∥5)** — makes session-open instant; retires the guardrail interstitial.
3. **W3 (FTS index re-wire)** — makes search results instant.
4. **W4/W5 polish** — fold in as W1 exposes residuals.

This is priority order, not a hard dependency graph: W2 and W3 are independent of W1 and can run concurrently if there are separate owners. Use existing or explicitly approved feature flags only; otherwise implement directly and validate with build + profiling. Verify on the 3,300-session / 619k-line fixtures before declaring a stream done.

---

## Status ledger

**Shipped (branch `perf/search-quick-wins`, pushed):**
- QW-1 interactive-search QoS split; QW-4 tokenization memo; QW-5 O(1) TranscriptCache LRU.
- Search **edit-guard** (no dropped characters).
- Transcript **Phase 1 guardrail** + **TL-1** (`.userInitiated` build).
- Sort: comparator Schwartzian (`ead051e0`) + **decoupled from filter** (`f7b8a62c`).

**Specced / planned, not built:**
- Transcript windowed build — Phases 2–5 plans + INDEX (this repo, `docs/superpowers/plans/`).
- Search FTS index re-wire — design spec (`docs/superpowers/specs/`).

**Unresolved, highest priority:**
- **W1 session-list beachball** — see the handoff doc; the biggest lever.

## References
- [Session-list beachball handoff](perf-session-list-beachball-handoff.md) (W1, with profiling evidence)
- [Transcript windowed-build plan INDEX](superpowers/plans/2026-06-30-transcript-windowed-build-INDEX.md) (W2)
- [Transcript design spec](superpowers/specs/2026-06-29-transcript-progressive-windowed-build-design.md) (W2)
- [Search responsiveness + FTS index spec](superpowers/specs/2026-06-29-search-responsiveness-and-index-design.md) (W3)
- [Perf quick wins](perf-quick-wins.md) · [AgentsView competitive analysis](competitive-agentsview.md)
