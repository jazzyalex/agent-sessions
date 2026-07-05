import AppKit
import Markdown

/// Renders a user/assistant block's markdown `text` into an `NSAttributedString`
/// plus a `SourceMapSegment` list that maps every preserved source character
/// back to its rendered location (the find-highlight seam). T12 scope is inline
/// spans (emphasis / strong / inline-code / link), headers, and paragraphs;
/// fences, lists, and tables arrive in later tasks and are treated as plain
/// paragraph text until then.
///
/// ## Source-map approach: forward-scan, NOT swift-markdown source ranges
///
/// swift-markdown DOES populate `Markup.range` (a `SourceRange` of
/// `SourceLocation`s), but `SourceLocation.column` is documented as a **UTF-8
/// byte** offset from the line start. Our find matches are UTF-16 ranges into
/// `block.text`, so using the AST ranges would require a per-line UTF-8→UTF-16
/// remap that silently breaks on any non-ASCII prose (accents, emoji, CJK) —
/// exactly the content that appears in real transcripts. Instead we FORWARD-SCAN:
/// walk the inline `Text` leaves in source (== rendered) order and locate each
/// leaf's `.string` in `block.text` with `NSString.range(of:options:range:)`
/// starting from the last consumed UTF-16 offset. The scan is monotonic and
/// operates entirely in UTF-16, so the map is correct for Unicode by
/// construction, and consumed syntax (`**`, backticks, list markers) simply
/// leaves a gap between consecutive segments — which `renderedRange` treats as a
/// non-mappable boundary. This is the robust fallback the brief calls out.
///
/// ## Walk strategy: manual recursion, NOT a MarkupWalker
///
/// We recurse over `.children` directly (rather than a `MarkupWalker`) so a
/// single pass can (a) thread an inherited attribute set through nested inline
/// containers — `**_x_**` composes bold+italic — and (b) interleave appending
/// rendered glyphs with recording source segments and advancing the scan
/// cursor, all against shared local state. A visitor's per-method dispatch
/// would fragment that state.
enum MarkdownBodyRenderer {

    static func render(_ text: String, baseFont: NSFont, isDark: Bool) -> RenderedBody {
        // `isDark` is part of the interface (and the controller's cache key) but
        // is NOT consumed here: markdown colors are DYNAMIC `NSColor`s (chip,
        // link) that resolve per-appearance at draw time, so one render is valid
        // for both modes' *drawing*. The controller still keys the cache by
        // `isDark` and rebuilds on a flip because the produced `NSAttributedString`
        // bakes whichever appearance was current when its `.backgroundColor`
        // chip was resolved for measurement parity.
        _ = isDark
        var builder = Builder(source: text, baseFont: baseFont)
        // `.disableSmartOpts` is LOAD-BEARING for the source map: swift-markdown
        // enables cmark smart punctuation by default, which rewrites ' " -- ...
        // into typographic forms (’ “ – …) inside `Text.string`. That rewritten
        // text no longer matches `block.text`, so the forward-scan misses and the
        // run gets no segment — silently degrading find-highlight to the pill on
        // essentially all natural prose (apostrophes, quotes, dashes). Disabling
        // smart opts keeps rendered characters byte-faithful to the source so the
        // map covers prose.
        let document = Document(parsing: text, options: .disableSmartOpts)
        builder.appendBlocks(Array(document.children))
        return builder.finish()
    }

    // MARK: - Builder

    /// Mutable accumulator for one render pass. Owns the output attributed
    /// string, the segment list, and the monotonic forward-scan cursor.
    private struct Builder {
        let sourceNS: NSString
        let baseFont: NSFont
        let proseFont: NSFont

        let out = NSMutableAttributedString()
        var segments: [SourceMapSegment] = []
        /// Highest UTF-16 offset into `sourceNS` consumed so far. The forward
        /// scan for the next `Text` leaf starts here, guaranteeing monotonic,
        /// non-overlapping segments even when the same literal recurs.
        var scanCursor: Int = 0

        init(source: String, baseFont: NSFont) {
            self.sourceNS = source as NSString
            self.baseFont = baseFont
            self.proseFont = NSFont.systemFont(ofSize: baseFont.pointSize)
        }

        // MARK: Block level

