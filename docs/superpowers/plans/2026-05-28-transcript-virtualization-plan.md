# Transcript Virtualization Handoff

Date: 2026-05-28
Repository: `/Users/alexm/Repository/Codex-History`
Branch: `docs/transcript-virtualization-plan`
Status: implementation-ready plan, no app code changed in this document.

## Summary

Agent Sessions currently renders the selected session transcript as one full AppKit text document. That keeps the transcript readable and gives strong native text behavior, but it means very large Codex/Claude/Gemini/OpenCode/Copilot/Droid/OpenClaw/Cursor/Pi histories still force the app to build and apply a full attributed transcript when the user opens or switches to a huge session.

The proposed improvement is block-level transcript virtualization: keep full parsing and full-text search/indexing available, but render only the visible transcript blocks plus a buffer above and below the viewport.

This should materially improve visual performance for pathological-size sessions:

- Faster first visual paint after selecting a huge session.
- Less visible delay when switching between the sessions list and transcript pane.
- Lower memory pressure from hidden rich transcript content, inline image attachments, link attributes, block decorations, and search overlays.
- More responsive scrolling through large transcripts because only nearby rows are mounted, constructed, and measured.

This is not a simple `LazyVStack` change. The transcript rows have variable height and rich behavior: markdown-like content, tool call/output formatting, code/diff line numbers, inline images, linkification, search highlights, role navigation, image navigation, event jumps, and native text selection/copy expectations. The implementation should treat this as a renderer subsystem project.

## Recommended Decision

Build this on a separate feature branch, not directly on `main`.

Recommended branch name:

```bash
git switch -c feat/transcript-block-virtualization
```

Recommended scope for the first implementation branch:

- Terminal/session transcript mode only.
- Block-level virtualization, not individual physical-line virtualization.
- Phase 0 and Phase 1 are instrumentation/refactoring only. They should not change visible UI/UX.
- Keep the existing full `NSTextView` renderer as the only active renderer until a later implementation step is explicitly approved.
- Keep global/full-text search and indexing independent from viewport rendering.
- Do not change parser formats, session storage, database schema, or provider support unless a measured blocker requires it.
- Do not add feature flags, rollout flags, kill switches, renderer preference toggles, or hidden behavior gates unless the user explicitly asks for them in that implementation session.

## Current Renderer Evidence

### Transcript host and provider switching

The unified sessions pane uses a stable transcript host:

- `AgentSessions/Views/UnifiedSessionsView.swift`
  - `transcriptPane` mounts `TranscriptHostView`.
  - `TranscriptHostView` mounts provider-specific transcript views in a `ZStack` and switches them with opacity.

Important implication:

The visible delay during session switching may have two contributors:

1. The selected transcript renderer doing too much work.
2. Hidden provider transcript views still being mounted and observed through the stable `ZStack`.

Do not assume virtualization alone fixes every switch delay until instrumentation separates those costs. Treat hidden-provider host churn as a Phase 0 instrumentation target, not only a future risk. The host currently keeps inactive provider views mounted, so provider-specific `@ObservedObject` updates and body recomputation may be a measurable part of switch latency independent of transcript virtualization.

### Terminal view entry point

The terminal transcript path is:

- `AgentSessions/Views/TranscriptPlainView.swift`
  - `terminalTranscriptView(session:)` constructs `SessionTerminalView`.
- `AgentSessions/Views/SessionTerminalView.swift`
  - `content` passes `filteredLines` into `TerminalTextScrollView`.
- `AgentSessions/Views/SessionTerminalView.swift`
  - `TerminalTextScrollView` is an `NSViewRepresentable` that wraps one `NSScrollView` and one `TerminalTextView`.

### Current line model

The current terminal transcript model is line-level:

- `AgentSessions/Services/TerminalModels.swift`
  - `TerminalLineRole`
  - `SemanticKind`
  - `TerminalLine`
  - `TerminalBuilder.buildLines(from:source:enableReviewCards:)`

`TerminalLine.id` is currently an incremental index and is used for identity, navigation, search mapping, and scroll targets.

Important implication:

Virtualization should keep stable line/block identifiers, but it should not use physical rendered rows as the primary virtualized unit. Physical lines are too granular and too sensitive to wrapping, font size, code line-number prefixes, and inline image insertion.

### Current full-document rendering cost

`TerminalTextScrollView` currently creates an AppKit text stack:

- `NSTextStorage`
- custom `TerminalLayoutManager`
- `NSTextContainer`
- custom `TerminalTextView`

The high-pressure path is:

- `applyContent(to:context:)`
- `buildAttributedString(containerWidth:coordinator:)`
- `textView.textStorage?.setAttributedString(attr)`
- `buildBlockDecorations(ranges:)`
- `TerminalLayoutManager.lineIndex` rebuilds from every line/range
- layout manager highlight/decorations metadata updates

This means the app still constructs and applies a single attributed representation of all visible lines for the selected session. For a huge transcript, "visible lines" normally means the entire filtered transcript, not the viewport.

### Existing mitigations already in place

The current code already has meaningful performance work:

- Off-main rebuild task in `SessionTerminalView.rebuildLines(...)`.
- Tail patching through `tailPatchStrategy(previous:current:)`, but this is only partial: append paths still rebuild all-line metadata such as `TerminalLayoutManager.lineIndex` and `buildBlockDecorations(ranges:)`.
- AppKit `allowsNonContiguousLayout = true`, which means text layout/drawing is already lazy/viewport-bounded compared with a naive full-document layout.
- Separate full and visible search snapshots.
- Cached/external transcript build paths in `TranscriptPlainView`.
- Feature flags for lower QoS, throttled search/index updates, coalesced results, and off-main transcript build.

Important implication:

If large transcripts still show visual delays, the remaining bottleneck is probably not only raw JSONL parsing. It is likely dominated by main-actor construction and mutation work: full attributed-string construction, full text storage replacement, full decoration metadata, all-line range/index rebuilds, and tail-append metadata rebuilds. Do not frame the main cold-open problem as full AppKit layout/drawing; AppKit layout and custom drawing are already substantially viewport-bounded. Phase 0 must measure construction versus layout so the implementation proves the right win.

## User-Visible Problem Statement

Large agent sessions can contain massive JSONL histories after long runs, compaction, repeated tool output, or image-heavy prompts. Agent Sessions can still parse and search those sessions, but opening or switching to them can visibly lag because the transcript view is optimized for readable full-document rendering, not pathological-size log viewing.

Short public wording:

```text
Agent Sessions currently uses a straightforward readable transcript renderer, not a pathological-size log viewer. Very large sessions can still be searched, but opening and scrolling them would benefit from virtualized transcript rendering.
```

## UI/UX Impact

Ideal product impact:

- Phase 0 instrumentation should have no visible UI/UX impact.
- Phase 1 model extraction should be pure refactoring. The active transcript renderer should remain the current `NSTextView` path.
- Phase 2 layout/search tests should not mount a new user-visible renderer.
- The first visible change should be performance: huge transcripts open, switch, and scroll faster.

