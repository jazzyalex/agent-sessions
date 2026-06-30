# Design: Progressive Windowed Transcript Build (terminal renderer)

**Date:** 2026-06-29
**Status:** Design — pending user review before implementation plan
**Supersedes:** the earlier per-block "Option B" spec (removed) and `perf-transcript-virtualization-plan.md` Options A/B — both retargeted by profiling.

## Problem (profiled, not assumed)

Default mode is **terminal** ([TranscriptPlainView.swift:527](../../../AgentSessions/Views/TranscriptPlainView.swift)) → **`SessionTerminalView`** ([:872](../../../AgentSessions/Views/TranscriptPlainView.swift)), not the plain `NSTextView`. Profiling the real open path (file-based timers, since removed):

| Stage | What | Cost |
|---|---|---|
| **1. Model build** | `buildRebuildResult` = `coalescedBlocks` + `TerminalBuilder.buildLines` | **~90% of open; 926 ms @ 5.7k lines; 30,653 ms @ 619k lines** |
| 2. Attr build | `buildAttributedString` | 10–40 ms @ 100k chars |
| 3. Set + layout | `setAttributedString` + TextKit | 20–50 ms @ 100k chars |

The whole-session **model build** dominates. Attr-build and TextKit layout — the parts in the single `NSTextView` — are cheap. So: keep the text view; stop building the whole session.

**Separately, there is a cold-parse wall.** Selecting a session whose events aren't loaded calls `reloadSession` → **`parseFileFull` parses the entire file before events exist** ([SessionIndexer.swift:430](../../../AgentSessions/Services/SessionIndexer.swift)). The build profile above is measured *after* hydration. A build cap does nothing for the parse.

## Goal / Non-Goals

**Goals**
- For an **already-hydrated** session (events in memory), open cost is bounded by a **window of blocks**, not the whole session: first content < 150 ms; memory scales with the window.
- A hydrated 619k-line session opens fast instead of 30 s + beachball.
- Keep `SessionTerminalView`'s features within the loaded window: inline images, linkification, role/semantic filters+nav, Find, selection, Copy Block/Speak, export, live-tail.

**Non-Goals (this phase)**
- Per-block view virtualization (profile: attr/layout are cheap).
- Richer formatting (markdown/collapsible) — separate.
- **Windowing the event parse.** Cold huge sessions still pay `parseFileFull`. The **<150 ms metric is scoped to hydrated sessions**; cold monster sessions are handled by the **guardrail gating auto-hydration** (below). True cold-instant requires **tail/partial parsing** (parse only recent events) — a larger per-provider parser change, called out as a **required follow-on phase**, not done here.