        mutating func appendBlocks(_ blocks: [Markup]) {
            for (index, block) in blocks.enumerated() {
                appendBlock(block)
                // Rendered-only separator between block-level siblings. It carries
                // NO source segment (a gap in rendered coverage), so it never
                // shifts a find range: `renderedRange` maps via segment deltas,
                // and inserted glyphs live outside every segment.
                if index < blocks.count - 1 {
                    out.append(NSAttributedString(string: "\n\n"))
                }
            }
        }

        mutating func appendBlock(_ block: Markup) {
            switch block {
            case let heading as Heading:
                let size = baseFont.pointSize + CGFloat(max(0, 7 - heading.level)) * 2
                let headingFont = NSFont.boldSystemFont(ofSize: size)
                appendInlineChildren(heading.inlineChildren.map { $0 as Markup },
                                     font: headingFont,
                                     traits: .bold,
                                     extra: [:])
            case let paragraph as Paragraph:
                appendInlineChildren(paragraph.inlineChildren.map { $0 as Markup },
                                     font: proseFont,
                                     traits: [],
                                     extra: [:])
            case let codeBlock as CodeBlock:
                // Fenced/indented code block → dark inset card (Task 13). The
                // CODE MUST still render + copy — dropping it would blank the
                // single most common assistant payload. The `.code` body appears
                // verbatim in `block.text` (minus the ``` fences), so
                // `appendMappedRun` forward-scans it and records a segment. The
                // fence's info-string (language) is captured on `codeBlock` but
                // intentionally NOT rendered/highlighted here (syntax
                // highlighting is tier-2, out of scope for T13).
                //
                // Trailing-newline decision: cmark's `code_block` literal (what
                // swift-markdown surfaces verbatim as `.code`, straight from
                // `cmark_node_get_literal` with no swift-markdown-side
                // post-processing — see CommonMarkConverter.convertCodeBlock)
                // ALWAYS ends in exactly one `\n`, even for a single-line fence
                // or an empty body — confirmed empirically against the
                // checked-out swift-markdown package for `"```\nlet x = 1\n```"`
                // (→ "let x = 1\n"), a multi-line fence, and an empty fence (→
                // "\n"). Left as-is, that trailing `\n` renders as a blank line
                // INSIDE the card before the closing card padding. We trim
                // EXACTLY one trailing `\n` (never more — a body with a genuine
                // blank line ends in "\n\n" and must keep one) before handing the
                // literal to `appendMappedRun`. This is SAFE for the forward
                // scan: `appendMappedRun` does `sourceNS.range(of: literal)`,
                // i.e. it searches for the (now one-`\n`-shorter) literal as a
                // SUBSTRING of the full source — trimming a suffix off the
                // needle only ever shortens the matched range, it can't cause a
                // miss or shift the match's START, so the recorded segment still
                // begins at the same source location and the map stays valid.
                // The dropped `\n` simply becomes a one-character gap AFTER the
                // segment (consumed "syntax" in the same sense a list marker or
                // `**` is), which `renderedRange` already treats correctly as
                // non-mappable. If the body is ONLY the newline (an empty fence,
                // `.code == "\n"`), trimming yields "" and `appendMappedRun`
                // early-returns via its `!literal.isEmpty` guard — also correct
                // (nothing to render or map).
                var code = codeBlock.code
                if code.hasSuffix("\n") { code.removeLast() }

                // ONE `appendMappedRun` call → ONE identity `SourceMapSegment`
                // over the whole fence body (the interface contract T13
                // consumes). Attributes here are the uniform per-CHARACTER ones
                // (font/color/card fill/marker); paragraph style is applied
                // SEPARATELY below, after the append, as a pure attribute
                // overlay on the range `appendMappedRun` just wrote — it does
                // NOT touch `out.length`, the literal, or the scan cursor, so it
                // cannot perturb the segment or the map.
                //
                // The card's `.backgroundColor` shares the attribute find
                // highlights paint over — see the `.markdownCodeBlockBg` marker
                // doc (RenderedBody.swift) and `clearFindHighlights` for how a
                // find-clear restores this card fill instead of stripping it.
                let codeStart = out.length
                appendMappedRun(code, attributes: [
                    .font: baseFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: MarkdownStyle.codeBlockBackground,
                    .markdownCodeBlockBg: MarkdownStyle.codeBlockBackground
                ])
                applyCodeCardParagraphStyle(over: NSRange(location: codeStart, length: out.length - codeStart))

            default:
                // Any OTHER block T12 doesn't model yet (lists, block quotes,
                // list items, tables, HTML blocks). CRITICAL: no block node
                // conforms to `PlainTextConvertibleMarkup` (only inline types do)
                // and there is no blanket `extension Markup`, so a
                // `block.plainText` cast is always nil — flattening that way would
                // render the block BLANK (silent data loss). Instead RECURSE over
                // the block's children: container blocks yield child blocks (→
                // this same switch, reaching their inner Paragraph/Text with valid
                // segments), and any inline leaves are emitted directly. Result:
                // unmodeled blocks render as readable, copyable, findable plain
                // text now; T13/T14 ADD styling on top of already-correct
                // text+segments. Text is NEVER dropped.
                appendUnmodeledBlockChildren(block)
            }
        }