Behavior that should remain unchanged before virtual mode is allowed to replace the current renderer:

- Transcript text, wrapping, card spacing, role colors, semantic code/diff/plan/review rendering, and line-number display.
- Cmd-F find bar behavior, Cmd-G / Shift-Cmd-G navigation, and Escape behavior.
- Global search selection handoff and in-transcript highlight counts.
- Role navigation shortcuts for users, tools, and errors.
- Copy full transcript, selected text copy, export Markdown, context menus, speak/stop speaking, link clicks, and inline image actions.
- Scroll-to-bottom, jump-to-first/last prompt, event jumps, image-browser jumps, and focus return to the transcript.
- Accessibility/focus behavior and first-responder ownership.

Potential user-visible differences if virtual mode later becomes active:

- Full-document native `NSTextView` selection may become block-local unless custom cross-block selection is added.
- The native macOS find panel cannot search unmounted blocks; Cmd-F must route through the transcript-local find UI.
- Search or event jumps can briefly correct their scroll offset after an unmounted target block is measured.
- Extremely image-heavy blocks should keep fixed placeholder dimensions so image decoding does not move surrounding content.

Product recommendation:

Treat Phase 0 and Phase 1 as no-UI-change refactoring. Do not ship virtual mode as the active renderer until the parity checklist above passes or the remaining differences are explicitly accepted as product tradeoffs.

If the desired scope stays "only refactoring," stop after instrumentation, model extraction, shared-type extraction, and tests. The virtual renderer becomes user-visible only in a later product-change phase.

Stage-by-stage UI policy:

- Phase 0: no UI change; instrumentation only.
- Phase 1: no UI change; the same `NSTextView` renderer stays active.
- Phase 2: no UI change; layout/search math is exercised in tests.
- Phase 3: no normal-app UI change; virtual rendering is exercised through tests, previews, or a branch-local manual harness unless active wiring is explicitly approved.
- Phase 4 through Phase 6: parity work may add implementation code, but it should not replace the active renderer until the parity checklist passes.
- Phase 7: first intentional user-visible product change. Huge sessions may use virtual rendering after explicit approval and calibrated thresholds.

## Target Behavior

The final virtualized transcript should behave like this:

- The scrollbar represents the full transcript height.
- Only visible blocks plus a configurable overscan buffer are mounted.
- Full-text search/indexing still covers the entire session.
- Search jump and role navigation can jump to a match or event that is not currently mounted.
- Highlight navigation does not drift as row heights are measured and corrected.
- Opening a huge session quickly shows the nearest target region:
  - default last user prompt,
  - first prompt,
  - requested event,
  - requested search match,
  - or bottom/tail for live append.
- Scrolling remains responsive with tens of thousands of transcript lines.
- Inline images do not decode or mount outside the visible buffer.
- Linkification only resolves/render-attaches links for mounted blocks, while full search remains independent.

## Size Threshold Policy

Do not define "huge session" by message count alone. Message count is useful telemetry, but a single tool-output message can be larger and more expensive than hundreds of normal chat messages.

Use these initial threshold candidates for Phase 0 calibration:

- Keep the old full `NSTextView` renderer for ordinary sessions below roughly `10_000` rendered terminal lines and below roughly `10 MB` raw transcript size.
- Treat a session as a virtual-renderer candidate when it exceeds roughly `10_000` rendered terminal lines, exceeds roughly `10 MB` raw transcript size, or measured full attributed render/apply time exceeds roughly `300 ms`.
- Treat a session as definitely pathological when it reaches `50_000+` rendered terminal lines, contains very large JSONL/tool output, is image-heavy, or causes visible beachball/spinner behavior in the current renderer.

Preferred activation signals after Phase 0:

- Rendered terminal line count.
- Raw transcript file size.
- Attributed string build time.
- Text storage apply time.
- Decoration/index/metadata rebuild time.
- Time to first visible transcript paint.
- Memory increase after selecting the session.

Message count should be collected, but it should not be the primary activation signal.

These are starting points, not final constants. The implementation session should use instrumentation to compare small, medium, large, and pathological transcripts before choosing any product threshold for Phase 7.

## Non-Goals For First Implementation

Do not include these in the first branch unless explicitly requested:

- No parser format redesign.
- No database schema change.
- No new provider support.
- No feature flags, rollout flags, kill switches, renderer preference toggles, or hidden behavior gates.
- No public marketing copy changes until the feature is implemented and validated.
- No attempt to perfectly match native `NSTextView` continuous selection in the first prototype.
- No optimization of global search/indexing beyond keeping it independent from viewport rendering.
- No complete rewrite of JSON/raw transcript modes.

## Architecture Recommendation

### Virtualize transcript blocks, not physical lines

Use logical transcript blocks as the primary virtual item. A block corresponds roughly to a user message, assistant message, tool call, tool output, error block, meta block, code block, diff block, plan block, review card block, or synthetic rendered block.

Reasons:

- Blocks are stable across wrapping width changes.
- Blocks match the visual card/decorations model.
- Blocks match current navigation intent better than arbitrary wrapped lines.
- Blocks can own inline images and link attributes.
- Blocks can be measured and cached independently.
- Blocks reduce mounted view count compared with per-line virtualization.

### Proposed core models

Create a renderer model separate from parser/session models:

```swift
struct TranscriptRenderBlock: Identifiable, Sendable {
    let id: TranscriptRenderBlockID
    let sourceEventID: String?
    let logicalBlockIndex: Int?
    let decorationGroupID: Int
    let role: TerminalLineRole
    let semanticKind: SemanticKind?
    let blockKind: TranscriptVisualBlockKind
    let lines: [TerminalLine]
    let searchText: String
    let renderedPlainText: String
    let inlineImages: [TranscriptInlineImageAnchor]
    let hasLinkifiableText: Bool
}

struct TranscriptRenderBlockID: Hashable, Sendable {
    let sessionID: String
    let decorationGroupID: Int
    let logicalBlockIndex: Int?
    let eventID: String?
    let segmentOrdinal: Int
}

struct TranscriptBlockMeasurement: Sendable {
    let blockID: TranscriptRenderBlockID
    let width: CGFloat
    let fontSize: CGFloat
    let contentSignature: Int
    let measuredHeight: CGFloat
}
```

Do not make this exact shape mandatory. The important contract is:

- Stable identity.
- Clear mapping back to event/logical block.
- Render text separate from search text.
- Measurement can be invalidated by width, font size, display options, linkification, line numbers, inline images, and content signature.

Important visual-block unit:

The current renderer draws cards by contiguous `decorationGroupID` transitions, not by raw `SessionTranscriptBuilder.LogicalBlock` alone. One logical block can split into multiple visual card groups, for example assistant prose plus code, diff, plan, or review-summary segments. Center virtual block identity on `decorationGroupID`, with `logicalBlockIndex` and `eventID` as metadata, so the virtual model matches the actual card geometry.

Identity stability boundary:

