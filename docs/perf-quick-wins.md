# Perf Quick Wins — Independent Speed Tickets

**Status:** Proposal / not started
**Context:** See [competitive-agentsview.md](competitive-agentsview.md). These are the *independent, low-risk* speed improvements — separate from the big rendering refactor in [perf-transcript-virtualization-plan.md](perf-transcript-virtualization-plan.md). Each can land on its own.

> Reminder: this repo's policy is **no commits/pushes without explicit request**, and we are in audit/planning phase — these are tickets to schedule, not yet to implement.

---

## QW-1 — Stop self-throttling interactive search (highest ratio)

**Problem.** `FeatureFlags.lowerQoSForHeavyWork = true` ([FeatureFlags.swift:7](../AgentSessions/Support/FeatureFlags.swift)) forces `.utility` QoS and injects `try? await Task.sleep(nanoseconds: 10_000_000)` (10 ms) **between every search batch**:
- [SearchCoordinator.swift:515](../AgentSessions/Search/SearchCoordinator.swift), [:590](../AgentSessions/Search/SearchCoordinator.swift), [:835](../AgentSessions/Search/SearchCoordinator.swift), [:934](../AgentSessions/Search/SearchCoordinator.swift)
- QoS downgrade also at [:253](../AgentSessions/Search/SearchCoordinator.swift), [:457](../AgentSessions/Search/SearchCoordinator.swift)

A search that scans 1000 sessions in batches of 64 eats ~16 × 10 ms = 160 ms of pure sleep on top of `.utility` scheduling latency. This is the "search feels slow" complaint, by construction.

**Fix.** Split the flag: keep background *indexing/ingest* at `.utility` (good citizen), but run **interactive search** at `.userInitiated` with **no inter-batch sleep**. E.g. `FeatureFlags.lowerQoSForBackgroundIngest` vs `FeatureFlags.lowerQoSForInteractiveSearch = false`. Gate the four `Task.sleep` sites on the interactive flag.

