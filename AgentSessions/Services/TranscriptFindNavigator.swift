import Foundation

/// Pure, off-view find-navigation primitives for Rich mode (Task 10).
///
/// Whole-session matches come from `TranscriptDerivedState.findMatches` as a
/// flat, ordinal-ordered `[BlockMatch]` in BLOCK-text space. Everything the
/// Rich find bar needs — ordinal stepping with wrap, "first match at-or-after a
/// viewport anchor" reset, per-row match-count aggregation for the collapsed-row
/// pill, and stable-current-match reconciliation across a snapshot change — is
/// a pure function of that list plus a few scalars. Keeping them here (rather
/// than inlined in the AppKit controller) makes the tricky wrap/clamp reasoning
/// unit-testable without a table.
enum TranscriptFindNavigator {

    typealias Match = TranscriptDerivedState.BlockMatch

    // MARK: Ordinal stepping

    /// Step `current` by `direction` (+1 next / -1 prev) through `count`
    /// matches, wrapping at both ends (parity with Text mode). Returns 0 for an
    /// empty list. `direction` is clamped to its sign so callers can pass any
    /// nonzero int.
    static func steppedOrdinal(current: Int, count: Int, direction: Int) -> Int {
        guard count > 0 else { return 0 }
        let step = direction >= 0 ? 1 : -1
        var next = current + step
        if next < 0 { next = count - 1 }
        if next >= count { next = 0 }
        return next
    }

    // MARK: Query-change reset (jump to first match at-or-after viewport top)

    /// Ordinal of the first match whose block is at-or-after `viewportTopBlock`,
    /// falling back to the first match overall when none qualifies (i.e. the
    /// viewport top is past the last match — wrap to the top, parity with Text
    /// mode's reset-to-first behavior). Returns nil for an empty list.
    ///
    /// `matches` is assumed ordinal-ordered (as produced by findMatches), which
    /// also means block-ascending, so a linear scan for the first qualifying
    /// block is correct and cheap.
    static func firstOrdinalAtOrAfter(matches: [Match], viewportTopBlock: Int?) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let top = viewportTopBlock else { return 0 }
        if let hit = matches.first(where: { $0.globalBlockIndex >= top }) {
            return hit.ordinal
        }
        return 0
    }

    // MARK: Stable-current reconciliation across a snapshot change

    /// After a live-append (or any snapshot recompute) the match list may change.
    /// Keep the current selection stable by finding the SAME match (identical
    /// `globalBlockIndex` + `rangeInBlockText`) in the new list; if it survived,
    /// return its new ordinal. Otherwise clamp the old ordinal into the new list
    /// bounds (or nil when the new list is empty).
    static func reconciledOrdinal(previous: Match?,
                                  previousOrdinal: Int,
                                  newMatches: [Match]) -> Int? {
        guard !newMatches.isEmpty else { return nil }
        if let previous,
           let survivor = newMatches.first(where: {
               $0.globalBlockIndex == previous.globalBlockIndex &&
               $0.rangeInBlockText == previous.rangeInBlockText
           }) {
            return survivor.ordinal
        }
        return min(max(0, previousOrdinal), newMatches.count - 1)
    }

    // MARK: Row-shape renderability of a match

    /// The rendered-body shape of the row a match lands in, from the row's
    /// perspective at highlight time. Drives whether a match range can be
    /// painted as an in-row background highlight, and (when it can) what UTF-16
    /// length of visible text bounds it.
    enum RowShape: Equatable {
        /// Ordinary message row (user/assistant/error). `bodyText.string ==
        /// block.text`, so a match range maps directly.
        case message
        /// A user/assistant message rendered as markdown (Task 12). The body
        /// string is the RENDERED plain text (syntax stripped), so a match range
        /// in block.text maps through the body's source map — a range that spans
        /// consumed syntax is non-mappable and falls back to the pill.
        case markdownMessage(RenderedBody)
        /// A single expanded tool card, NOT truncated: `bodyText.string ==
        /// block.text`, so the range maps directly (same as `message`).
        case expandedSingleToolFull
        /// A single expanded tool card, truncated to the first `visibleUTF16Len`
        /// UTF-16 units: a match fully inside that prefix is renderable; one
        /// past it is hidden (count it, no highlight).
        case expandedSingleToolTruncated(visibleUTF16Len: Int)
        /// Rendered body ≠ block.text (a merged group's bullet-annotated body),
        /// or the row is collapsed / a meta separator: no direct range mapping,
        /// so the match is non-renderable (pill only).
        case nonRenderable
    }

    /// Whether `range` (UTF-16 into block.text) can be painted as an in-row
    /// highlight given the row's rendered shape, and if so the exact range to
    /// paint (identical to `range` — the strings are byte-identical where
    /// renderable). A truncated shape renders only ranges fully within the
    /// visible prefix. Returns nil for any non-renderable shape or an
    /// out-of-visible-bounds range.
    static func renderableRange(_ range: NSRange, shape: RowShape) -> NSRange? {
        switch shape {
        case .message, .expandedSingleToolFull:
            return range
        case .markdownMessage(let body):
            // The rendered body ≠ block.text (syntax was consumed), so map the
            // match range through the source map. A range crossing consumed
            // syntax (or landing in an unmappable region) returns nil → pill.
            return body.renderedRange(forSourceRange: range)
        case .expandedSingleToolTruncated(let visibleLen):
            // Fully inside the visible prefix ⇒ paintable; otherwise hidden.
            return NSMaxRange(range) <= visibleLen ? range : nil
        case .nonRenderable:
            return nil
        }
    }

    // MARK: Find-auto-expand fold check (Task 16)

    /// Whether a match ending at UTF-16 offset `matchEndOffset` inside a tool
    /// row's rendered (expanded) `fullBodyText` falls beyond the row's
    /// `lineLimit`-line visible prefix — i.e. auto-expanding the collapsed card
    /// alone won't make the match visible; "Show all N lines" is also needed.
    ///
    /// `fullBodyText` is the row's already-rendered expanded body — a lone
    /// card's `block.text` or a merged group's bullet+summary-annotated
    /// concatenation (`BlockCardCellView.expandedToolBodyText`) — so this stays
    /// a pure string/offset comparison with no knowledge of how that body was
    /// built. `matchEndOffset` is the match's end position IN THAT STRING's
    /// coordinate space (for a group, the caller has already re-based the
    /// match's block-local `rangeInBlockText` by the preceding blocks'
    /// annotated lengths). Returns false when the body doesn't even exceed
    /// `lineLimit` lines (nothing is folded).
    static func matchExceedsTruncationFold(fullBodyText: String,
                                           matchEndOffset: Int,
                                           lineLimit: Int) -> Bool {
        let lines = fullBodyText.components(separatedBy: "\n")
        guard lines.count > lineLimit else { return false }
        let visibleLen = (lines.prefix(lineLimit).joined(separator: "\n") as NSString).length
        return matchEndOffset > visibleLen
    }
}