`decorationGroupID` is the right current visual-card key, but it is derived from the built terminal line model rather than being a persisted storage identity. Treat `TranscriptRenderBlockID` as stable for a given session content signature and renderer/parser version. Do not persist it outside the renderer cache, and keep `eventID`, `logicalBlockIndex`, and `segmentOrdinal` as fallback metadata for rebuilding mappings after parser or renderer changes.

Important dependency:

`InlineSessionImage` is currently private inside `SessionTerminalView.swift`. A new renderer file cannot reuse that type until it is hoisted into a shared transcript-rendering module or replaced by a new shared image-anchor model such as `TranscriptInlineImageAnchor`.

### Proposed layout engine

Add a `TranscriptVirtualLayout` object that owns:

- Ordered block IDs.
- Estimated heights for unmeasured blocks.
- Measured heights for mounted/measured blocks.
- Prefix-sum height index.
- Total estimated content height.
- `blockID -> yRange` mapping.
- `yOffset -> blockIndex` lookup.
- Invalidations for width/font/preference/session changes.

Required operations:

```swift
func totalHeight() -> CGFloat
func visibleRange(for viewport: CGRect, overscan: CGFloat) -> Range<Int>
func yOffset(for blockID: TranscriptRenderBlockID, anchor: TranscriptScrollAnchor) -> CGFloat?
func blockIndex(at yOffset: CGFloat) -> Int
func applyMeasurement(_ measurement: TranscriptBlockMeasurement)
func invalidateMeasurements(reason: TranscriptMeasurementInvalidationReason)
```

Implementation detail:

- Start with a simple prefix array and binary search.
- This mirrors the existing `TextSnapshot` binary lookup pattern for character-range to line-ID mapping, but applies it to y-offset to block-index mapping.
- If updates become too expensive for huge sessions, move to a Fenwick tree or segment tree later.
- Do not prematurely introduce a complex data structure before profiling.

### Proposed scroll view

Implement an AppKit-backed virtual scroll surface rather than a SwiftUI `LazyVStack` first.

Suggested first class names:

- `VirtualTranscriptScrollView: NSViewRepresentable`
- `VirtualTranscriptDocumentView: NSView`
- `TranscriptBlockHostingView`
- `TranscriptBlockView`

Why AppKit first:

- The current renderer is already AppKit-backed.
- Precise scroll offset and document height control are easier with `NSScrollView`.
- Search jumps, top alignment, bottom proximity, and scroll preservation are already expressed in AppKit terms.
- SwiftUI `LazyVStack` does not provide enough control for stable variable-height scrollbar behavior and jump-to-unmounted-row precision.

The document view should:

- Have a frame height equal to `layout.totalHeight()`.
- Mount only block subviews in the visible+overscan range.
- Position each block view at its computed y offset.
- Recycle or reuse block hosting views where practical.
- Report measurements back after layout.
- Keep a spacer-like full document height so the scrollbar reflects the whole transcript.

### Renderer migration boundary

Keep the existing full `NSTextView` renderer active during Phase 0 and Phase 1. The virtual renderer can be developed and tested as a separate implementation on the feature branch, but do not add runtime feature flags, preference toggles, hidden switches, or rollout gates.

When a later implementation step is explicitly approved to make virtual rendering active, wire it directly for the agreed scope and keep the old renderer code available only as an internal fallback path until parity is proven. If rollback controls are desired, ask for that explicitly before adding them.

## Search And Navigation Design

### Separate global search from in-transcript find

There are two distinct search systems:

1. Global/unified session search scans across all sessions. This is FTS/cache/search-pipeline work in `SearchSessionStore`, `SearchCoordinator`, `UnifiedSearchState`, and `SessionSearchTextBuilder`. It is already independent of transcript rendering and should not be refactored for virtualization.
2. In-transcript find/navigation operates inside the selected transcript. In terminal mode, `SessionTerminalView` builds private `TextSnapshot` values for full and visible line sets, uses `SearchTextMatcher.matchRanges(...)`, maps ranges back to line IDs, and scrolls the mounted `NSTextView` ranges.

Virtualization should replace the second system's renderer-coupled snapshot with a transcript-local snapshot that can jump to unmounted blocks. It should reuse existing session search text only as an input/contract reference, not by moving global FTS into the renderer.

Existing rendered-text contract:

`SessionTerminalView.buildTextSnapshot(...)` and `TerminalTextScrollView.buildAttributedString(...)` already call the same `renderedTranscriptLineText(...)` helper. Preserve and extract that contract rather than inventing a second text-normalization path. The risk is not that rendered and search text are currently divergent; the risk is accidentally diverging them during extraction.

Native find-panel gap:

The current full renderer sets `textView.usesFindPanel = true`, so macOS native find operates over the full `NSTextView` storage. A virtual renderer cannot keep that behavior by default because only mounted blocks exist in the view tree. Virtual mode must disable or intercept native find and route Cmd-F / find navigation through the transcript-local snapshot.

Command, focus, and first-responder surface:

Virtual mode must preserve the app-level command path, not only renderer-local search:

- `AgentSessionsApp` Search menu posts `.openTranscriptFindFromMenu`.
- `UnifiedSessionsView` forwards that notification through `WindowFocusCoordinator`.
- `TranscriptPlainView` owns the find bar, hidden shortcut buttons, Cmd-F, Cmd-G, Shift-Cmd-G, Escape, and terminal find tokens.
- `SessionTerminalView` currently passes `transcriptFocusToken` / `focusRequestToken` into `TerminalTextScrollView`, which calls `window.makeFirstResponder(tv)`.

Catalog and test this focus chain before replacing the renderer. The virtual scroll view must either become the first responder itself or forward focus to a mounted selectable child without breaking menu commands, shortcut handling, image-browser jumps, or event-jump focus return.

Recommended model:

```swift
struct TranscriptSearchSnapshot {
    let text: String
    let blockRanges: [TranscriptRenderBlockID: NSRange]
    let lineRanges: [Int: NSRange]
    let orderedBlocks: [(id: TranscriptRenderBlockID, range: NSRange)]
    let orderedLines: [(lineID: Int, range: NSRange)]
}
```

Search behavior:

- Global session search remains outside the renderer. The selected transcript receives a query/current-result state from the existing search UI.
- In-transcript find scans the transcript-local snapshot, not mounted block views.
- The current match stores both `blockID` and line/match range.
- If the match block is not mounted, scroll to estimated `yOffset(for:blockID)`.
- After the block mounts and measurement updates, correct the scroll offset if needed.
- Highlight drawing is local to the mounted block view, using match ranges projected into that block.

### Role navigation

Current role navigation uses line IDs for user/tool/error movement. In the virtual renderer, store role navigation targets as block IDs with optional line IDs.

Suggested target model:

```swift
struct TranscriptNavigationTarget: Sendable, Hashable {
    let blockID: TranscriptRenderBlockID
    let lineID: Int?
    let kind: TranscriptNavigationKind
}
```

Navigation target families:

