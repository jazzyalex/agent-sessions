# Design: Search Responsiveness + FTS Index Repopulation

**Date:** 2026-06-29
**Branch:** `perf/search-quick-wins` (continues the perf work; QW-1/QW-4/QW-5 already landed)
**Status:** Design — pending user review before implementation plan

## Problem

Search in Agent Sessions feels worse than the AgentsView competitor in two distinct,
independent ways. Investigation (see `docs/perf-quick-wins.md` and the QW-2 finding)
showed these are **two separate problems** wearing one costume:

- **B — Typing stutters / drops characters (input latency).** The search draft
  `queryDraft` is `@Published` on `UnifiedSessionIndexer` (`unified`), a heavyweight
  object the entire 3,000-line `UnifiedSessionsView` (containing the results `Table`)
  observes via `@ObservedObject`. Every keystroke fires `unified.objectWillChange`,
  re-evaluating the whole view body on the main thread. A two-way
  `queryDraft ↔ searchState.query` sync adds churn. The `Table` itself is virtualized
  (NSTableView-backed) and `cachedRows` is stable `@State`, so the cost is **whole-view
  body invalidation per keystroke**, not row rendering.
- **A — Search is slow (no index).** The SQLite FTS corpus is empty for *all* sources:
  commit `31f6a619` removed the per-session `upsertSessionSearch` /
  `SessionSearchTextBuilder.build` ingest. `hasSearchData()` is always false, so
  `SearchCoordinator`'s FTS fast path never runs and every search uses the legacy linear
  scan over ~3,460 sessions. Verified against the live `index.db`: 3,460 rows in
  `session_meta`, 0 in `session_search`.

These are independent. Fixing only A leaves typing stuttering; fixing only B leaves
results slow. Matching AgentsView needs both. **B ships first** (smaller, lower-risk,
the prerequisite for smooth typing); **A second** (structural).

## Goals / Non-Goals

**Goals**
- B: Typing never drops characters; the session list/`Table` is not re-evaluated on
  keystrokes. Results update on a short debounce or on Return.
- A: `session_search` + FTS populated for all sources incl. Cursor; `SearchCoordinator`'s
  existing two-tier model becomes real — instant tier from FTS, exact deep scan on Return.

**Non-Goals**
- Transcript rendering virtualization (separate deferred plan — `docs/perf-transcript-virtualization-plan.md`).
- Redesigning match semantics (two-tier reuses the existing `SearchCoordinator` FTS path + legacy deep scan).
- `session_tool_io` (tool-output-scoped FTS) repopulation — a follow-on (A.2), not this cut.
- Full-text indexing (we keep the bounded sampled corpus; deep-scan-on-Return covers gaps).

---

## Phase B — Search input responsiveness (first)

### Root cause (verified against code)
Dropped characters come from **two compounding causes**:
1. **Stale-value clobber.** `ToolbarSearchTextField.updateNSView` (`:3984`) runs
   `if tf.stringValue != text { tf.stringValue = text }` with **no check for active
   editing**. Under fast typing the SwiftUI binding (`text` → `unified.queryDraft`) lags
   the NSTextField; a re-render then overwrites the field with the stale binding value,
   erasing characters typed since. This is the direct mechanism for *lost characters*.
2. **Main-thread congestion.** `queryDraft` is `@Published` on `unified`, so each keystroke
   re-bodies the 3,000-line view — the congestion that makes the binding in (1) lag, plus
   general jank. (Search itself is already debounced ~280ms and runs off-main, so the
   *search work* is not the cause.)

Both get fixed; (1) is the cheapest, highest-value change for lost characters specifically.

### Approach
Isolate the search field with a **local** draft + debounced commit, AND make the text
field never overwrite itself mid-edit. Per-keystroke mutations stay inside the isolated
field; the shared/applied query (which the big view and per-indexer pipelines observe)
updates **only** on debounce or Return.

### Components
- **`ToolbarSearchTextField` (edit-guard fix).** In `updateNSView`, skip the
  `stringValue = text` write while the field is actively being edited / first responder
  (apply external/programmatic text only when not editing). Removes the stale-value clobber
  (cause 1) regardless of congestion — small, high-value, and independently shippable.
- **`SearchToolbarField` (new small SwiftUI view).** Owns `@State private var draft: String`.
  Hosts the existing AppKit-backed `ToolbarSearchTextField`. Debounces draft changes
  (~175 ms) and exposes `onApply(String)`, `onCommit()` (Return → immediate + deep scan),
  `onClear()`. Typing mutates only `draft` + the NSTextField — no parent `objectWillChange`.
- **`UnifiedSessionIndexer`.** Remove `queryDraft`. Keep the *applied* `query` (the
  per-indexer filter pipelines subscribe to `$query`), but it is written only on
  debounce/commit, so pipelines + the big view churn at most once per debounce, never
  per keystroke.
- **`UnifiedSessionsView`.** Remove the two-way `queryDraft ↔ searchState.query` sync
  (`:3758–3782`). Host `SearchToolbarField`; wire its callbacks to `SearchCoordinator`
  (apply/commit/clear). The view observes only **results**, not the draft.
- **Applied-query source of truth.** Today both `unified.query` and `searchState.query`
  exist and the latter is written per keystroke. Phase B consolidates to a *single*
  applied-query value written **only** on debounce/commit, and removes all per-keystroke
  writes to any object the big view observes. (Concretely: drive `SearchCoordinator` from
  the debounced apply, and set `unified.query` from the same point so the per-indexer
  filter pipelines stay in sync — no separate per-keystroke `searchState.query` path.)
- **Preserve:** ⌥⌘F focus, Escape-to-clear, the ✕ clear button, programmatic query set
  (menu / deep-link), and `TypingActivity.shared.bump()` (gates transcript prewarm).

