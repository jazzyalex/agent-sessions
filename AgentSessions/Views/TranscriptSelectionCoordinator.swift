import Foundation

/// Pure cross-block selection math for Rich-mode transcript blocks.
///
/// `blockOrdinal` is an index into the CURRENT row-text array (visible/loaded
/// order), NOT `globalBlockIndex` — the table layer owns that mapping. On ANY
/// change to the rows array (prepend/load-older, session switch, a collapse
/// toggle that changes rendered text, font/mode change) the table layer CLEARS
/// the active selection, because the ordinals would otherwise silently
/// misindex. That "clear on any rows change" rule keeps this struct free of
/// row-identity bookkeeping.
///
/// Locked P1 decisions encoded here:
/// - Collapsed tool cards contribute NOTHING to selection (`excludedBlockOrdinals`).
///   Meta-separator rows are likewise excluded by the table layer.
/// - Expanded tool cards contribute their RENDERED (possibly truncated) text —
///   "copy what you see". The table layer passes that exact string as the
///   block's text.
/// - Copy joins contributing blocks with "\n\n".
struct TranscriptSelectionCoordinator: Equatable {
    struct Position: Comparable, Equatable {
        var blockOrdinal: Int
        var utf16Offset: Int
        static func < (l: Position, r: Position) -> Bool {
            (l.blockOrdinal, l.utf16Offset) < (r.blockOrdinal, r.utf16Offset)
        }
    }

    private(set) var anchor: Position?
    private(set) var focus: Position?

    /// Ordinals that must contribute nothing to the selection (collapsed tool
    /// cards, meta separators). They still occupy an ordinal slot so the span
    /// math stays contiguous; they just render/copy no text.
    var excludedBlockOrdinals: Set<Int> = []

    mutating func begin(at p: Position) { anchor = p; focus = p }
    mutating func extend(to p: Position) { focus = p }
    mutating func clear() { anchor = nil; focus = nil }

    /// A real (non-caret) multi/intra-block selection is present.
    var isActive: Bool { anchor != nil && focus != nil && anchor != focus }

    /// Normalized ordered endpoints (low ≤ high), or nil if no selection.
    var normalizedEndpoints: (low: Position, high: Position)? {
        guard let anchor, let focus else { return nil }
        return anchor <= focus ? (anchor, focus) : (focus, anchor)
    }

    /// The NSRange to paint (via `setSelectedRange`) in the text view for a given
    /// block ordinal, given that block's current UTF-16 length. Nil ⇒ the block
    /// is outside the selection span or explicitly excluded (paint an empty
    /// range there). Offsets are clamped to `textLength` so a recycled/shrunken
    /// row (e.g. after a truncation toggle) can't produce an out-of-bounds range.
    func selectionRange(blockOrdinal: Int, textLength: Int) -> NSRange? {
        guard let (lo, hi) = normalizedEndpoints else { return nil }
        guard !excludedBlockOrdinals.contains(blockOrdinal) else { return nil }
        guard blockOrdinal >= lo.blockOrdinal, blockOrdinal <= hi.blockOrdinal else { return nil }
        let start = blockOrdinal == lo.blockOrdinal ? min(max(0, lo.utf16Offset), textLength) : 0
        let end = blockOrdinal == hi.blockOrdinal ? min(max(0, hi.utf16Offset), textLength) : textLength
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Assemble the copied text: each contributing block's selected substring,
    /// joined with "\n\n". A block contributes iff its selection range is
    /// non-empty (length > 0). Excluded ordinals and empty/zero-length ranges
    /// drop out entirely — no blank segments, no doubled separators. Full
    /// middle-block selections (length == textLength) are included by this rule
    /// since their length is > 0.
    func selectedText(blockTexts: [String]) -> String {
        blockTexts.indices.compactMap { i -> String? in
            let ns = blockTexts[i] as NSString
            guard let r = selectionRange(blockOrdinal: i, textLength: ns.length),
                  r.length > 0 else { return nil }
            return ns.substring(with: r)
        }.joined(separator: "\n\n")
    }
}