## Decisions (locked with user, profile-driven)
- **Window the build into the existing single `NSTextView`** (progressive load, AV's model). Keep renderer/attr/layout.
- Selection / Find / features operate on the **loaded window** (accepted). Reaching off-window content loads more.
- Ship **TL-1** (build QoS) and a **guardrail** alongside.

## Architecture

A **loaded window** over the in-memory events, defined by a range of **whole coalesced blocks** (not raw event counts). On open, build only the last window. On scroll-near-top, prepend the previous window; live-tail appends; Find/jump load windows in either direction. Stable global identities make prepend non-destructive.

```
open (hydrated) → window = last N blocks → buildLines(slice) → applyContent (fast)
scroll near top → loadOlder() → prepend → restore scroll anchor by global line id
scroll near bottom / live-tail → loadNewer()/append
Find/jump to off-window target → load toward it (older or newer) → scroll + highlight
```

## Components

- **Window unit = whole coalesced blocks, boundary-safe.** The coalescer merges assistant/tool deltas **across events** (`canMerge`, [SessionTranscriptBuilder.swift:448](../../../AgentSessions/Services/SessionTranscriptBuilder.swift)). The window must **never cut inside a merge chain** (same `messageID` / delta run / `toolName`). Rule: coalesce over the full event stream once to get **block boundaries** (cheap — coalescing is text-append, far less than line-splitting), then window by **block index**; or expand any event-range boundary outward to the enclosing block. Each block is built into lines **exactly once**; prepend **dedupes by global block id**.
- **Stable global identities (model change, required).** `TerminalLine.id` and `blockIndex` must derive from the **global block index / `eventIndex`** (the `TerminalLine.eventIndex` field exists but is `nil` today — populate it), **not** local `blocks.enumerated()` / `nextID` from 0 ([TerminalModels.swift:81](../../../AgentSessions/Services/TerminalModels.swift),[:84](../../../AgentSessions/Services/TerminalModels.swift)). Prepending older content must not renumber existing lines.
- **Inline image reconciliation.** The image mapper yields **full-session user-block indexes** ([CodexSessionImagePayload.swift:56](../../../AgentSessions/Utilities/CodexSessionImagePayload.swift)); the renderer attaches by `line.blockIndex` ([SessionTerminalView.swift:5000](../../../AgentSessions/Views/SessionTerminalView.swift)). Both must key off the **same global block identity**, so a thumbnail lands on the right block regardless of which window is loaded.
- **Index maps.** `userLineIndices` / role indices / `eventIDToUserLineID` / `conversationStartLineID` recomputed from the loaded slice **using global ids**; unit-tested for parity against the whole-session build on small fixtures.
- **Load-older / load-newer triggers.** Reuse `isNearTranscriptTop` / `updateTopProximity`; add a near-bottom symmetric trigger. **Preserve scroll anchor** by capturing a stable **global** top line id + offset before prepend and restoring after.
- **Find (bidirectional + counts).** Run a **model-level text scan over `Session.events`** (cheap — text only, no line build) to get **accurate total match count + each match's global block/ordinal** up front. Next/prev navigates that match list, **loading older *or* newer** windows as needed to bring the target into the window, then highlights. Wrap: next past last → first (and load that window); prev past first → last.
- **Guardrail (Phase 1, ships first, addresses the parse wall) — one central hydration gate.** Selecting a session fans out to **three** paths that can each call `parseFileFull`:
  1. Direct per-source reload ([UnifiedSessionsView.swift:1963–1992](../../../AgentSessions/Views/UnifiedSessionsView.swift) → `xIndexer.reloadSession`).
  2. `searchCoordinator.prewarmTranscriptIfNeeded(… allowParsingLightweight:)` ([:1995](../../../AgentSessions/Views/UnifiedSessionsView.swift) → [SearchCoordinator.swift:128/152](../../../AgentSessions/Search/SearchCoordinator.swift)).
  3. `updateFocusedSessionIfNeeded` → `setFocusedSession` → `refreshFocusedSession(trigger: .selection)` ([:1996](../../../AgentSessions/Views/UnifiedSessionsView.swift) → [UnifiedSessionIndexer.swift:1326/1349](../../../AgentSessions/Services/UnifiedSessionIndexer.swift)).

  The guardrail must be a **single `shouldAutoHydrate(_ session) -> Bool`** check (size/message threshold + an explicit per-session override) consulted by **all three**, not just the direct reload. Over threshold and no override → none of the three parse; the transcript area shows a "Large session — Show full transcript" affordance whose action sets the override and re-runs hydration. Gating only the direct reload is a trap: `prewarmTranscriptIfNeeded` or the focused-session reload would still fire `parseFileFull`.

## Must-keep behaviors → handling

| Behavior | Handling |
|---|---|
| Inline images, linkification, filters+nav, Copy Block/Speak | Preserved via the existing single storage, keyed off **global block identity**, applied over the loaded window. |
| In-session Find next/prev + counts | Counts from the up-front model scan; navigation loads older/newer to reach each match; wrap defined. |
| Selection / copy | Within the loaded window (accepted); Copy Block + export unchanged. |
| Live-tail / jump-to-range / first-prompt | Append path / load the containing window then scroll. |

## Phasing
1. **Guardrail + TL-1** — a single central `shouldAutoHydrate` gate consulted by **all three** selection hydration paths (direct reload, search prewarm, focused-session reload), with a "Show full transcript" override; plus build at `.userInitiated` (TL-1). Small, independently shippable, immediate.
2. **Stable global identities** in the line/block model (`eventIndex`-based ids; image mapping reconciled) — prerequisite, behind `FeatureFlags.transcriptWindowedBuild`. Parity-tested vs whole-session build.
3. **Windowed build on open** (last window) + load-older/newer with scroll-anchor + index recompute.
4. **Bidirectional Find + counts** (model scan) + jump-to-range; parity gates; flip default; remove whole-session build.
5. **(Follow-on, separate)** tail/partial **parse** for cold-instant on monster sessions.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Window boundary splits a merged block / dupes on prepend | Window by **whole coalesced blocks**; build each block once; dedupe by global id. |
| Local ids renumber on prepend; images mis-attach | **Global identities** (`eventIndex`-based) for lines/blocks; image mapper + renderer key off the same global id; parity tests. |
| Cold-parse wall (out of scope) defeats <150 ms | Metric scoped to hydrated; guardrail gates cold monster auto-hydration; tail-parse is a named follow-on phase. |
| Scroll-anchor jump on prepend | Anchor on a stable **global** line id + offset; test at multiple window sizes. |
| Find counts/direction wrong across windows | Up-front model scan for counts+locations; bidirectional load; explicit wrap semantics; tests. |
| Big-bang regression | Behind a flag; parity-gated vs whole-session build before removal. |

## Testing / acceptance
- **Fixtures:** 1k / 10k / 50k / ~600k-line sessions; one delta/tool-stream that crosses a window boundary; one with inline images near a boundary.
- **Unit:** windowed build parity with whole-session build (same lines/indices for a full window); global-id stability across prepend; image attach by global id; Find scan counts/locations.
- **Metrics:** hydrated first content < 150 ms; memory bounded by window; hydrated 619k-line session opens fast.
- **Regression gates:** Find next/prev (incl. off-window, wrap, counts), jump-to-range, first-prompt, live-tail, filters, inline images at boundary, linkification, Copy Block, export.
- Behind `FeatureFlags.transcriptWindowedBuild`; parity-gated before deleting the whole-session path.