**Effort:** S · **Risk:** Low (it's a throttle; removing it can only speed interactive paths). Watch for UI-thread contention on very large legacy scans — keep work off-main, just don't sleep.

---

## QW-2 — Route Cursor sessions through FTS5

> **Update (2026-06-28): not viable as written — the FTS corpus is empty for *all* sources.**
> Commit `31f6a619` ("perf: derive analytics index from session_meta…") removed the per-session
> `upsertSessionSearch` / `SessionSearchTextBuilder.build` ingest. Verified against the live
> `index.db`: 3,460 sessions in `session_meta`, **0** rows in `session_search` / `session_search_fts`.
> `hasSearchData()` is therefore always false, so SearchCoordinator's FTS fast path never runs and
> **every** search already uses the legacy scan (the Cursor exclusion at `SearchCoordinator.swift:242`
> is moot). Re-wiring FTS ingest for all sources (incl. Cursor) — text materialization at index time,
> DB growth, a backfill migration, and the QW-8 `DELETE FROM session_search` interaction — is a
> structural effort to plan separately, not a quick win.

**Problem.** Cursor sessions are **excluded from FTS** and fall through to the slow legacy scan ([SearchCoordinator.swift:242](../AgentSessions/Search/SearchCoordinator.swift)). Any query touching Cursor data hits the linear path.

**Fix.** Include Cursor in the FTS corpus build (`SessionSearchTextBuilder` / `session_search` ingest) so `searchSessionIDsFTS` covers it. Verify the Cursor transcript text is available at index time (it is — Cursor sessions are parsed from JSONL + `store.db`).

**Effort:** S–M · **Risk:** Low–Med (need to confirm Cursor text is fully materialized at ingest; otherwise partial-corpus matches).

---

## QW-3 — Viewport-scoped / value-swap recolor (Phase 0 of the big plan)

**Problem.** `applySyntaxColors` ([:3600](../AgentSessions/Views/TranscriptPlainView.swift)) does whole-document `removeAttribute` + `addAttribute(baseColor, full)` and re-iterates all role ranges, re-fired on six signals including **appearance/scheme/mono toggles** that don't change *which* spans are *which category* ([:3352](../AgentSessions/Views/TranscriptPlainView.swift)).

**Fix.** Precompute category spans once per `text`/ranges change; on pure appearance/scheme/mono/JSON-mode changes, swap attribute *values* over the known spans (or scope to the visible glyph range) instead of re-deriving over `full`.

**Effort:** M · **Risk:** Med (shares code with the rendering refactor — coordinate with [perf-transcript-virtualization-plan.md](perf-transcript-virtualization-plan.md) Phase 0). Listed here because it's independently shippable and benefits even the current view.

---

## QW-4 — Memoize transcript tokenization in the in-memory matcher

**Problem.** `SearchTextMatcher.tokenizeText` ([FilterEngine.swift:192](../AgentSessions/Services/FilterEngine.swift)) re-tokenizes the *entire* transcript string on **every** `sessionMatches` call (`:414`, `:499`) during in-memory filtering — O(transcript) per session per filter pass, no caching.

**Fix.** Cache the tokenized form keyed by session id + content version (mtime/size or transcript hash). Invalidate on reparse. Better long-term: make FTS authoritative so the in-memory transcript scan is rarely needed at all (ties into QW-2).

**Effort:** S–M · **Risk:** Low (pure memoization; correctness hinges on a good cache key).

---

## QW-5 — O(1) TranscriptCache eviction

**Problem.** `TranscriptCache.evictIfNeeded` ([TranscriptCache.swift:33](../AgentSessions/Services/TranscriptCache.swift)) calls `entries.min(by:)` (full scan of up to 512 entries) **inside a `while` loop**, under a global `NSLock`, on every `set`. Under prewarm bursts that's O(n²)-ish lock-held work serializing all cache writers.

**Fix.** Replace with an O(1) LRU (intrusive doubly-linked list + dictionary, or an ordered dictionary) so eviction is constant-time and the lock is held briefly.

**Effort:** S · **Risk:** Low (self-contained data-structure swap; unit-testable).

---

## QW-6 — Faster JSONL line scanning + drop duplicate decode

**Problem.**
- `JSONLReader.forEachLineCore` ([JSONLReader.swift:36](../AgentSessions/Utilities/JSONLReader.swift)) splits lines with `Data.range(of:)` + `Data.subdata`/`Data(buffer[...])` — per-line `Data` reallocation and a scanning `range(of:)`, slow on multi-MB files.
- `parseFileFull` decodes the first 20 lines **twice**: `parseLine` then a second `JSONSerialization.jsonObject` on the same line ([SessionIndexer.swift:1922](../AgentSessions/Services/SessionIndexer.swift), [:1926](../AgentSessions/Services/SessionIndexer.swift)).

**Fix.** Scan newlines over raw bytes (`withUnsafeBytes` + manual/`memchr`-style scan), yielding slices without per-line `Data` copies. Reuse the already-decoded object in `parseFileFull` instead of re-decoding.

**Effort:** M · **Risk:** Med (parser correctness — cover CRLF, trailing-newline, huge-line, and non-UTF8 edge cases with fixtures before/after). Speeds selection latency and FTS rebuilds.

---

## QW-7 — Decouple indexing-progress ticks from the filter pipeline

**Problem.** `UnifiedSessionIndexer`'s `CombineLatest` fan-in over ~10 providers ([UnifiedSessionIndexer.swift:738](../AgentSessions/Services/UnifiedSessionIndexer.swift)) re-runs merge+filter+sort whenever **any** provider emits — including `filesProcessed`/`totalFiles` progress ticks during indexing. Lots of repeated O(n) churn while indexing.

**Fix.** Separate the *data* stream (`allSessions` deltas) from *status/progress* streams so progress updates don't retrigger the full filter+sort. Only re-aggregate on actual session deltas.

**Effort:** M · **Risk:** Med (Combine graph surgery; verify progress UI + list both still update correctly).

---

## QW-8 — Additive migrations instead of full FTS wipes

**Problem.** `DB.bootstrap` ([DB.swift:375](../AgentSessions/Indexing/DB.swift)) contains `DELETE FROM …` reindex markers (`subagent_reindex_v2`, `custom_title_reindex_v1`, `claude_workflow_subagent_reindex_v1`, …). Each new marker on upgrade **wipes the FTS corpus and re-parses every file** — a one-time-per-upgrade "everything is slow right after updating" cliff.

**Fix.** Prefer additive/backfill migrations that re-derive only affected rows, instead of truncating the whole search corpus. Where a full rebuild is unavoidable, do it incrementally in the background with a clear progress signal.

**Effort:** M · **Risk:** Med (migration correctness; needs careful versioning + test on a populated DB).

---

## Suggested ordering

| Order | Ticket | Why first |
|---|---|---|
| 1 | **QW-1** | Biggest felt-latency win, smallest change, lowest risk. |
| 2 | **QW-5** | Tiny, isolated, removes prewarm contention. |
| 3 | **QW-2** | Removes the worst remaining slow search path (Cursor). |
| 4 | **QW-4** | Cuts in-memory filter cost; complements QW-2. |
| 5 | **QW-3** | Independently shippable; also Phase 0 of the rendering refactor. |
| 6 | **QW-6 / QW-7 / QW-8** | Higher effort/risk; schedule after the cheap wins land. |

The transcript rendering refactor ([perf-transcript-virtualization-plan.md](perf-transcript-virtualization-plan.md)) remains the largest single win and is tracked separately because it's a structural change, not a quick win.
