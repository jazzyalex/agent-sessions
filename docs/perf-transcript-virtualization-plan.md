# Plan — Virtualize Transcript Rendering (the AV speed gap)

**Status:** Proposal / not started
**Owner:** TBD
**Goal:** Close the single largest "AS feels slow vs AgentsView" gap: opening and scrolling large transcripts.
**Context:** See [competitive-agentsview.md](competitive-agentsview.md). The DB/index foundation is already sound — this doc is *only* about the view layer.

---

## 1. The problem, in code

The Session transcript renders the **entire** session into one `NSTextView`:

- `text` is one giant `String` (built by `SessionTranscriptBuilder`) assigned wholesale:
  - [`TranscriptPlainView.swift:3276`](../AgentSessions/Views/TranscriptPlainView.swift) (`makeNSView`) — `textView.string = text`
  - [`TranscriptPlainView.swift:3347`](../AgentSessions/Views/TranscriptPlainView.swift) (`updateNSView`) — `tv.string = text`
- Colorization runs over the **whole document** every time text/appearance/scheme/mode/monochrome/ranges change:
  - [`applySyntaxColors` :3600`](../AgentSessions/Views/TranscriptPlainView.swift) — `removeAttribute(.foregroundColor, range: full)` + `addAttribute(baseColor, range: full)` then iterates every role range; re-invoked at [`:3352`](../AgentSessions/Views/TranscriptPlainView.swift) on six different change signals.
- `layoutManager.allowsNonContiguousLayout = true` ([:3243](../AgentSessions/Views/TranscriptPlainView.swift)) helps TextKit defer *layout*, but does **not** help the O(document) work of building the giant `String`, assigning it, and re-coloring it.
- The terminal variant has the same shape: [`SessionTerminalView.swift`](../AgentSessions/Views/SessionTerminalView.swift) builds a full `[TerminalLine]` + attributed string with inline image attachments for the whole session.

**Net effect:** cost scales with total transcript size, not with what's on screen. A 10k-line session pays full layout + full colorization up front and again on every appearance toggle. AV renders only the visible window (constant DOM regardless of length) and fetches messages in pages.

---

## 2. Goal / acceptance criteria

- Opening a very large session (≥ 10k lines / several MB) shows first content in **< 150 ms** and is scroll-smooth (no multi-hundred-ms hitches).
- Memory and CPU scale with the **visible window**, not total transcript length.
- Appearance/scheme/mono/JSON-mode toggles do **not** trigger O(document) recolor.
- No regression to existing features that depend on the current single-text-view model:
  - In-transcript Find (Cmd+F) with highlight + next/prev ([`applyFindHighlights` :3771](../AgentSessions/Views/TranscriptPlainView.swift), `PlainFindLayoutManager`).
  - Text selection + copy across the whole transcript.
  - "Scroll to bottom" / bottom-proximity + top-proximity callbacks (live tail).
  - Markdown export (operates on the model, not the view — should be unaffected).
  - Deep-link / jump-to-range selection (`selection`, `scrollSelection`).

These constraints are the hard part: a naive `LazyVStack` of per-message views loses cross-message selection and the existing Find machinery. The plan must preserve them.

---

## 3. Options considered

### Option A — TextKit 2 viewport layout (keep one text view)
Move from the TextKit 1 `NSLayoutManager` path to **TextKit 2** (`NSTextLayoutManager` + `NSTextViewportLayoutController`) and let TextKit 2 lay out only the viewport's fragments. Coloring becomes *viewport-scoped* via the layout fragment callback instead of whole-document `addAttribute`.
- **Pros:** keeps one text view → selection, copy, and Find still work over a single text storage; smallest conceptual change to surrounding code; Apple's own answer to "huge documents."
- **Cons:** TextKit 2 on macOS has sharp edges (mixing with TextKit 1 APIs silently falls back; `NSTextView` interop is fiddly); still builds the full backing string unless paired with a paged text-storage.
- **Best when:** we want to preserve the exact current UX with the least surface-area change.

### Option B — Windowed/paged content (virtualized message list)
Render the transcript as a virtualized list of **message blocks** (mirrors AV): keep a windowed set of rendered blocks around the viewport, recycle off-screen ones, and back it with **windowed model fetches** (`messages WHERE ordinal >= ? LIMIT n`) so we never materialize the whole transcript string.
- **Pros:** true constant-cost rendering; matches AV's architecture; naturally enables per-block collapsing (tool blocks, thinking) which is *also* AV's transcript-quality lead — so this option doubles as the path to richer formatting.
- **Cons:** must rebuild Find (cross-block search + auto-expand of collapsed blocks) and selection/copy across block boundaries; larger refactor.
- **Best when:** we also want to pursue the richer transcript presentation (collapsible tool blocks, etc.).

### Option C — Chunked paging into the existing NSTextView
Keep the single `NSTextView` but only load a window of the string (e.g. ±N screens) and extend/trim as the user scrolls, anchored by the scroll observer that already exists ([`installScrollObserverIfNeeded`](../AgentSessions/Views/TranscriptPlainView.swift)).
- **Pros:** incremental; reuses Find/selection within the loaded window; smallest new infrastructure.
- **Cons:** selection/Find break *across* the unloaded boundary; scroll-anchor math is error-prone; a stop-gap, not a real fix.
- **Best when:** we want a fast partial win before committing to A or B.

---

## 4. Recommendation

> **Decision (2026-06-28):** A-vs-B is **deferred**. Do the quick wins first ([perf-quick-wins.md](perf-quick-wins.md), starting QW-1), get immediate speed, then revisit A vs B with that experience in hand. The analysis below stands for when we pick it back up.

**Two-phase:** ship the cheap recolor fix now, then do **Option A (TextKit 2 viewport)** as the structural fix — *unless* we decide to also pursue richer transcript formatting, in which case go **Option B**, since virtualized message blocks are the same substrate AV uses for collapsible tool/thinking blocks. Decide A-vs-B based on whether "richer transcript formatting" is on the roadmap; B is strictly more work but unlocks more.

Rationale: Option A preserves selection/Find/copy with the least risk to existing behavior and directly attacks the dominant cost (whole-document layout + recolor). Option C is only worth it as a throwaway if we need a demo-able win this week.

---

## 5. Phased steps

### Phase 0 — Make recolor cheap (no architecture change) — *do first regardless of A/B*
The recolor is whole-document and fires on appearance/scheme/mode/mono toggles that **don't actually change which characters get which color category**.
1. Precompute color *category spans* once when `text`/ranges change; store on the coordinator.
2. On pure appearance/scheme/mono/JSON-mode changes, recolor by **swapping attribute values over the already-known spans**, not by `removeAttribute`+`addAttribute` over `full` and re-deriving. (`applySyntaxColors` [:3600](../AgentSessions/Views/TranscriptPlainView.swift), invoked at [:3352](../AgentSessions/Views/TranscriptPlainView.swift).)
3. Better: scope the recolor to the **visible glyph range** (from the scroll view's `documentVisibleRect` → `glyphRange(forBoundingRect:)`) and lazily color the rest as it scrolls into view.
- *Outcome:* removes the per-toggle O(document) hit and most of the open-time recolor cost, with zero change to the view model. Low risk, high ratio.

### Phase 1 — Spike Option A (TextKit 2 viewport) behind a feature flag
1. Add `FeatureFlags.transcriptTextKit2` (default off) and a parallel `PlainTextScrollViewTK2` `NSViewRepresentable`.
2. Build it on `NSTextLayoutManager` + `NSTextContentStorage` + `NSTextViewportLayoutController`; color via the viewport fragment callback (visible fragments only).
3. Verify the four must-keep behaviors (Find, selection/copy, bottom/top proximity, jump-to-range) against the TextKit 2 view.
4. Benchmark against fixtures (see §7).

### Phase 2 — Windowed model fetch (only if going Option B, or if string-build itself is a bottleneck)
1. Add a paged transcript source: `messages WHERE session_id=? AND ordinal >= ? ORDER BY ordinal LIMIT n` (the index already supports this; mirror AV's `GetMessages`).
2. Build only the visible window's block models; recycle off-screen blocks.
3. Reimplement Find as a model-level search that maps hits → block + offset and auto-expands collapsed blocks (this is also the hook for collapsible tool/thinking blocks).

### Phase 3 — Cut over + delete the old path
1. Flip the flag on by default; soak.
2. Remove the legacy whole-document assignment + recolor once parity is confirmed.

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| TextKit 2 ↔ TextKit 1 interop silently degrades | Keep TK2 behind a flag; A/B against the TK1 view; never mix the two layout managers on one storage. |
| Find/selection regressions | Treat the four must-keep behaviors as acceptance gates; write fixtures before cutover. |
| Live-tail (running session append) breaks under windowing | Preserve the existing bottom-proximity append path; only window the *static* history, always keep the tail mounted. |
| Scope creep into "rich formatting" | Phase 0 + Option A are independently shippable; B is a separate, explicit decision. |

---

## 7. Validation

- **Fixtures:** synthesize sessions at 1k / 10k / 50k lines and a multi-MB tool-output-heavy session. (AV's `internal/backendbench` uses N sessions × M messages — same idea.)
- **Metrics:** time-to-first-content on open; scroll frame time (Instruments / `os_signpost`); recolor time on appearance toggle; peak memory.
- **Targets:** < 150 ms first content at 10k lines; no recolor on appearance toggle; constant memory vs length.
- **Regression suite:** Find next/prev across the whole doc, select-all + copy fidelity, jump-to-range, live-tail append, markdown export unchanged.

---

## 8. Out of scope
- Search throttles, Cursor FTS exclusion, tokenizer memoization, LRU cache, JSONL parser, Combine fan-in → these are independent and live in [perf-quick-wins.md](perf-quick-wins.md).
- Richer transcript *content* (markdown rendering, collapsible blocks) is a related but separate feature effort; Option B is the enabling substrate if we pursue it.
