import AppKit

extension NSAttributedString.Key {
    /// Marks a run that carries a markdown-owned `.backgroundColor` chip (inline
    /// code). The find-highlight system paints/strips `.backgroundColor` over
    /// match ranges; without a distinct marker, clearing a find highlight would
    /// wipe the code chip too. The renderer stamps this key (value: the chip
    /// `NSColor`) alongside `.backgroundColor` so `SelectableBlockTextView` can
    /// RESTORE the chip after a find-clear rather than losing it. It is inert to
    /// layout/drawing — purely a bookkeeping marker.
    static let markdownCodeChip = NSAttributedString.Key("AgentSessions.markdownCodeChip")
}

/// One contiguous source→rendered mapping segment. `sourceRange` is UTF-16 into
/// block.text; `renderedLocation` is where that source text begins in the
/// rendered attributed string. Segments are sorted by sourceRange.location and
/// non-overlapping. A gap in source coverage = consumed markdown syntax
/// (`**`, backticks, list markers) — never a mappable find target. A gap in
/// rendered coverage = inserted glyphs (bullets, table separators).
struct SourceMapSegment: Equatable {
    var sourceRange: NSRange
    var renderedLocation: Int
}

/// Per-block render product. Lives in the VIEW layer (controller cache), never
/// in TranscriptDerivedState — it carries resolved (appearance-baked) colors.
///
/// `Equatable` is provided so `TranscriptFindNavigator.RowShape` can stay
/// `Equatable` while carrying a `.markdownMessage(RenderedBody)` case. Equality
/// is defined on the SOURCE MAP + lengths only (`attributed` is intentionally
/// excluded): two bodies with the same segments and rendered length map find
/// ranges identically, which is all a `RowShape` equality comparison needs, and
/// `NSAttributedString` equality is expensive to evaluate on a hot path. The
/// map is a pure function of the rendered string's structure, so this never
/// conflates two genuinely different renders in practice.
struct RenderedBody: Equatable {
    var attributed: NSAttributedString
    var segments: [SourceMapSegment]
    var renderedLength: Int
    /// Source ranges that rendered into a non-highlightable region (table cell,
    /// group annotation). A match here → pill/count only, never a paint.
    var unmappableSourceRanges: [NSRange]

    static func == (lhs: RenderedBody, rhs: RenderedBody) -> Bool {
        lhs.renderedLength == rhs.renderedLength
            && lhs.segments == rhs.segments
            && lhs.unmappableSourceRanges == rhs.unmappableSourceRanges
    }

    /// Map a match range in block.text to the rendered range to highlight.
    /// nil when the source range spans a consumed-syntax boundary or lands in
    /// an unmappable region — caller falls back to the pill (like a collapsed card).
    func renderedRange(forSourceRange src: NSRange) -> NSRange? {
        if unmappableSourceRanges.contains(where: { NSIntersectionRange($0, src).length > 0 }) {
            return nil
        }
        guard let seg = segments.last(where: { $0.sourceRange.location <= src.location }),
              NSMaxRange(src) <= NSMaxRange(seg.sourceRange) else { return nil }
        let delta = seg.renderedLocation - seg.sourceRange.location
        return NSRange(location: src.location + delta, length: src.length)
    }
}

/// Cache key for a rendered body. eventID (not globalBlockIndex — indices shift
/// on prepend/widen; eventID is stable). textHash catches a streaming delta
/// mutating the same block. isDark because colors are baked at render time.
struct RenderKey: Hashable {
    var eventID: String
    var textHash: Int
    var fontBucket: Int
    var isDark: Bool
}