- First user prompt.
- Last user prompt.
- Next/previous user prompt.
- Next/previous tool call/output.
- Next/previous error.
- Next/previous semantic kind.
- Next/previous inline image prompt.
- Event ID jump.
- Search match jump.

### Open exact message / event behavior

Do not rely on visible rows for exact message opening. Maintain a stable map:

```swift
[String: TranscriptRenderBlockID] // eventID -> blockID
```

For events that currently map to nearest user prompt, preserve the same behavior unless product direction changes.

### Scroll anchoring

The virtual renderer must support these anchors:

- Top align target block.
- Nearest/visible scroll target.
- Bottom/tail.
- Preserve current top block across width/font/session-tail updates.
- Preserve bottom proximity during live append.

For preserving scroll during remeasurement:

- Track the current anchor block and local offset within that block.
- When measurements change above the anchor, adjust `scrollView.contentView.bounds.origin.y` so the anchor stays visually stable.

Current scroll/jump surface to replace:

The full renderer resolves most navigation through `coordinator.lineRanges[lineID] -> NSRange`, then asks `NSTextView`/`NSLayoutManager` to scroll or compute glyph bounds. Virtual mode must re-express each of these through `yOffset(for:blockID:)` plus anchor correction:

- Local find auto-scroll.
- Unified search auto-scroll.
- Explicit scroll target / top-align jump.
- Role navigation scroll.
- Scroll-to-bottom.
- Glyph-rect-based `scrollRangeToTop(...)`.

This is the dominant Phase 3-4 integration cost. Search highlighting is only one consumer of the same scroll-target rewrite.

## Selection And Copy Strategy

This is the biggest product tradeoff.

Current `NSTextView` gives native selection across the full transcript. A virtual block renderer will not get that for free.

Recommended phased approach:

### Phase 1 selection behavior

For the first virtual prototype:

- Keep full transcript copy button working through existing transcript text generation.
- Keep per-block text selection if the mounted block is an `NSTextView` or selectable text component.
- Do not promise continuous multi-block native selection.
- Keep the old full-document renderer available as fallback for exact continuous selection if needed.

### Phase 2 selection behavior

Add custom selection only if users miss full native selection:

- Track selection start/end as `(blockID, localTextOffset)`.
- Draw selection highlights across mounted blocks.
- Copy selected range by slicing the whole transcript snapshot, not by asking mounted views.
- Support drag selection across viewport edges by autoscrolling.

This is substantial and should not block first performance validation.

## Context Menu And Action Parity

The current terminal renderer owns more than text painting. A virtual block renderer must preserve these actions before it can become the active renderer:

- Right-click Copy for selected text.
- Copy Block for the block under the pointer.
- Speak selection/block and Stop Speaking.
- File-link click handling through `TranscriptLinkifier` and `IDEOpener`.
- Inline image context menu actions:
  - Open in Image Browser.
  - Open in Preview.
  - Copy Image Path.
  - Copy Image.
  - Save to Downloads.
  - Save with a panel.

Do not treat these as optional polish. They are part of the existing transcript UI contract.

## Inline Images Strategy

Current inline images are inserted as `NSTextAttachment`s in the full attributed text.
The full renderer already gives these attachments fixed sizes through `InlineImageAttachment(imageID:fixedSize:)`, so image decode completion should not change row height in the normal path.

In the virtual renderer:

- Store inline image metadata on the owning block.
- Preserve the existing fixed-size placeholder behavior so estimated height is stable before decoding finishes.
- Decode/load thumbnails only for mounted blocks plus a small image-specific prefetch window.
- Cancel image loads when blocks leave the overscan region.
- Preserve image navigation by mapping image prompt indices to block IDs.

Measurement invalidation triggers:

- Images enabled/disabled.
- Image visibility toggled for the session.
- Thumbnail grid column count changes because width changed.
- Image load completed only if the placeholder and final view differ in height. Prefer fixed placeholders so image load does not change block height.

## Linkification Strategy

Current linkification runs while building attributed text and attaches AppKit `.link` attributes to ranges.

In the virtual renderer:

- Keep link detection lazy and block-local.
- Cache link matches by `(blockID, textSignature, cwd, repoRootPath)`.
- Resolve click behavior through the existing `TranscriptLinkifier` and `IDEOpener` path.
- Do not let link resolution block first paint of mounted rows. Render text first, attach links immediately after if needed.

## Visual Styling Strategy

Current block card styling lives in `TerminalLayoutManager.drawBackground(...)`.

In the virtual renderer:

- Move block visual style into a shared style helper so old and new renderers can agree on colors.
- Reuse `TranscriptColorSystem`, `TerminalRolePalette`, and the existing semantic role mapping.
- Keep card radius at the current visual language unless separately redesigning the transcript.
- Keep role/semantic colors visually consistent with existing screenshots.

Important dependency:

`TerminalRolePalette` is currently private inside `SessionTerminalView.swift`. Hoist it, or introduce a shared equivalent, before the virtual renderer tries to reuse current terminal colors outside that file.

Suggested new type:

```swift
struct TranscriptBlockVisualStyle {
    let fill: NSColor
    let accent: NSColor?
    let accentWidth: CGFloat
    let paddingY: CGFloat
    let textColor: NSColor
    let font: NSFont
}
```

This should replace duplicated block-style logic only when the virtual renderer is real enough. Do not refactor the current layout manager first without a concrete virtualization slice.

## Measurement Strategy

### Initial estimates

Use fast, conservative estimates:

- Base line height from font metrics.
- Text line count from newline count.
- Additional wrapped line estimate from approximate character width and content width.
- Block padding from visual style.
- Inline image placeholder rows from image count and grid column count.

The first estimate does not need to be perfect. It needs to be stable enough that the scrollbar is plausible and search jumps land near the target.

### Measurement refinement

When a block mounts:

- Render it at the current content width.
- Measure its fitting height.
- Send measurement to layout.
- If the measured height differs meaningfully from the estimate, update prefix sums and document height.
- Preserve scroll anchor so visible content does not jump.

Suggested tolerance:

- Ignore deltas below 0.5 px or 1 px to avoid thrash.

### Cache key

Measurement cache key must include:

- Session ID.
- Block ID.
- Block content signature.
- Font size.
- Content width bucket or exact width.
- Color scheme only if it changes typography or border padding. It usually should not.
- Linkification enabled/disabled if it changes rendered text layout.
- Code/diff line-number setting.
- Inline images enabled/visible state.

## Phased Implementation Plan

### Phase 0: Instrument before changing behavior

Goal: prove the bottleneck distribution and define success metrics.

Add temporary/permanent debug signposts or scoped timers around:

- `SessionTerminalView.rebuildLines(...)`.
- `SessionTerminalView.buildRebuildResult(...)`.
- `TerminalBuilder.buildLines(...)`.
- `TerminalTextScrollView.applyContent(...)`.
- `TerminalTextScrollView.buildAttributedString(...)`.
- `textStorage.setAttributedString`.
- `buildBlockDecorations`.
- `TerminalLayoutManager.lineIndex` rebuilds.
- Tail append paths that still rebuild all-line metadata.
- Tail append/full apply rebuilds of `lineRoles`, `orderedLineRanges`, `orderedLineIDs`, and link-cache pruning over `Set(lines.map(\.id))`.
- `updateLayoutManagerUnifiedFind`.
- `updateLayoutManagerLocalFind`.
- AppKit layout work separately from construction, to confirm lazy layout is not the primary cold-open cost.
- `TranscriptHostView` body/update cost while switching selected sessions.
- Inactive provider transcript views mounted inside `TranscriptHostView`.
- Provider-specific observation churn caused by hidden `TranscriptPlainView`/`UnifiedTranscriptView` instances.

Metrics to collect:

- Session ID/source/file size/message count/line count.
- Classification bucket: ordinary, virtual-candidate, or pathological based on the provisional threshold policy.
- Time to first visible transcript paint.
- Time spent building lines.
- Time spent building attributed string.
- Time spent applying text storage.
- Time spent updating decorations/highlights.
- Time spent rebuilding `lineIndex`, line-role maps, ordered ranges/IDs, link-cache pruning sets, and block decorations during append/replace-tail paths.
- Time spent in actual layout/drawing versus construction/application.
- Time spent recomputing/mounting hidden provider transcript hosts during selection changes.
- Memory before/after selecting huge session.
- Scroll frame time or observed hitching during fast scroll.

Acceptance:

- A test/developer log can show where a huge session spends time.
- The next phase has a target metric, e.g. "reduce 50 MB Codex session first paint from N ms to under M ms."

### Phase 1: Extract block render model

Goal: build a block model without changing UI behavior.

Tasks:

- Add `TranscriptRenderBlock` and ID model.
- Add a builder that reuses the existing `TerminalBuilder` line-generation path, but do not treat `TerminalBlock` as sufficient render-block identity.
- Derive render-block identity and event mapping from `TerminalLine.blockIndex`, `TerminalLine.decorationGroupID`, and `SessionTranscriptBuilder.LogicalBlock` metadata.
- Use `TerminalBuilder.buildLinesAndBlocks(...)` only if it helps preserve shared line generation; its current `TerminalBlock` output is coarse and does not carry stable event/logical-block identity by itself.
- Hoist or replace private view-local types needed by the new renderer:
  - `TextSnapshot` or a new shared transcript-local search snapshot type,
  - `InlineSessionImage` or a new shared image-anchor type,
  - `TerminalRolePalette` or a new shared terminal-role palette,
  - snapshot-building helpers that currently live inside `SessionTerminalView`.
- Preserve current `TerminalLine` generation and IDs.
- Preserve maps:
  - block ID to line IDs,
  - line ID to block ID,
  - event ID to block ID,
  - role navigation targets,
  - semantic navigation targets,
  - image prompt targets.
- Add unit tests for block identity and mapping stability.

Acceptance:

- Current full `NSTextView` renderer can still render from the same line output.
- Tests prove event and role navigation target maps are unchanged for representative fixtures.
- No visual behavior changes yet.

### Phase 2: Add virtual layout engine

Goal: build and test the height/index math independent of UI.

Tasks:

- Add `TranscriptVirtualLayout`.
- Add estimated height calculation.
- Add measured height update.
- Add binary-search lookup by y offset.
- Add scroll target lookup by block ID.
- Add anchor-preservation calculations.
- Add tests for:
  - total height,
  - lookup by y,
  - measurement updates above viewport,
  - jump to block,
  - preserving anchor after height correction,
  - invalidation on width/font/settings changes.

Acceptance:

- Pure Swift tests pass without AppKit rendering.
- Large synthetic layouts with 100k blocks can update and search quickly enough for UI use.

### Phase 3: Prototype virtual renderer without making it active

Goal: render only visible blocks for terminal mode.

Tasks:

- Add `VirtualTranscriptScrollView`.
- Keep the production transcript path on the existing full `NSTextView` renderer unless the user explicitly approves active wiring in that session.
- Exercise the virtual renderer through tests, previews, or a branch-local manual harness, not through a committed feature flag or hidden preference.
- Use block views for text-only user/assistant/tool/error/meta blocks.
- Use overscan by viewport height, e.g. 1.5x above and below.
- Implement basic block measurement and document height updates.
- Implement virtual scroll-to-bottom and scroll-to-block using y offsets, not `NSTextView` character ranges.
- Keep native find disabled or routed to the existing full renderer in this prototype.
- Keep the existing full renderer as default until validation.

First prototype exclusions:

- Inline images can render as placeholders or be disabled in virtual mode.
- Linkification can be skipped or minimal.
- Search highlights can be basic.
- Continuous native text selection can be absent.

Acceptance:

- Huge transcript opens and shows visible content quickly.
- Scrollbar represents full transcript.
- Scrolling mounts/unmounts blocks without blank regions.
- Existing user-visible renderer remains unchanged unless active wiring has been explicitly approved.

### Phase 4: Search, find, and navigation parity

Goal: make the virtual renderer usable for real workflows.

Tasks:

- Build an in-transcript search snapshot independent of mounted blocks.
- Map match ranges to block IDs and line IDs.
- Project match highlights into mounted block-local ranges.
- Replace current `coordinator.lineRanges[lineID] -> NSRange` scroll integrations with block/y-offset targets for local find, unified search, explicit scroll targets, role navigation, scroll-to-bottom, and top-align jumps.
- Replace or intercept the native AppKit find panel in virtual mode so Cmd-F searches the whole transcript snapshot, not just mounted blocks.
- Preserve the menu/shortcut/focus chain from `AgentSessionsApp` to `UnifiedSessionsView` to `TranscriptPlainView` to the active transcript renderer.
- Preserve first-responder behavior for transcript focus requests after event jumps and image-browser navigation.
- Implement next/previous unified search navigation against virtual targets.
- Implement local find navigation against virtual targets.
- Implement role navigation:
  - user prompts,
  - tools,
  - errors,
  - semantic kinds.
- Implement event ID jumps.
- Preserve auto-scroll to first/last prompt behavior.

Acceptance:

- Cmd-F within a selected transcript works in virtual mode.
- Native find does not silently search only the mounted viewport.
- Search menu commands, hidden keyboard shortcut buttons, Cmd-G, Shift-Cmd-G, Escape, and focus return behave like the full renderer.
- Unified search highlights the selected transcript.
- Search result count and navigation count match the full renderer.
- Jump to first/last prompt works.
- Tool/error navigation works.
- Search jumps to unmounted matches land on the right block and correct after measurement.

### Phase 5: Rich content parity

Goal: add the rich transcript features that make Agent Sessions useful.

Tasks:

- Add linkification in mounted blocks.
- Add code/diff line numbers.
- Add semantic block rendering parity.
- Add review summary/plan block rendering parity.
- Add inline image thumbnail rendering and image navigation.
- Add current image highlight behavior.
- Add hover/click behavior for file links.
- Add context menu parity for Copy, Copy Block, Speak, Stop Speaking, file-link actions, and inline image actions.