        /// Recurse an unmodeled block's children so its text always renders. Child
        /// blocks route back through `appendBlock` (with block separators, via
        /// `appendBlocks`); stray inline children are emitted inline. A block with
        /// no children contributes nothing (correct — e.g. a `ThematicBreak`).
        mutating func appendUnmodeledBlockChildren(_ block: Markup) {
            let children = Array(block.children)
            guard !children.isEmpty else { return }
            // Common case: a container block's children are ALL blocks — route
            // them through `appendBlocks` for consistent separators + recursion.
            // Rare mixed case (a stray inline child at block scope): emit each
            // child in its own lane so nothing is lost.
            if children.allSatisfy({ $0 is BlockMarkup }) {
                appendBlocks(children)
            } else {
                for child in children {
                    if child is BlockMarkup {
                        appendBlock(child)
                        out.append(NSAttributedString(string: "\n\n"))
                    } else {
                        appendInline(child, font: proseFont, traits: [], extra: [:])
                    }
                }
            }
        }

        // MARK: Inline level

        /// Render a list of inline nodes under an inherited font + symbolic
        /// traits + extra attributes (e.g. an inline-code background chip).
        /// Takes `[Markup]` (the existential) rather than a generic constrained
        /// `where S.Element: Markup`: `InlineContainer.inlineChildren` yields
        /// `any InlineMarkup`, and an existential type cannot itself *conform* to
        /// `Markup`, so a `: Markup` constraint fails to typecheck. Callers upcast
        /// their children with `.map { $0 as Markup }` (a widening existential
        /// conversion, which is legal).
        mutating func appendInlineChildren(_ inlines: [Markup],
                                           font: NSFont,
                                           traits: NSFontDescriptor.SymbolicTraits,
                                           extra: [NSAttributedString.Key: Any]) {
            for inline in inlines {
                appendInline(inline, font: font, traits: traits, extra: extra)
            }
        }