### Data flow
```
keystroke → SearchToolbarField.draft (local @State) + NSTextField
          → [debounce 175ms]  → applied query → background search → results → Table re-body
          → [Return]          → applied query (immediate) → deep scan (tier-2)
```

### Error / edge handling
- Empty/whitespace query → cancel in-flight search, clear results filter.
- Focus races: the isolated field is the first responder; programmatic set updates `draft`
  and the NSTextField via the existing guarded `updateNSView` (`if tf.stringValue != text`).
- Rapid type-then-Return: Return cancels the pending debounce and commits immediately.

### Testing
- **Unit (model-level decoupling):** a small testable search-field state type — assert
  updating `draft` does NOT mutate the applied query before debounce/commit; Return commits
  immediately; clear resets both.
- **Manual/QA (build, user verifies):** fast typing over the full dataset — no dropped
  characters, smooth caret. The view's existing `debugActiveOnlyUpdateRows*` counters can
  confirm body re-eval count drops to ~per-debounce.

### Acceptance
- Typing in a large dataset drops no characters and stays smooth.
- The `Table`/big-view body is not re-evaluated per keystroke (only per debounce/result change).
- All existing search affordances (shortcut, clear, Return-deep-scan, programmatic set) still work.

---

## Phase A — FTS index repopulation (second)

### Note (verified against code)
When the query is non-empty the results `Table` is driven by
`unified.applyFiltersAndSort(to: searchCoordinator.results)` (`:367`), so repopulating FTS
(which `SearchCoordinator` already queries) **does** speed up the displayed list — it is not
a hidden code path. When the query is empty the list shows `unified.sessions` (metadata
filter/sort), unaffected. The as-you-type debounce is currently 280ms
(`FeatureFlags.increaseDeepSearchDebounce`); with fast FTS it can be lowered for snappier
results — a tuning knob decided during implementation, not a core design choice.

### Approach
A dedicated **incremental background indexer** (`SearchCorpusIndexer`) backfills and
keeps up `session_search` for rows that are missing or stale, decoupled from the hot
parse path (consistent with why `31f6a619` moved indexing off file-parsing).

### Components
- **`SearchCorpusIndexer` (new service).**
  - **Work set:** sessions in `session_meta` whose `session_search` row is missing, or
    stale by `mtime`/`size`/`format_version` (reuse `fetchSearchReadyPaths` +
    `FeatureFlags.sessionSearchFormatVersion`).
  - **Per session:** ensure a **full parse** (materialize events — crucial for Cursor and
    other lazily-parsed sources) via the session store's `parseFull`; build the bounded
    corpus via `SessionSearchTextBuilder.build`; `upsertSessionSearch(...)`.
  - **Scheduling:** once after launch (backfill), then incrementally on session add/update
    (subscribe to indexer `allSessions` deltas). Runs at `.utility`
    (`lowerQoSForBackgroundIngest`), batched with cooperative yields, cancellable,
    restartable (idempotent by `mtime`/`format_version`). Surfaces progress.
- **Migration (additive).** A `format_version` bump re-derives only affected rows
  (predicate by stale `format_version`), **never** `DELETE FROM session_search`. Resolves
  the QW-8 upgrade cliff for this corpus.
- **`SearchCoordinator`.** Remove the Cursor exclusion (`:242`) once Cursor is indexed;
  rely on per-source `hasSearchData`. Keep the legacy scan as the **Return deep-scan
  (tier-2)**; FTS is the instant tier-1.

### Data flow
```
launch → SearchCorpusIndexer: find missing/stale rows
       → per session: parseFull (materialize) → build bounded corpus → upsertSessionSearch
       → session_search / _fts populate → hasSearchData=true
       → SearchCoordinator instant tier uses FTS; Return still runs legacy deep scan
```

### Error / edge handling
- **Cursor materialization (primary risk):** the indexer MUST `parseFull` before building.
  If a source genuinely cannot be fully materialized at index time, it is excluded from
  FTS (documented) and remains covered by the legacy deep scan — no silent partial corpus.
- Parse failure → skip + log; session stays unindexed (legacy covers it).
- DB errors → transactional upserts; retry/skip; never corrupt the corpus.
- Cancellation (app quit) → resume next launch; idempotent.

### Testing
- **Unit:** the "needs reindex" predicate (missing row / stale mtime / stale format_version).
- **Integration (QW-2 acceptance):** seed a Cursor session with unique content → run the
  indexer → assert `session_search` contains its text → assert `SearchCoordinator` returns
  it via the **FTS path** (`hasSearchData` true), not the legacy scan.
- **Migration:** bump `format_version` → only affected rows re-derived; corpus not wiped.

### Acceptance
- After backfill, `session_search`/`session_search_fts` are populated for all enabled
  sources incl. Cursor; `hasSearchData` true.
- A query matching Cursor-only content returns via FTS, not the legacy scan.
- Upgrades that bump the corpus version re-derive incrementally, without a full wipe.

---

## Risks & mitigations
- **Cursor (lazy-source) text not materialized at ingest** → indexer forces `parseFull`;
  integration test asserts Cursor content is FTS-searchable.
- **Ingest cost / DB growth** → bounded corpus (~48k chars/session, base64+secret redaction)
  + `.utility` + incremental, idempotent backfill.
- **Migration correctness** → additive re-derivation, tested on a populated DB.
- **Phase B focus/shortcut regressions** → preserve and test all existing affordances.

## Sequencing
1. **Phase B** — responsiveness (independently shippable + testable).
2. **Phase A** — index repopulation (independently shippable + testable).
Each phase builds + passes the full test suite before it is considered done.