Acceptance:

- Existing transcript readability tests still pass.
- Visual inspection confirms virtual blocks match the current renderer closely enough.
- Inline image navigation moves to the owning prompt.
- Link clicks open the expected IDE target.
- Context menus expose the same actions as the full renderer for equivalent content.

### Phase 6: Selection/copy decision

Goal: decide whether virtual mode can become default.

Options:

1. Keep old renderer as "full text mode" for exact selection.
2. Add custom cross-block selection and copy.
3. Accept block-local selection plus full-transcript copy.

Recommended first decision:

Ship virtual mode only if block-local selection plus full-transcript copy is acceptable. Add custom continuous selection only after user feedback proves it is necessary.

Acceptance:

- Copy full transcript still works.
- Copy selected mounted text works where supported.
- No accidental clipboard overwrite regressions.

### Phase 7: Default rollout and fallback

Goal: safely switch large transcripts to virtual mode only after explicit approval. This is a product-change phase, not part of the no-UI-change refactoring phase.

Recommended rollout policy:

- Keep full renderer for small sessions.
- Use virtual renderer automatically only above calibrated thresholds from Phase 0, favoring rendered terminal line count, raw file size, measured build/apply time, and first-paint time over raw message count.
- Keep the old renderer code available as an internal fallback path while stabilizing, but do not add a user preference, hidden switch, or feature flag unless explicitly requested.

Potential thresholds to test:

- `lines.count > 10_000`
- raw transcript file size `> 10 MB`
- attributed build time from instrumentation `> 300 ms`
- definitely pathological: `lines.count > 50_000`, very large JSONL/tool output, image-heavy sessions, or current-renderer beachball/spinner behavior.

Acceptance:

- Small sessions remain visually unchanged.
- Huge sessions open substantially faster.
- No functional regressions in search/navigation/image/link workflows.

## Testing Plan

### QA principles

The virtualization work is allowed to improve performance, but it must not silently redefine the transcript product:

- Parser output must remain stable unless a parser change is explicitly in scope.
- Existing readable transcript presentation is the reference renderer.
- Search, navigation, copy/export, focus, links, images, and context menus are part of the transcript UX contract, not optional extras.
- Phase 0 through Phase 2 must be no-UI-change work.
- Any stage that makes virtual rendering user-visible must pass full-renderer parity checks first.

### Hard gates before changing active renderer

Do not replace the current full `NSTextView` renderer for any normal app path until all of these are true:

- Parser and transcript golden fixtures pass unchanged.
- For representative fixtures, full-renderer text and virtual-renderer text match after applying the same display settings.
- In-transcript find counts, current-match index, and next/previous navigation match the full renderer.
- Role, semantic, event, first/last prompt, image, and unified-search target maps match the full renderer.
- Copy full transcript and export Markdown output are unchanged.
- Context menus expose equivalent actions for equivalent content.
- Link payloads resolve to the same file/line/column targets.
- Inline image anchors map to the same user prompt/event and keep fixed layout dimensions.
- Keyboard and focus flows behave like the current app.
- Manual visual QA confirms no meaningful presentation drift for small and ordinary sessions.
- Large-session performance improves enough to justify activation.

### Parser and transcript contract tests

Virtualization should not require parser-format changes. If a parser or transcript builder file is touched, treat that as high-risk and run the existing parser/golden suites plus targeted new tests.

Existing suites to keep green:

- `AgentSessionsTests/SessionParserTests.swift`
- `AgentSessionsTests/CursorSessionParserTests.swift`
- `AgentSessionsTests/GeminiParserTests.swift`
- `AgentSessionsTests/DroidSessionParserTests.swift`
- `AgentSessionsTests/PiSessionParserTests.swift`
- `AgentSessionsTests/TranscriptBuilderTests.swift`
- `AgentSessionsTests/TranscriptGoldenFixtureTests.swift`
- `AgentSessionsTests/Stage0GoldenFixturesTests.swift`
- `AgentSessionsTests/ToolTextBlockNormalizerTests.swift`
- `AgentSessionsTests/ToolTextBlockNormalizerRegressionTests.swift`
- `AgentSessionsTests/TerminalSemanticSegmentationTests.swift`
- `AgentSessionsTests/SessionTerminalDiffTests.swift`
- `AgentSessionsTests/InlineSessionImageMappingTests.swift`

Add new tests that serialize and compare the renderer-facing contract for representative sessions:

- `SessionTranscriptBuilder.LogicalBlock` sequence: role, text, event ID, tool metadata, and source.
- `TerminalBuilder.buildLines(...)` output: line ID, role, text, event index, block index, `decorationGroupID`, and `semanticKind`.
- Rendered text contract from `renderedTranscriptLineText(...)` for code/diff line-number settings.
- `eventID -> render block`, `userPromptIndex -> render block`, inline image anchor, and role/semantic navigation maps.

The baseline should be checked into tests as compact fixtures or generated expected arrays. Do not approve changes that alter these baselines unless the implementation intentionally changes transcript parsing or presentation and updates the plan/changelog accordingly.

### Full renderer parity tests

Create a parity harness that builds both representations from the same `Session` and display settings:

1. Current full renderer model:
   - `TerminalBuilder.buildLines(...)`.
   - Current rendered-line text generation.
   - Current full/visible search snapshots.
   - Current line-ID navigation maps.
2. New virtual model:
   - `TranscriptRenderBlockBuilder`.
   - `TranscriptSearchSnapshot`.
   - Block navigation maps.

Compare:

- Plain rendered transcript text.
- Per-line rendered text.
- Line-to-block ownership.
- Search match count and match order for local find.
- Unified-search projected match count and current-match target.
- Role navigation targets for user, assistant, tools, and errors.
- Semantic navigation targets for plan, code, diff, and review summary.
- Event jump targets.
- Inline image prompt/event targets.
- Link payload ranges and resolved targets.

Run this parity suite across multiple widths, font sizes, code/diff line-number settings, linkification on/off, inline images on/off, review cards on/off, and role/semantic filters.

### Presentation QA matrix

Use fixture and synthetic sessions that exercise every transcript visual category:

- Small chat-only session.
- Normal Codex session with user/assistant/tool input/tool output.
- Claude/OpenCode/OpenClaw/Cursor/Gemini/Pi provider sessions.
- Long tool-output session.
- Structured tool output normalized through `ToolTextBlockNormalizer`.
- Code fence, diff, plan, and review-summary content.
- Local-command transcript caveat.
- User-interrupt and turn-aborted meta blocks.
- Error outputs.
- Preamble skip behavior.
- Compaction/summary-heavy transcript.
- Inline images and multiple image rows.
- File references and IDE link targets.
- Very long unbroken text, long paths, and markdown-like tables.
- Huge synthetic `10_000`, `50_000`, and `100_000` line sessions.

For each representative fixture, verify:

- Card boundaries and spacing.
- Accent strips and role colors.
- Semantic colors.
- Code/diff line numbering.
- Wrapping and indentation.
- Text does not clip or overlap.
- Search/current-match highlight placement.
- Inline image placeholder size and alignment.
- Light mode and dark mode.
- Default, smaller, and larger transcript font sizes.
- Narrow, default, and wide transcript pane widths.

Automated presentation checks should use deterministic rendered text/layout assertions where possible. Screenshot checks are valuable for final QA, but should be treated as visual evidence rather than the only correctness oracle.

### Interaction QA matrix

Before virtual mode can replace the current renderer, verify these user workflows:

- Open small transcript.
- Open huge transcript.
- Switch repeatedly between session list and transcript.
- Scroll by wheel/trackpad from top to bottom.
- Drag scrollbar thumb to top, middle, and bottom.
- Keep bottom pinned during live append.
- Preserve current top anchor during resize/font changes.
- Cmd-F opens transcript find.
- Escape clears/closes find exactly as today.
- Cmd-G and Shift-Cmd-G navigate matches.
- Global search selected result highlights inside the transcript.
- Jump first/last user prompt.
- Navigate users/tools/errors/semantic blocks.
- Image-browser jump returns focus to the transcript.
- Event jump lands on the expected block.
- Copy full transcript.
- Copy selected mounted text.
- Copy Block from context menu.
- Export Markdown.
- Speak selection/block and Stop Speaking.
- Click file links with the configured IDE target.
- Inline image menu actions: Open in Image Browser, Open in Preview, Copy Image Path, Copy Image, Save to Downloads, and Save.

For interaction tests that cannot be cleanly automated in XCTest, record a manual QA checklist with pass/fail notes and screenshots for the branch handoff.

### Performance QA matrix

Measure on the same machine before and after virtual rendering:

- Cold open selected huge session.
- Switch from another session into a huge session.
- Switch from a huge session back to a small session.
- Fast scroll through huge session.
- Drag scrollbar to an unmounted middle region.
- Search jump to end-of-transcript match.
- Live append into a huge transcript.
- Toggle code/diff line numbers.
- Resize the transcript pane.
- Change transcript font size.

Record:

- Raw file size.
- Message/event count.
- Rendered terminal line count.
- Block count.
- First visible paint time.
- Main-thread time spent in attributed build/apply/decorations/indexing.
- Peak memory after opening.
- Mounted block count.
- Scroll hitch/frame-time observations.

Performance success alone is not sufficient to ship. It must be paired with the parity and interaction gates above.

### Unit tests

Add tests for:

- Render block identity stability.
- Logical block to render block mapping.
- Event ID to block mapping.
- Role navigation target generation.
- Semantic navigation target generation.
- Search snapshot range mapping.
- Height estimation and measured-height correction.
- Prefix-sum lookup by y offset.
- Scroll anchor preservation.
- Width/font/settings invalidation.
- Tail append and suffix replacement behavior.

Likely test files:

- `AgentSessionsTests/TranscriptRenderBlockTests.swift`
- `AgentSessionsTests/TranscriptRenderContractTests.swift`
- `AgentSessionsTests/TranscriptRendererParityTests.swift`
- `AgentSessionsTests/TranscriptVirtualLayoutTests.swift`
- `AgentSessionsTests/TranscriptVirtualSearchTests.swift`
- `AgentSessionsTests/TranscriptVirtualNavigationTests.swift`
- `AgentSessionsTests/TranscriptVirtualInteractionContractTests.swift`

### Focused fixture tests

Use existing fixtures and synthetic sessions:

- Small chat-only session.
- Command-heavy Codex session.
- Long tool-output session.
- Code/diff-heavy session.
- Session with review cards enabled.
- Session with inline images.
- Session with preamble skip behavior.
- Session with local-command transcript caveat.
- Session with error outputs.
- Huge synthetic session with 50k-100k blocks or lines.

### UI/manual QA

Manual checks:

- Open small transcript: no visual regression.
- Open huge transcript: first content appears quickly.
- Switch from sessions list to huge transcript repeatedly: no visible stale transcript flash.
- Scroll from top to bottom quickly: no blank holes.
- Drag scrollbar thumb to middle: lands near expected content.
- Search for text near the end of a huge session: jumps correctly.
- Next/previous match over unmounted regions: works.
- Jump first/last user prompt: works.
- Tool/error navigation: works.
- Inline image navigation: works.
- Link click opens expected file in configured IDE.
- Change font size: heights invalidate and content remains stable.
- Resize window: heights invalidate and current scroll anchor remains stable.
- Toggle code/diff line numbers: layout and search ranges remain correct.
- Toggle linkification: no crash, no bad layout.
- Switch color scheme: visual style updates without redoing unnecessary parsing.

### Build/test commands

Because this will touch Swift and likely AppKit/SwiftUI integration, always build before presenting results.

Preferred validation:

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
./scripts/xcode_test_stable.sh
```

Minimum no-UI-change validation for Phase 0 and Phase 1:

```bash
xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/TranscriptBuilderTests \
  -only-testing:AgentSessionsTests/TranscriptGoldenFixtureTests \
  -only-testing:AgentSessionsTests/Stage0GoldenFixturesTests \
  -only-testing:AgentSessionsTests/ToolTextBlockNormalizerTests \
  -only-testing:AgentSessionsTests/ToolTextBlockNormalizerRegressionTests \
  -only-testing:AgentSessionsTests/TerminalSemanticSegmentationTests \
  -only-testing:AgentSessionsTests/SessionTerminalDiffTests \
  -only-testing:AgentSessionsTests/InlineSessionImageMappingTests
```

If parser files or provider transcript builders are touched, add the provider parser suites relevant to the changed code, then run the stable wrapper before presenting results.

For narrower intermediate validation:

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/TranscriptVirtualLayoutTests
```

Use the repo's stable XCTest wrapper for broad validation to avoid intermittent macOS code-sign flakes.

## Performance Acceptance Criteria

Define exact numbers after Phase 0 instrumentation. Initial suggested targets:

- For a 10k-line transcript: first visible paint under 150 ms after parsed lines are available.
- For a 50k-line transcript: first visible paint under 300 ms after parsed lines are available.
- For a 100k-line synthetic transcript: no full attributed string is built in virtual mode.
- Live append into a huge virtual transcript does not rebuild all-line decorations or line indexes on every tick.
- Scrolling should not mount more than visible blocks plus overscan.
- Memory should scale with visible block count, not total transcript line count, for rendered views/attachments.
- Search/index memory may still scale with transcript size; that is acceptable if it is separate from rendering and not triggered by ordinary opening without search.

## Major Risks

### Native text selection regression

Risk:

Virtual block rendering loses full-document `NSTextView` selection behavior.

Mitigation:

- Keep full renderer fallback.
- Keep full-transcript copy.
- Defer custom selection until after performance proof.

### Scroll jumpiness

Risk:

Estimated heights differ from measured heights, causing jumpy scrolling or search targets that drift.

Mitigation:

- Track anchor block plus local offset.
- Preserve existing fixed-size placeholders for images.
- Apply measured-height corrections with scroll offset compensation.
- Ignore tiny measurement deltas.

### Search range mismatch

Risk:

Rendered text diverges from indexed/search text during extraction, causing highlights and jumps to target wrong locations.

Mitigation:

- Preserve/extract the existing `renderedTranscriptLineText(...)` contract used today by both `buildTextSnapshot(...)` and `buildAttributedString(...)`.
- Build search snapshot from the same block text contract used by the renderer.
- Add tests comparing full renderer search counts against virtual snapshot counts.

### Hidden host churn remains

Phase 0 dependency:

Provider host `ZStack` observation or hidden views still cause switching cost after virtualizing the selected transcript.

Required action:

- Instrument `TranscriptHostView` separately.
- If needed, change host mounting so inactive providers do less work while preserving split-view stability.

### Inline image layout instability

Risk:

Image decode completion changes row height and moves content if virtual mode drops the current fixed-size attachment behavior.

Mitigation:

- Preserve the existing fixed-size attachment/placeholder sizing with final thumbnails fitted inside it.
- Keep image grid column count tied to width and invalidate only on width changes.

### Too much abstraction too early

Risk:

Refactoring the current text renderer before proving virtual rendering slows delivery and introduces regressions.

Mitigation:

- Phase 1 extracts only the render model needed by virtualization.
- Do not rewrite `TerminalLayoutManager` styling until virtual blocks need shared style code.

## Files Likely To Change

First implementation branch likely touches:

- `AgentSessions/Views/SessionTerminalView.swift`
- `AgentSessions/Views/TranscriptPlainView.swift`
- `AgentSessions/Services/TerminalModels.swift`
- `AgentSessions/Services/SessionTranscriptBuilder.swift`
- `AgentSessions/Services/TranscriptColorSystem.swift`
- `AgentSessions/Services/ToolTextBlockNormalizer.swift`
- `AgentSessions/Search/SessionSearchTextBuilder.swift` if renderer text contracts need to align with existing session search text.
- `AgentSessions/Search/SearchCoordinator.swift`, `AgentSessions/Search/UnifiedSearchState.swift`, and `AgentSessions/Search/SearchSessionStore.swift` only if instrumentation shows selected-result handoff needs changes.
- `AgentSessions/Services/FilterEngine.swift` only if the virtual in-transcript snapshot keeps using the existing `SearchTextMatcher` implementation.
- `AgentSessionsTests/*Transcript*Tests.swift`
- `docs/CHANGELOG.md` only once behavior changes become user-visible
- `docs/summaries/2026-05.md` or later month summary once user-visible behavior changes ship

New files to consider:

- `AgentSessions/TranscriptRendering/TranscriptRenderBlock.swift`
- `AgentSessions/TranscriptRendering/TranscriptRenderBlockBuilder.swift`
- `AgentSessions/TranscriptRendering/TranscriptVirtualLayout.swift`
- `AgentSessions/TranscriptRendering/VirtualTranscriptScrollView.swift`
- `AgentSessions/TranscriptRendering/TranscriptBlockView.swift`
- `AgentSessions/TranscriptRendering/TranscriptSearchSnapshot.swift`
- `AgentSessionsTests/TranscriptRenderBlockTests.swift`
- `AgentSessionsTests/TranscriptRenderContractTests.swift`
- `AgentSessionsTests/TranscriptRendererParityTests.swift`
- `AgentSessionsTests/TranscriptVirtualLayoutTests.swift`
- `AgentSessionsTests/TranscriptVirtualSearchTests.swift`
- `AgentSessionsTests/TranscriptVirtualNavigationTests.swift`
- `AgentSessionsTests/TranscriptVirtualInteractionContractTests.swift`

If new Swift files are added, use the repo's Xcode project helper:

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/TranscriptRendering/TranscriptVirtualLayout.swift \
  AgentSessions/TranscriptRendering
```

For tests:

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/TranscriptVirtualLayoutTests.swift \
  AgentSessionsTests
```

Build after adding files.

## Implementation Prompt For Next Session

Use this prompt when starting the implementation session:

```text
You are working in /Users/alexm/Repository/Codex-History on Agent Sessions.

Goal: implement transcript virtualization for huge terminal/session transcripts, starting with instrumentation and a block-level render model. Read docs/superpowers/plans/2026-05-28-transcript-virtualization-plan.md first.

Do not jump directly to LazyVStack. The current renderer is a full AppKit NSTextView pipeline in AgentSessions/Views/SessionTerminalView.swift. Virtualization must be block-level and must preserve search/navigation semantics.

Start with Phase 0 and Phase 1 only unless explicitly asked to continue:
1. Add lightweight instrumentation around transcript line rebuild, attributed string build, textStorage set, block decoration build, lineIndex rebuilds, line-role map rebuilds, ordered range/ID rebuilds, link-cache pruning sets, tail-append metadata rebuilds, highlight updates, selected transcript host switching, inactive provider host updates, and hidden provider observation churn. Measure construction separately from AppKit layout/drawing.
2. Add a TranscriptRenderBlock model/builder that reuses TerminalBuilder line generation but derives block IDs from TerminalLine.blockIndex, TerminalLine.decorationGroupID, and SessionTranscriptBuilder.LogicalBlock metadata; do not rely on TerminalBlock alone for identity. Treat these IDs as stable for a given session content signature and renderer/parser version, not as persisted storage identities.
3. Hoist or replace private SessionTerminalView.swift types needed outside that file: TextSnapshot, InlineSessionImage, TerminalRolePalette, renderedTranscriptLineText, and snapshot-building helpers.
4. Keep current UI behavior unchanged.
5. Catalog, but do not rewrite yet, every current `coordinator.lineRanges` / `scrollRangeToVisible` / native find-panel dependency that virtual mode must replace later.
6. Catalog, but do not rewrite yet, the menu/shortcut/focus chain and context-menu/action surface that virtual mode must preserve.
7. Add focused unit tests for mapping stability, renderer-facing contract stability, and navigation target parity.
8. Run the parser/transcript golden suites listed in the Testing Plan. If any parser, provider builder, transcript builder, or normalizer code is touched, treat changed baselines as a blocker unless the transcript presentation change was intentional and documented.
9. Build the active scheme after Swift changes.

Do not modify parser formats, storage formats, global search behavior, provider support, or visible UI behavior. Do not add feature flags, hidden renderer switches, preferences, or rollout gates. Keep the old renderer as the only active renderer in this first pass. Do not wire virtual rendering into a normal app path until the hard QA gates pass.
```

## Final Recommendation

Yes, do this as a separate branch.

Do not start by rewriting the whole transcript view. Start by measuring the current cost and extracting a stable block render model with no visible UI/UX change. Once that is tested, add a virtual renderer implementation for terminal mode only, but do not wire it into active user-visible behavior without explicit approval. Treat full native selection, inline images, context menus, focus/menu commands, and exact search-highlight parity as gates before virtual mode can replace the current renderer.
