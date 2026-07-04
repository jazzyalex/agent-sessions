# Architecture Review — "Make Agent Sessions Instant"

**Reviewer:** Claude Fable 5 (independent design review, 2026-07-01)
**Input:** `docs/perf-fable-review-brief.md`, plus direct reading of the design/plan docs and the code on `perf/search-quick-wins` (builder, coalescer, window math, ID scheme, parse path, IndexDB, view rebuild path, poll loop).

---

## TL;DR verdicts

| Question | Verdict |
|---|---|
| Windowed model build (Problem B, hydrated) | **Endorse the frame, with two corrections**: (1) the 30 s number is partly *accidental quadratics*, not inherent linear cost — fix those first, they shrink the problem the window must solve; (2) treat the window as a **warm start, not a permanent regime** — kick off the full build in the background and swap it in. That deletes most of the long-tail windowing complexity (Find/selection/scroll semantics) instead of engineering around it. |
| Categorically simpler design (per-block views, rope, TextKit 2, persisted lines) | **No.** Your profiling correctly killed these. Detailed rejections below so this doesn't get re-litigated. |
| Cold-parse wall + empty FTS (Problems B-cold and D) | **Yes, one indexing story collapses them** — and you already own the substrate. `IndexDB` already has `files`/`session_meta`/`session_search`+FTS5/`session_tool_io`. Re-wiring FTS ingest requires streaming every file once; emit **per-event byte-offset checkpoints** in the same pass and Phase 5 stops being "a big per-provider parser rewrite" — tail parse becomes *seek + read slice + existing `parseLine`*. |
| Global-id encoding (§5.3) | Encoding is fine; the *failure policy* isn't. The >1M-line block aliases **silently in Release** (assert-only). Add a block-split/truncate policy at build time instead of changing the ID type. Also audit `decorationGroupID`, which has the same aliasing shape at stride 1000. |
| Polling model (§5.4) | Polling per se is not the sin; **doing merge/classify/publish on the main actor and rebuilding the HUD 35 ms per tick with no time-debounce is**. Two-step fix: debounce + off-main snapshot computation now; `actor PresenceEngine` emitting immutable snapshots as the structural fix. FSEvents replaces the *registry* poll only; process/lsof/AppleScript probes stay timed. |
| SwiftUI Table at 40k (§5.5) | The rebuild hack is legitimate but is O(n) with a growing constant — it's on borrowed time past ~10k rows. Keep it at 3.3k; define a measured trigger (p95 sort > 200 ms at target dataset) that flips the list to `NSTableView` behind the existing row model. Don't rewrite preemptively. |

The single highest-leverage finding of this review: **two accidental quadratics in the hydrated-open path that the plan doesn't know about** (§1.1). They're flag-independent, testable, fixable in days, and they change the economics of everything downstream.

---

## 1. Problem B — the windowed build

### 1.1 First, the accidental quadratics (fix before more architecture)

The 30,653 ms @ 619k lines figure is the justification for the windowing state machine. Part of that cost is not inherent. I found two superlinear hot spots by reading the code:

**(a) `nearestUserBlockIndex` is O(blocks × userBlocks)** — [SessionTerminalView.swift:988](../AgentSessions/Views/SessionTerminalView.swift#L988). Inside `buildRebuildResult`, for **every** block, the closure does:

```swift
let prior = userBlockIndices.filter { $0 <= idx }        // O(U) allocation + scan
if let preferred = prior.last(where: { ... }) ?? prior.last { ... }
let after = userBlockIndices.filter { $0 > idx }         // O(U) again
```

At monster scale (tens of thousands of blocks × thousands of user blocks) this is hundreds of millions of closure invocations and array allocations — plausibly *seconds* of the 30 s. It's a single forward sweep with a running "last non-preamble user block" pointer: O(B). The `after`-fallback only matters for blocks before the first user block, which you can patch in one backward pass.

**(b) The coalescer's delta merge is O(chain²) in bytes** — [SessionTranscriptBuilder.swift:488–498](../AgentSessions/Services/SessionTranscriptBuilder.swift#L488). The merge does:

```swift
if let last = blocks.last, canMerge(last, b) {
    var merged = last            // second reference to last.text's buffer
    merged.text += b.text        // CoW: copies the ENTIRE accumulated string
    blocks.removeLast()
    blocks.append(merged)
}
```

At the moment of `merged.text += b.text`, the storage is still referenced by `blocks.last`, so copy-on-write duplicates the whole accumulated text on **every** delta append. A Codex assistant stream of k deltas totaling L bytes copies ~k·L/2 bytes. Mutating in place — `blocks[blocks.count - 1].text += b.text` (single unique reference) — is amortized O(1) per append. This directly contradicts the design's "coalescing runs once over all events (cheap text-append)" premise: the *intent* is cheap append, the *implementation* is quadratic.

Smaller but real, same pass:
- `ToolTextBlockNormalizer.normalize` runs **twice per tool block** — once in `TerminalBuilder.buildLines` ([TerminalModels.swift:112](../AgentSessions/Services/TerminalModels.swift#L112)) and again in `buildRebuildResult`'s tool-group-key loop ([SessionTerminalView.swift:1029](../AgentSessions/Views/SessionTerminalView.swift#L1029)). Compute once, carry it.
- `looksLikeLineNumberedSourceDump` regex-scans the full text of every read-like tool output; `parseExitValue` compiles its `NSRegularExpression` per call. Cache compiled regexes; bail early on size.

**Why this is an architecture point, not a nitpick:** re-measure the 619k build after (a)+(b). If the true linear cost lands at ~2–5 s (plausible), the windowed build is still right for instant-open — but the *shape* of the solution changes, per §1.2.

### 1.2 The structural simplification: window as warm start, full build swapped in behind

The plan as written makes the window a *permanent regime*: `loadOlder()` prepend, scroll-anchor restore, window reset on filter change, Find that pages windows in both directions, selection scoped to the window forever. That's the 5k-line view's state machine growing a second state machine, and it's where your risk concentrates (you said it yourself: "scroll-anchor preservation on prepend is the finicky UX-correctness risk").

Phase 2 bought you something the plan isn't cashing in: **window lines and whole-session lines have identical global IDs**. A whole-session build is a strict superset of the window build. So:

1. On open: build the last window, show it (< 150 ms). *Unchanged from your plan.*
2. Immediately kick the **full build** on a background task (you already have `Task.detached` plumbing in `rebuildLines`).
3. When it completes, swap `lines` wholesale. Because IDs are stable and the window is a suffix of the full array, the currently-visible anchor line's ID exists in the new array — capture first-visible line ID + offset, `setAttributedString`, restore. One swap, at a moment you control, instead of N user-triggered prepends.
4. After the swap: Find, selection, minimap, role nav, export are **whole-session again**. No windowed-Find (Phase 4's window-paging machinery mostly evaporates — the model-scan for counts is still nice for pre-swap accuracy, but next/prev after swap is today's code). `loadOlder()` becomes the fallback for the pre-swap seconds and for guardrailed monsters — nice-to-have, not the primary UX.

Cost model: at post-§1.1 linear build speeds, a 619k-line session completes its full build in single-digit seconds *while the user is already reading the tail*. The 926 ms @ 5.7k-line session swaps in ~1 s — most sessions never show a window seam at all. Memory is the one thing the swap gives back (whole session's lines + attr string resident) — see §2.4: window-bounded memory is currently fiction anyway because `Session.events` retains `rawJSON`.

Concrete recommendation for Phase 3 Tasks 4–8: keep Task 4–5 (open with last window, window in `@State`), **add the background-full-build swap before building the loadOlder prepend machinery**, then decide from real usage whether interactive prepend is still worth its complexity. My bet: it gets demoted to "monster sessions only," and Phase 4 shrinks by half.

### 1.3 Alternatives you asked me to consider — rejections with reasons

- **Per-block view virtualization (`NSTableView`/`NSCollectionView` of block cells):** kills cross-block text selection (a core affordance of a terminal transcript), breaks the single-storage Find/highlight/linkify/decoration pipeline you've already built in `TerminalLayoutManager`, and doesn't attack the measured cost (model build) anyway. Your profile correctly killed this; stay dead.
- **TextKit 2 viewport layout:** solves *layout* cost at scale. Layout is 20–50 ms — not your problem. You'd still build the whole model + attributed string. Meanwhile your custom `TerminalLayoutManager` (TK1 `NSLayoutManager` subclass doing decorations, find highlighting, line indexing) has no TK2 equivalent without a rewrite, and TK2 `NSTextView` on macOS still has selection/API rough edges. Revisit only when Apple forces the migration.
- **Rope / piece table:** ropes fix random-position *editing* of huge strings. This is an append/prepend-only render target; `NSTextStorage` handles both fine. The cost is upstream of the string.
- **Persisted rendered lines (build-once-at-index-time, page on open):** rendered lines are a function of app version × settings (review cards, tool normalizers, semantic segmentation, meta visibility). You'd inherit a cache-invalidation matrix forever, to skip a build that windowing already bounds and §1.1 makes cheap. **Reject as persistence** — but do add an **in-memory LRU of `RebuildResult` keyed by (sessionID, mtime, settings-hash)**: reopening a recently-viewed session becomes free, and it's ~30 lines.

### 1.4 Risk reduction on the endorsed path

- **Window sizing must be char/line-budgeted, not just block-counted.** `transcriptWindowBlockTarget = 400` whole blocks can still be 100k+ lines if one block is a giant tool dump. You have per-block text in hand at window-selection time; accumulate an estimated line budget (`text` newline count is already computed in the build — precompute or estimate by bytes/80) and stop expanding when hit. `TranscriptWindow` is the right home.
- **Parity tests at the window boundary for the index maps.** `nearestUserBlockIndex` semantics differ subtly when the true nearest user block is *outside* the window (it anchors to a different user block than the whole build would). With the §1.2 swap this is a transient state; still, assert parity for the full-window case and define (test-pin) the clamped behavior for partial windows.
- **Prepend scroll-anchor (if you keep interactive prepend):** insert-at-0 on `NSTextStorage` rebases every coordinator range (O(n), fine) and invalidates layout from 0 — expect a one-frame hitch. Capture `(anchorLineID, offsetInLine, scrollY-delta)` before, restore via the rebased range after, inside a single layout pass with animations disabled. Budget ~50–100 ms per prepend and call it acceptable for a rare gesture; do not chase perfect pixel stability before the swap architecture lands.

---

## 2. The cross-cutting story: parse + index (Problems B-cold and D are one problem)

This is the part of the brief where I most disagree with the current framing. Phase 5 is described as "a big per-provider parser rewrite," and Problem D as a separate unstarted workstream. Reading the code says otherwise:

### 2.1 What you already own

- Sessions for the dominant providers (Codex, Claude, Copilot, Antigravity-post-migration) are **JSONL** — parsed by a streaming `JSONLReader` ([JSONLReader.swift](../AgentSessions/Utilities/JSONLReader.swift)) feeding a per-line `parseLine`. Line-delimited formats are the *easiest possible* format to window: any byte offset at a `\n` boundary is a valid resume point.
- `IndexDB` ([DB.swift](../AgentSessions/Indexing/DB.swift)) already has: `files` (path, mtime, size — your invalidation key), `session_meta` (already powering fast startup), `session_search` + FTS5 external-content table with triggers, `session_tool_io` + FTS, `fetchSearchReadyPaths` anticipating incremental re-ingest. The **only missing piece is the ingest writer** (removed in `31f6a619`).
- OpenCode/Cursor already read from SQLite sources — they never had a parse wall of the same shape.

### 2.2 The unification: one streaming pass, two outputs

Re-wiring FTS ingest means streaming every session file once (off-main, idle QoS, batched transactions — the throughput problem is real but bounded). While you are in that byte stream anyway, **also emit event checkpoints**:

```
per session: [(lineIndex, byteOffset, kind, timestamp?)] at every K-th event
             (K=64 → ~600 KB for the 619k monster at 16 B/entry; K=1 is also fine)
```

Store as a blob column keyed by `(session_id)`, validated by `(mtime, size)` from `files` — append-only JSONL files mean an mtime/size mismatch with a *larger* size can even fast-forward from the last checkpoint instead of re-ingesting.

Then cold open of any indexed session is:

1. Query checkpoints; binary-search the one ≤ (fileLength − tailBudget).
2. `FileHandle.seek` to it; run the **existing** `parseLine` loop from there with `idx` seeded from the checkpoint's `lineIndex` — which keeps `eventID(base:index:)` **identical** to a full parse (this is the one subtle correctness point: event IDs are index-derived, so partial parse must know its absolute line index; checkpoints give you exactly that).
3. Hand the parsed tail events to the windowed build. `isPartiallyParsed` / `parseMoreOlder` = seek to an earlier checkpoint, parse forward, prepend events — the same dedupe-by-global-id discipline Phase 2 already built, one level down.

**Phase 5 collapses from "per-provider parser rewrite" to "a seek-parameter on the existing per-line parsers, fed by the ingest pass Problem D needs anyway."** For a *never-indexed* session (new file, app just installed), fall back to a `ReverseJSONLLineReader` (read backwards in 64 KB chunks to collect the last N lines — ~80 lines of shared code) or just eat one full parse and checkpoint it as you go.

What I would **not** do: store transcripts themselves in SQLite and render from queries. The JSONL files are the source of truth, agents append to them live, and duplicating hundreds of MB into the DB buys you nothing the offset index doesn't, at the price of a second copy to invalidate. Store *small derived things* (meta, search text, checkpoints); leave the transcripts on disk.

### 2.3 Ordering consequence

This makes FTS re-wire + checkpoints **higher priority than Phase 5 as planned** — it's the same work, and it unblocks two problems. Suggested order: land Phase 3 (with §1.2's swap), then do ingest+checkpoints, then Phase 5 becomes a small PR. Phase 4's model-scan Find is unaffected (in-memory events, cheap, no index needed).

### 2.4 Memory: the goal statement is currently false

"Memory scales with the window" cannot be true while `SessionEvent.rawJSON` retains the full raw line for **every event** ([SessionIndexer.swift parse path], `LogicalBlock.rawJSON` too). A hydrated 200 MB session holds ≥ 200 MB of strings before a single line is built, window or no window. With the checkpoint index in place, `rawJSON` becomes recoverable on demand (seek + re-read the line) — keep only what the UI actually consumes eagerly (exit-code sniffing, review-card detection already extract at build time) and drop or lazy-load the rest. Without this, the windowed build fixes latency but not "monster session makes the app fat."

---

## 3. §5.3 — Global-ID encoding

The `gbi * 1_000_000 + ordinal` scheme is sound: unique, monotonic in render order, cheap to decode, and the view honors the "dictionary key, never subscript" contract. The synthetic negative-space encoding is clever and now slice-stable. I would **not** move to a composite struct ID — `Identifiable`/`Comparable` would work, but the churn radius (every dictionary, `sorted()`, `LineIndexEntry`, layout-manager plumbing) buys you protection against exactly one pathology, which has a cheaper fix:

- **The real gap is failure policy, not encoding.** A >1M-line block aliases *silently in Release* (asserts compile out). Don't let it: at build time, when a block's ordinal would hit `stride`, **stop emitting lines for that block** and emit one synthetic meta line ("… output truncated, N more lines") — a 1M-line single block is unreadable and unnavigable anyway; truncation is a *feature* dressed as a guard. Alternatively split the block into continuation blocks at coalesce time, but truncation is simpler and honest. Add an `os_log` fault so you hear about it.
- **Same audit for `decorationGroupID`** — `blockIndex * 1000 + segmentOrdinal` ([TerminalModels.swift:587](../AgentSessions/Services/TerminalModels.swift#L587)): a block with >1000 segments (system-reminder splitter on a pathological paste) aliases decoration groups into the next block. Same truncate-or-clamp policy, same one-line guard.
- Headroom check for the encoding itself: Int64 gives ~9.2e18; at stride 1e6 that allows ~9.2e12 blocks. No overflow risk. Fine.

---

## 4. §5.4 — The live-session polling model

Split the question in two, because they have different answers:

**Is polling wrong?** Not entirely. The *registry* poll (disk reads every 2 s) should become event-driven — FSEvents/`DispatchSource` on the registry directories, with a slow (30–60 s) sweep as a TTL/garbage-collection backstop. But the process probes (`ps`/`lsof`) and the iTerm AppleScript probe have no push equivalent; they stay timed. So the end state is "watch what can be watched, poll what must be polled, slowly."

**Is @MainActor the wrong home? Yes, unambiguously.** `refreshOnce` ([CodexActiveSessionsModel.swift:1161](../AgentSessions/Services/CodexActiveSessionsModel.swift#L1161)) captures ~15 snapshot locals and runs merge/dedup/classify actor-isolated; only process waits hop off. Target shape:

- `actor PresenceEngine`: owns caches, probe scheduling, generation guards, merge/classify. Emits immutable `PresenceSnapshot` values over an `AsyncStream`.
- Thin `@MainActor` store: consumes snapshots, diffs against current, publishes only on real change (your `activeMembershipVersion` discipline ports verbatim — it's the part of this model that's already right).
- Watch-outs for the migration: AppleScript execution is not thread-safe — if the iTerm probe uses `NSAppleScript` it must stay on main or move to an `osascript` subprocess (the subprocess is the better answer anyway); ordering currently comes free from main-actor serialization and the actor preserves it; the DEBUG metrics counters assume single-threaded mutation.

**But the visible symptom has a cheaper kill.** The idle-energy driver is the **HUD rebuild at ~35 ms per 2 s tick with same-runloop coalescing only**. Two independent fixes, either sufficient, do both:
1. **Time-debounce** `rebuildIfReady` (≥ 500 ms–1 s coalescing window) — HUD data is presence-freshness display; sub-second latency is imperceptible.
2. **Snapshot-hash gate**: compute `makeRowsSnapshot` input's hash (or reuse the membership version + live-state fingerprint) and skip the rebuild when nothing changed — which at idle is *every* tick. Idle then costs ~0, and the actor migration becomes a hygiene project instead of an emergency.

Sequencing: ship debounce+gate now (days, low risk), do the actor extraction as the structural follow-up (it's a 4.6k-line file; budget accordingly).

---

## 5. §5.5 — The list at 40k rows

Honest framing of your rebuild hack: you discovered SwiftUI `Table`'s reorder-diff is O(moved²) and you route around it by resetting identity, paying O(n) rebuild + scroll reset. That's the right trade at 3.3k. The open questions:

- **Is there an O(n), scroll-preserving sort inside SwiftUI Table?** Not that I can offer with confidence. The diff is inside `AppKitOutlineTableCoordinator`; you don't control it. Two spikes worth one afternoon each before concluding: (1) capture first-visible row ID before the identity bump and `scrollTo` it after — turns "scroll resets to top" into "scroll approximately preserved," removing the tradeoff rather than the hack; (2) verify the residual double `updateCachedRows` (~230 ms, first one redundant) — that's a third of your remaining 0.5 s and is pure bookkeeping.
- **Is Table viable at 40k?** The rebuild is O(n) row-model construction + outline data-source rebuild; extrapolating your ~200 ms @ 3.3k gives ~2.4 s @ 40k — over budget before counting `SubagentHierarchyBuilder` (which does `URL(fileURLWithPath:)` per top-level session per sort — cache by path string; and cache the built hierarchy keyed by the id-set/sort signature). So: **Table is fine at your current scale and on borrowed time at 40k.** Rather than rewrite now, pin the decision to a measurement: generate a synthetic 40k `session_meta` fixture (the PerfBench harness can drive it), and if sort p95 > ~200 ms after the residual fixes, put `NSTableView` + `NSDiffableDataSource` (or plain `reloadData` — wholesale reorder is exactly the case diffable data sources are *worst* at and `reloadData` is best at) behind your existing `cachedRows` row model via `NSViewRepresentable`. The row model is already view-agnostic; the swap is contained.
- Note the symmetry with Problem A's lesson: diffing is for incremental change; wholesale reorder wants rebuild. `reloadData` on an `NSTableView` is the native expression of the same insight, without fighting SwiftUI for it.

---

## 6. Priority order (what I'd actually do)

1. **§1.1 quadratic fixes + regex caching + normalize-once** — days, flag-independent, shrinks every downstream number. Re-measure the 619k build; publish the new baseline before writing more windowing code.
2. **Phase 3 Tasks 4–5 as planned, then the §1.2 background-full-build swap** — deliberately *before* investing in loadOlder prepend polish and windowed Find. Re-scope Phase 4 after seeing how much the swap eats.
3. **FTS ingest re-wire + event-offset checkpoints in the same pass** (§2.2) — one workstream, closes D and reduces Phase 5 to a small seek-parameter PR. Then Phase 5.
4. **HUD debounce + snapshot gate** (§4) — kills the idle-energy symptom in days. Actor extraction + FSEvents as the structural follow-up.
5. **List residuals** (dedupe `updateCachedRows`, hierarchy cache, scroll-restore spike), then the **synthetic-40k measurement** that decides the NSTableView question with data instead of taste.

The one thing I'd stop doing: treating Phases 3→4→5 as a fixed sequence of increasing windowing sophistication. The window is scaffolding to get first-content-instant; the swap (§1.2) and the checkpoint index (§2.2) are what make the scaffolding mostly temporary. Build toward the version where the window is invisible.