        mutating func appendInline(_ inline: Markup,
                                   font: NSFont,
                                   traits: NSFontDescriptor.SymbolicTraits,
                                   extra: [NSAttributedString.Key: Any]) {
            switch inline {
            case let textNode as Text:
                var attrs = extra
                attrs[.font] = applying(traits, to: font)
                attrs[.foregroundColor] = extra[.foregroundColor] ?? NSColor.labelColor
                appendMappedRun(textNode.string, attributes: attrs)

            case let emphasis as Emphasis:
                appendInlineChildren(emphasis.inlineChildren.map { $0 as Markup },
                                     font: font,
                                     traits: traits.union(.italic),
                                     extra: extra)

            case let strong as Strong:
                appendInlineChildren(strong.inlineChildren.map { $0 as Markup },
                                     font: font,
                                     traits: traits.union(.bold),
                                     extra: extra)

            case let code as InlineCode:
                // Inline code keeps the monospaced identity (baseFont), plus a
                // subtle chip background. Its literal is the `.code` string; map
                // it forward-scan like any other preserved text.
                var attrs = extra
                attrs[.font] = baseFont
                attrs[.foregroundColor] = NSColor.labelColor
                attrs[.backgroundColor] = MarkdownStyle.inlineCodeChip
                // Marker so a find-highlight clear can restore this chip instead
                // of stripping it (find and the chip share `.backgroundColor`).
                attrs[.markdownCodeChip] = MarkdownStyle.inlineCodeChip
                appendMappedRun(code.code, attributes: attrs)

            case let link as Link:
                // Render the link's visible children with a `.link` attribute so
                // the destination is clickable; the visible text is still mapped.
                var childExtra = extra
                if let dest = link.destination, let url = URL(string: dest) {
                    childExtra[.link] = url
                }
                childExtra[.foregroundColor] = MarkdownStyle.linkColor
                appendInlineChildren(link.inlineChildren.map { $0 as Markup },
                                     font: font, traits: traits, extra: childExtra)

            case is SoftBreak:
                // A soft line break renders as a single space (CommonMark). No
                // source segment (the source newline is consumed whitespace).
                out.append(NSAttributedString(string: " "))

            case is LineBreak:
                out.append(NSAttributedString(string: "\n"))

            case let container as any InlineContainer:
                // Any other inline container (e.g. strikethrough) — recurse so its
                // text still renders and maps, even without a bespoke style.
                appendInlineChildren(container.inlineChildren.map { $0 as Markup },
                                     font: font, traits: traits, extra: extra)

            default:
                // Leaf inline we don't special-case: append its plain text mapped.
                if let plain = (inline as? PlainTextConvertibleMarkup)?.plainText, !plain.isEmpty {
                    var attrs = extra
                    attrs[.font] = applying(traits, to: font)
                    attrs[.foregroundColor] = extra[.foregroundColor] ?? NSColor.labelColor
                    appendMappedRun(plain, attributes: attrs)
                }
            }
        }

        // MARK: Segment-recording append

        /// Append `literal` with `attributes`, recording a `SourceMapSegment` that
        /// ties its rendered location to the forward-scanned position of `literal`
        /// in the source.
        ///
        /// The append is UNCONDITIONAL — the rendered text is added FIRST, before
        /// the scan — so a scan miss can never drop content. A miss happens when
        /// cmark decodes an escape or entity (`\*`→`*`, `&amp;amp;`→`&amp;`), so `Text.string`
        /// no longer matches the source bytes and `range(of:)` is `NSNotFound`.
        /// In that case we STILL render + copy the decoded literal; we only skip
        /// its source-map segment. Consequence: a find match landing on that
        /// escaped/entity run degrades to the pill/count (no in-body paint) —
        /// confirmed SAFE (never mispaints), a known T12 limitation.
        mutating func appendMappedRun(_ literal: String, attributes: [NSAttributedString.Key: Any]) {
            guard !literal.isEmpty else { return }
            let renderedLocation = out.length
            out.append(NSAttributedString(string: literal, attributes: attributes)) // always render

            let searchRange = NSRange(location: scanCursor, length: sourceNS.length - scanCursor)
            let found = sourceNS.range(of: literal, options: [], range: searchRange)
            // Scan miss (escaped/entity-decoded run): keep the rendered text, skip
            // the segment. Find degrades to pill for this run (safe).
            guard found.location != NSNotFound else { return }
            segments.append(SourceMapSegment(sourceRange: found, renderedLocation: renderedLocation))
            scanCursor = NSMaxRange(found)
        }

        // MARK: Code-card paragraph styling

