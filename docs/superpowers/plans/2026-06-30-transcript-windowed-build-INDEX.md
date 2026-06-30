# Windowed Transcript Build — Plan Index & Cross-Phase Reconciliation

These four phase plans implement the windowed transcript build from
[the design spec](../specs/2026-06-29-transcript-progressive-windowed-build-design.md).
Read this index first: it pins the shared contract so the phases compose, and gives the
build order. (Phase 1 — the large-session guardrail + TL-1 — already shipped, commit `6b72fb2e`.)

## Plans & build order

Build **strictly in this order** (each depends on the prior):

1. [Phase 2 — Stable global identities](2026-06-30-transcript-phase2-global-identities.md) — foundational substrate; zero behavior change, parity-tested.
2. [Phase 3 — Windowed build on open + load-older/newer](2026-06-30-transcript-phase3-windowed-build.md) — depends on Phase 2's global ids.
3. [Phase 4 — Bidirectional Find + counts + jump](2026-06-30-transcript-phase4-find-jump.md) and [Phase 5 — Tail/partial parse](2026-06-30-transcript-phase5-parse-windowing.md) — both depend on Phase 3; can be built in parallel.

## Canonical shared contract (from Phase 2 — all phases use these names)

- **`LogicalBlock.globalBlockIndex`** — `0…N-1` over the full coalesced-block stream (coalescing runs once over all events; cheap, stable). Assigned in `SessionTranscriptBuilder.coalesce`.
- **`TerminalLine.id = globalBlockIndex * STRIDE + lineOrdinalWithinBlock`** (STRIDE = 1_000_000). Stable, globally unique, monotonic in render order; never an array subscript (verified). Synthetic/negative `blockIndex` sentinels preserved.
- **`TerminalLine.blockIndex = globalBlockIndex`** — the join key shared by `CodexSessionImagePayload` (inline images) and the renderer.
- **`TerminalLine.eventIndex`** — populated from the block's first originating event (was nil).
- **Flag:** `FeatureFlags.transcriptWindowedBuild` (default **false**). Added **once** in Phase 2 Task 1; Phase 3/4's "add the flag" tasks are defensive (skip if present). Flag OFF = today's whole-session build, byte-identical.

## Three seams to reconcile during the build

1. **Phase 3 must expose the windower API that Phase 4 assumes.** Phase 4 consumes `loadedBlockRange` and **`func ensureBlockLoaded(_ globalBlockIndex: Int)`** (synchronously extend the window older/newer to include that block, preserving scroll anchor, updating `lines`/`lineRanges`). Phase 3 currently defines `TranscriptWindow` (`lowerBlock…upperBlock`) + `loadOlder()`/`loadNewer()`/`expandedOlder/Newer`. **Action:** in Phase 3, also expose `loadedBlockRange` (from the window) and `ensureBlockLoaded(_:)` (loop `loadOlder`/`loadNewer` until the block is in range). Add it to Phase 3's task list before Phase 4 starts.

2. **Phase 3's `loadOlder` must drive Phase 5's `parseMoreOlder` for partial sessions.** Phase 5 parses only the tail on open (`isPartiallyParsed`, `parsedFromLineIndex`) and exposes `parseMoreOlder(id:)`. When a session is partially parsed, Phase 3's `loadOlder` must first ensure the older events exist (call `parseMoreOlder` if the requested older blocks fall before `parsedFromLineIndex`) before slicing/building them. **Action:** Phase 3 `loadOlder` checks `session.isPartiallyParsed`; if so, requests more events via the Phase 5 hook, then windows. Both gated (`transcriptWindowedBuild` + `transcriptTailParse`); if Phase 5 isn't built yet, the session is simply fully parsed (Phase 1 guardrail still applies), so Phase 3 works without Phase 5.

3. **Flags & gates are additive, not duplicated.** `transcriptWindowedBuild` (Phases 2–4) and `transcriptTailParse` (Phase 5) are distinct. Phase 5 extends the **existing** `TranscriptHydrationGate` (Phase 1) with `isTailParseCapable` / `shouldTailParse` — it does not introduce a second gate.

## Acceptance for the whole effort (unchanged from the spec)
A hydrated 619k-line session opens < 150 ms with memory bounded by the window; Find/jump/live-tail/images/links/Copy/export preserved; cold monster sessions open fast once Phase 5 lands (then the Phase 1 interstitial can be relaxed/retired). Everything behind the flags, parity-gated before any default flip — and the flip is a human decision.