        /// Apply the fenced-code-block "card" `NSParagraphStyle` over `range`
        /// (already-appended text — see the `CodeBlock` case). Every NON-EMPTY
        /// line in the range gets the head/tail indent (the card's horizontal
        /// inset), but ONLY the first such line gets `paragraphSpacingBefore`
        /// and ONLY the last gets `paragraphSpacing` (after). Applying one
        /// uniform `NSParagraphStyle` with both spacings set over a MULTI-LINE
        /// run would insert that spacing at EVERY internal paragraph break too
        /// — verified empirically via `NSLayoutManager` line-fragment
        /// measurement, a uniform style produces a visibly taller gap between
        /// every code line, not just top/bottom of the card. Splitting per-line
        /// (paragraph, in `NSParagraphStyle` terms, means "between `\n`s") keeps
        /// interior lines tight and only pads the card's outer edge — the
        /// actual "reads as one card" look the brief asks for.
        ///
        /// First pass collects every line's range and clips zero-length ones
        /// (a leading/trailing/internal blank line in the fence body); the
        /// edge spacing is then keyed off the first/last NON-EMPTY entry rather
        /// than the first/last loop iteration — a fence that happens to open
        /// with a blank line (`code == "\n\nlet x = 1"` after the one-newline
        /// trim) would otherwise attach `paragraphSpacingBefore` to that empty
        /// line, which carries zero characters and so is never applied to any
        /// glyph, silently dropping the card's top padding in that corner case.
        ///
        /// This runs strictly AFTER `out.append` in `appendMappedRun`, so it
        /// only overlays `.paragraphStyle` on already-written characters — it
        /// cannot affect `out.length`, the scan cursor, or the recorded
        /// `SourceMapSegment`.
        mutating func applyCodeCardParagraphStyle(over range: NSRange) {
            guard range.length > 0 else { return }
            let text = out.string as NSString
            var lineRanges: [NSRange] = []
            var lineStart = range.location
            let rangeEnd = NSMaxRange(range)
            while lineStart < rangeEnd {
                var lineEnd = 0
                var contentEnd = 0
                text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentEnd,
                                   for: NSRange(location: lineStart, length: 0))
                // Clip to the code range: `getLineStart` walks the FULL string's
                // line boundaries, which for the run's last line extends past
                // `rangeEnd` into whatever rendered content follows (the "\n\n"
                // block separator or a sibling block) — clamp so the style never
                // paints outside the code card.
                let clippedContentEnd = min(contentEnd, rangeEnd)
                let lineRange = NSRange(location: lineStart, length: clippedContentEnd - lineStart)
                if lineRange.length > 0 { lineRanges.append(lineRange) }
                if lineEnd <= lineStart { break } // safety: no forward progress
                lineStart = lineEnd
            }
            guard !lineRanges.isEmpty else { return }
            for (index, lineRange) in lineRanges.enumerated() {
                let style = NSMutableParagraphStyle()
                style.headIndent = 11
                style.firstLineHeadIndent = 11
                style.tailIndent = -11
                style.lineBreakMode = .byCharWrapping
                if index == 0 { style.paragraphSpacingBefore = 6 }
                if index == lineRanges.count - 1 { style.paragraphSpacing = 6 }
                out.addAttribute(.paragraphStyle, value: style, range: lineRange)
            }
        }

        // MARK: Font trait application

        /// Return `font` with `traits` merged into its descriptor. Falls back to
        /// the untraited font when the requested face isn't available.
        func applying(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
            guard !traits.isEmpty else { return font }
            let merged = font.fontDescriptor.symbolicTraits.union(traits)
            let descriptor = font.fontDescriptor.withSymbolicTraits(merged)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }

        // MARK: Finish

        func finish() -> RenderedBody {
            RenderedBody(attributed: NSAttributedString(attributedString: out),
                         segments: segments,
                         renderedLength: out.length,
                         unmappableSourceRanges: [])
        }
    }
}

/// Appearance-resolved style tokens for markdown bodies. Colors are DYNAMIC
/// `NSColor`s so the same instance resolves per appearance; the render cache is
/// keyed by `isDark` and rebuilt on an appearance flip, so a baked
/// `.backgroundColor` chip stays correct without live re-resolution.
private enum MarkdownStyle {
    /// Subtle background chip behind inline code. `.quaternaryLabelColor`
    /// resolves to a light-on-dark-text tint that is legible against BOTH the
    /// dark-card fence background and the plain prose background — it is a
    /// text-relative gray, not a fixed light/dark swatch, so it doesn't need an
    /// `isDark` branch: quaternary alpha over the underlying control color reads
    /// as a faint fill in both appearances (spot-checked against
    /// `.textBackgroundColor` in each).
    static var inlineCodeChip: NSColor { .quaternaryLabelColor }
    /// Dark inset card behind a fenced code block. Deliberately NOT
    /// `isDark`-branched: `.underPageBackgroundColor` is itself a dynamic system
    /// color that resolves to a slightly recessed tone relative to the page
    /// background in EACH appearance (a soft dark-gray card in dark mode, a
    /// soft light-gray card in light mode) — exactly the "inset card" look the
    /// brief asks for, without hand-picking two fixed swatches that could drift
    /// from the system's own appearance transitions.
    static var codeBlockBackground: NSColor { .underPageBackgroundColor }
    /// Link text color — the standard control accent.
    static var linkColor: NSColor { .linkColor }
}
