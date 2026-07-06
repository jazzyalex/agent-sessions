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
        /// Source ranges whose rendered form is NOT find-highlightable (Task 15:
        /// table cells). `renderedRange` returns nil for any find match that
        /// intersects one of these, so the match falls back to the header
        /// pill/count instead of trying to paint an in-cell highlight — see
        /// `RenderedBody.renderedRange` (it consults this list FIRST, before the
        /// segment lookup). Populated only by the `Table` handler.
        var unmappable: [NSRange] = []

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
                // Gentle em ramp off the prose (1em) size — h1 1.35em tapering
                // to 1.0em by h4 — reads as clear hierarchy without the flat
                // per-level bump this replaced, which pushed H1 to 25pt on a
                // 13pt base and read as a billboard, not a heading.
                let headingFont = NSFont.boldSystemFont(ofSize: proseFont.pointSize * MarkdownStyle.headingEmRatio(for: heading.level))
                let start = out.length
                appendInlineChildren(heading.inlineChildren.map { $0 as Markup },
                                     font: headingFont,
                                     traits: .bold,
                                     extra: [:])
                applyProseParagraphStyle(from: start, isHeading: true)
            case let paragraph as Paragraph:
                let start = out.length
                appendInlineChildren(paragraph.inlineChildren.map { $0 as Markup },
                                     font: proseFont,
                                     traits: [],
                                     extra: [:])
                applyProseParagraphStyle(from: start, isHeading: false)
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
                // Resolve the card fill ONCE and reuse the same instance for both
                // `.backgroundColor` and the `.markdownCodeBlockBg` find-restore
                // marker. `codeBlockBackground` is a hand-rolled `NSColor(name:
                // nil) { ... }` dynamic color (needed for the two-shade-per-
                // appearance card fill), and each access constructs a NEW
                // instance — two separately-resolved instances are not `==`, so
                // `clearFindHighlights`' `value as? NSColor` restore would
                // "succeed" but produce a color that fails equality against the
                // original in tests (and, worse, could resolve to visually
                // different output if the closure ever became appearance-history
                // -dependent). Binding once guarantees find-clear restores the
                // EXACT instance that was originally painted.
                let codeCardFill = MarkdownStyle.codeBlockBackground
                let codeStart = out.length
                appendMappedRun(code, attributes: [
                    .font: baseFont,
                    .foregroundColor: MarkdownStyle.codeBlockText,
                    .backgroundColor: codeCardFill,
                    .markdownCodeBlockBg: codeCardFill
                ])
                applyCodeCardParagraphStyle(over: NSRange(location: codeStart, length: out.length - codeStart))

            case let list as UnorderedList:
                // Task 14: bullet list. `listItems` (from `ListItemContainer`)
                // enumerates the list's `ListItem` children in source order;
                // 0-based `offset` becomes the 1-based bullet — irrelevant for
                // an unordered marker (always "•") but shared plumbing with the
                // ordered case below via `appendListItems`.
                appendListItems(Array(list.listItems), markerFor: { _ in "•" }, depth: 0)

            case let list as OrderedList:
                // Task 14: numbered list. CommonMark lets a list start at any
                // number (`3. foo` → `startIndex == 3`, confirmed against the
                // checked-out swift-markdown package); each subsequent marker
                // increments from there, so the Nth item (0-based `offset`) is
                // numbered `startIndex + offset`, NOT a plain 1-based position.
                let start = list.startIndex
                appendListItems(Array(list.listItems), markerFor: { offset in "\(start + UInt(offset))." }, depth: 0)

            case let table as Table:
                // Task 15: GFM table → real `NSTextTable` (borders + padding).
                // Highest risk / lowest frequency, so it ships last.
                appendTable(table)

            case let blockQuote as BlockQuote:
                // Blockquotes previously fell through to the generic unmodeled-
                // block recursion with NO styling at all — plain paragraph text,
                // indistinguishable from a normal quote-less paragraph. A quoted
                // block reads best with a left accent + indent + de-emphasized
                // text (a well-established quoting convention, not something
                // specific to any one reference app). NSAttributedString has no
                // left-BORDER primitive (only headIndent/firstLineHeadIndent,
                // which shift text but paint no rule), so we approximate the bar
                // with a leading "▎" glyph — reads as an accent stripe without
                // attempting custom glyph/border drawing (out of scope). The bar
                // is RENDERED-ONLY (appended directly, not through
                // `appendMappedRun`), so it contributes no source segment and
                // cannot perturb the map — same discipline as the list marker
                // glyph.
                //
                // Recurses over the quote's own block children (usually a single
                // Paragraph) via `appendUnmodeledBlockChildren` so nested
                // structure (multi-paragraph quotes) still renders and maps
                // correctly; the secondary-color + indent style is then overlaid
                // on the WHOLE quote range, mirroring the code-card/list-item
                // post-hoc styling pattern.
                let quoteStart = out.length
                out.append(NSAttributedString(string: "▎ ", attributes: [
                    .font: proseFont,
                    .foregroundColor: MarkdownStyle.blockquoteText
                ]))
                appendUnmodeledBlockChildren(blockQuote)
                applyBlockquoteStyle(over: NSRange(location: quoteStart, length: out.length - quoteStart))

            default:
                // Any OTHER block not modeled yet (block quotes, tables, HTML
                // blocks — lists gained dedicated cases in T14). CRITICAL: no
                // block node conforms to `PlainTextConvertibleMarkup` (only
                // inline types do)
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

        // MARK: List rendering (Task 14)

        /// Render every `ListItem` in a bullet/numbered list: RENDERED-ONLY
        /// marker (`"•\t"` / `"N.\t"`) + the item's own content (mapped
        /// normally), indented by `depth`. `markerFor` returns the bare glyph
        /// (no tab) for the item at 0-based `offset`; the tab is appended here
        /// so both call sites (bullet vs. numbered) share one indent/tab-stop
        /// path instead of duplicating it.
        ///
        /// Items are joined by a single rendered-only `"\n"` (a TIGHT list,
        /// matching CommonMark's normalized `ListItem`/`Paragraph` shape —
        /// confirmed empirically that even a "loose" source list with blank
        /// lines between `- a` / `- b` still yields exactly one `Paragraph`
        /// per `ListItem`, so there's no loose-vs-tight distinction to carry
        /// here). The list itself gets NO leading/trailing separator beyond
        /// that — surrounding `appendBlocks`/`appendUnmodeledBlockChildren`
        /// already inserts the standard `"\n\n"` before/after the whole list
        /// as a sibling block.
        mutating func appendListItems(_ items: [ListItem], markerFor: (Int) -> String, depth: Int) {
            for (offset, item) in items.enumerated() {
                let itemStart = out.length
                // Marker is RENDERED-ONLY: appended directly to `out`, never
                // through `appendMappedRun`, so it contributes no
                // `SourceMapSegment` and cannot perturb `scanCursor`. It is a
                // gap in SOURCE coverage exactly like consumed `**`/backtick
                // syntax — `renderedRange` already tolerates that (see the
                // `SourceMapSegment` doc in RenderedBody.swift: "a gap in
                // rendered coverage = inserted glyphs").
                out.append(NSAttributedString(string: markerFor(offset) + "\t", attributes: [
                    .font: proseFont,
                    .foregroundColor: NSColor.labelColor
                ]))
                // `appendListItemChildren` returns where THIS item's own
                // (marker + direct paragraph) content ends — which may be
                // SHORTER than `out.length` after the call if a nested
                // sub-list followed. That nested range was already styled at
                // `depth + 1` by its own recursive `appendListItems` call;
                // styling `[itemStart, out.length)` here (the naive "whole
                // item" range) would `addAttribute` OVER that already-written
                // sub-range and clobber its deeper indent with this shallower
                // one, since attribute application always wins for whatever
                // ran LAST. Scoping to `[itemStart, ownContentEnd)` — this
                // item's marker + direct text only — keeps every depth's style
                // confined to the range it authored and never touched again.
                let ownContentEnd = appendListItemChildren(item, depth: depth)
                applyListItemParagraphStyle(over: NSRange(location: itemStart, length: ownContentEnd - itemStart), depth: depth)
                if offset < items.count - 1 {
                    out.append(NSAttributedString(string: "\n"))
                }
            }
        }

        /// Render one `ListItem`'s block children. A `ListItem` normally holds
        /// exactly one `Paragraph` (the item's own text) optionally followed by
        /// a NESTED `UnorderedList`/`OrderedList` (confirmed against the
        /// checked-out swift-markdown package for `"- a\n  - b"`: the sub-list
        /// is a SIBLING block after the `Paragraph`, inside the same
        /// `ListItem` — not a grandchild of the `Text` leaf). The nested list
        /// recurses through `appendListItems` at `depth + 1`, preceded by a
        /// single rendered-only `"\n"` so it starts its own line without the
        /// full `"\n\n"` block-separator gap (it's part of THIS item, not a
        /// sibling block of it). Any other child shape (a block quote inside a
        /// list item, etc.) falls back to the existing `appendBlock`/inline
        /// paths so nothing is silently dropped — same discipline as
        /// `appendUnmodeledBlockChildren`.
        ///
        /// Returns `out.length` measured immediately BEFORE any nested
        /// sub-list is appended (i.e. right after this item's own marker +
        /// direct paragraph text) — see the caller comment above for why that
        /// boundary, not the post-recursion `out.length`, is what must be
        /// paragraph-styled at THIS depth.
        @discardableResult
        mutating func appendListItemChildren(_ item: ListItem, depth: Int) -> Int {
            var ownContentEnd = out.length
            for child in item.blockChildren {
                switch child {
                case let paragraph as Paragraph:
                    appendInlineChildren(paragraph.inlineChildren.map { $0 as Markup },
                                         font: proseFont,
                                         traits: [],
                                         extra: [:])
                    ownContentEnd = out.length
                case let nested as UnorderedList:
                    out.append(NSAttributedString(string: "\n"))
                    appendListItems(Array(nested.listItems), markerFor: { _ in "•" }, depth: depth + 1)
                case let nested as OrderedList:
                    out.append(NSAttributedString(string: "\n"))
                    let start = nested.startIndex
                    appendListItems(Array(nested.listItems), markerFor: { offset in "\(start + UInt(offset))." }, depth: depth + 1)
                default:
                    appendBlock(child)
                    ownContentEnd = out.length
                }
            }
            return ownContentEnd
        }

        /// Apply the list-item indent `NSParagraphStyle` over `range` (already
        /// appended — marker + item content). Mirrors
        /// `applyCodeCardParagraphStyle`: runs strictly AFTER the content is in
        /// `out`, so it only overlays `.paragraphStyle` on existing characters
        /// — it cannot affect `out.length`, `scanCursor`, or any recorded
        /// `SourceMapSegment`. `headIndent`/`firstLineHeadIndent` scale by
        /// `depth` (one level ≈ one marker-column's worth of indent) so a
        /// wrapped line of item text — or an entire nested sub-list — lines up
        /// under the marker rather than the leading edge; the matching tab
        /// stop at the same offset is what makes the `"\t"` after the marker
        /// glyph land text at that indent instead of a default 28pt stop.
        mutating func applyListItemParagraphStyle(over range: NSRange, depth: Int) {
            guard range.length > 0 else { return }
            let indent: CGFloat = 20 * CGFloat(depth + 1)
            let style = NSMutableParagraphStyle()
            style.headIndent = indent
            style.firstLineHeadIndent = indent - 20
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = MarkdownStyle.proseLineSpacing
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }

        /// Apply prose line-height to a paragraph/heading's rendered range. Like
        /// the list/fence styles it runs AFTER the text is in `out`, overlaying
        /// only `.paragraphStyle` — never touching `out.length`/`scanCursor`/
        /// segments, so the source map is unaffected. NSAttributedString adds no
        /// inter-line spacing by default (unlike web's line-height), which reads
        /// cramped; a small `lineSpacing` restores comfortable rhythm, and
        /// headings get space above for section hierarchy.
        mutating func applyProseParagraphStyle(from start: Int, isHeading: Bool) {
            guard out.length > start else { return }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = MarkdownStyle.proseLineSpacing
            style.lineBreakMode = .byWordWrapping
            if isHeading { style.paragraphSpacingBefore = MarkdownStyle.headingSpacingBefore }
            out.addAttribute(.paragraphStyle, value: style,
                             range: NSRange(location: start, length: out.length - start))
        }

        /// Apply the blockquote's indent + secondary-text-color styling over
        /// `range` (the "▎ " bar glyph + the quote's already-appended child
        /// content). Runs strictly AFTER the append — like every other
        /// paragraph-style overlay in this file it only adds `.paragraphStyle`/
        /// `.foregroundColor` attributes on existing characters, so it cannot
        /// affect `out.length`, `scanCursor`, or any recorded `SourceMapSegment`.
        ///
        /// `.foregroundColor` is applied here (rather than threaded through
        /// `extra` down the block-recursion chain that renders the quote's
        /// child paragraphs) because `appendBlock`/`appendUnmodeledBlockChildren`
        /// don't plumb an inherited color parameter — overlaying post-hoc over
        /// the whole quote range is the same "style what's already rendered"
        /// approach already used for code cards and list indents, and avoids
        /// widening those functions' signatures for a single caller.
        mutating func applyBlockquoteStyle(over range: NSRange) {
            guard range.length > 0 else { return }
            let style = NSMutableParagraphStyle()
            // Comfortable horizontal inset off the leading edge (no vertical/
            // block padding primitive in NSAttributedString, but the "▎" bar
            // glyph plus this indent together read as a quoted block).
            style.headIndent = MarkdownStyle.blockquoteIndent
            style.firstLineHeadIndent = MarkdownStyle.blockquoteIndent
            style.lineSpacing = MarkdownStyle.proseLineSpacing
            style.lineBreakMode = .byWordWrapping
            out.addAttribute(.paragraphStyle, value: style, range: range)
            out.addAttribute(.foregroundColor, value: MarkdownStyle.blockquoteText, range: range)
        }

        // MARK: Table rendering (Task 15)

        /// Render a GFM `Table` as a real `NSTextTable` (TextKit's native table
        /// layout), so it displays with column borders and measures correctly.
        ///
        /// ## Why `NSTextTable`, not a monospaced ASCII grid
        ///
        /// The acceptance gate is "measures via the `NSLayoutManager.usedRect`
        /// path and does not clip" (the Phase-1 ShowAll bug class). The
        /// controller already routes EVERY markdown body through
        /// `measuredHeight(of:width:)` (a throwaway `NSLayoutManager` +
        /// `usedRect`), NOT `boundingRect` — verified in
        /// `TranscriptBlockListView.measuredHeight`/`markdownCardHeight`. Empirical
        /// probe of that exact path on a 3-row `NSTextTable`: `usedRect` reports
        /// the full multi-row table height (≈5.9× a single prose line — three
        /// rows + borders + padding), so the row height the controller computes
        /// matches what actually lays out. `NSTextTable` is therefore safe here;
        /// the memo's R2 caution ("tables mismeasure under `boundingRect`") is
        /// exactly why markdown rows use the layout-manager path, and this handler
        /// simply relies on that already-established routing. No plain-grid
        /// fallback is needed.
        ///
        /// ## Find / source-map: cell text is UNMAPPABLE (→ pill), by design
        ///
        /// Each cell's inline content is walked through the normal inline
        /// recursion so it RENDERS and COPIES ("copy what you see": cells join
        /// with `\n`, which is how `NSTextTable` paragraphs read on the
        /// pasteboard). That recursion may incidentally forward-scan-match a
        /// cell's literal and record a `SourceMapSegment` — but we then record
        /// the WHOLE table's cell-text source span as one `unmappable` range, and
        /// `RenderedBody.renderedRange` consults `unmappableSourceRanges` FIRST,
        /// so ANY find match inside the table returns nil and falls back to the
        /// header pill/count (no in-cell paint). This is the intended behavior and
        /// the simpler of the brief's two options: rather than compute each cell's
        /// exact source range (which would need the UTF-8→UTF-16 remap this file
        /// deliberately avoids — see the source-map doc comment), we bracket the
        /// table with the forward-scan cursor. `scanCursor` is the same monotonic
        /// UTF-16 offset the segment scan uses; capturing it before the first cell
        /// and after the last yields `[start, end)` covering exactly the cell-text
        /// region in source, robust for Unicode by construction. Any table match
        /// lands in that span → nil → pill.
        mutating func appendTable(_ table: Table) {
            let columnCount = max(1, table.maxColumnCount)
            let textTable = NSTextTable()
            textTable.numberOfColumns = columnCount
            // Let columns size to content up to the container width, matching how
            // the row measures (percentage-of-container content width).
            textTable.setContentWidth(100, type: .percentageValueType)

            let alignments = table.columnAlignments

            // Bracket the whole table's cell text as one unmappable source span
            // using the forward-scan cursor (UTF-16, robust) — see the doc above.
            let sourceStart = scanCursor

            // Header row (row 0): bold cells.
            let headerCells = Array(table.head.cells)
            for (col, cell) in headerCells.enumerated() {
                appendTableCell(cell, table: textTable, row: 0, column: col,
                                alignments: alignments, bold: true)
            }
            // Pad a short header row out to columnCount so the grid is rectangular
            // (GFM guarantees rows are padded, but head can be the max — belt and
            // suspenders against an empty trailing column).
            for col in headerCells.count..<columnCount {
                appendEmptyTableCell(table: textTable, row: 0, column: col, alignments: alignments)
            }

            // Body rows (row 1…): normal weight.
            for (bodyIndex, row) in table.body.rows.enumerated() {
                let rowIndex = bodyIndex + 1
                let cells = Array(row.cells)
                for (col, cell) in cells.enumerated() where col < columnCount {
                    appendTableCell(cell, table: textTable, row: rowIndex, column: col,
                                    alignments: alignments, bold: false)
                }
                for col in cells.count..<columnCount {
                    appendEmptyTableCell(table: textTable, row: rowIndex, column: col, alignments: alignments)
                }
            }

            let sourceEnd = scanCursor
            if sourceEnd > sourceStart {
                unmappable.append(NSRange(location: sourceStart, length: sourceEnd - sourceStart))
            }
        }

        /// Append one table cell: its inline content (rendered + copyable) inside
        /// an `NSTextTableBlock` paragraph with a thin border + padding. The cell
        /// text is emitted through the normal inline recursion (so nested
        /// emphasis/code/links render), then a trailing `\n` closes the cell's
        /// paragraph — `NSTextTable` places one paragraph per cell, so the newline
        /// is what makes the block a distinct cell rather than merging with the
        /// next. Header cells force `.bold` via the inline traits.
        mutating func appendTableCell(_ cell: Table.Cell,
                                      table: NSTextTable,
                                      row: Int, column: Int,
                                      alignments: [Table.ColumnAlignment?],
                                      bold: Bool) {
            let cellStart = out.length
            // Explicit `[Markup]` (not the lazy inferred `LazyMapSequence`): the
            // annotation forces eager evaluation so `.isEmpty` and the
            // `[Markup]` parameter below both typecheck.
            let inlines: [Markup] = cell.inlineChildren.map { $0 as Markup }
            if inlines.isEmpty {
                // An empty cell still needs a paragraph so the block occupies its
                // grid slot; emit a zero-width placeholder that carries the style.
                out.append(NSAttributedString(string: ""))
            } else {
                // Header cells are bold via the inline `traits` path (mirrors the
                // Heading case): `appendInline` applies `applying(traits, to:font)`
                // per Text leaf, merging the `.bold` symbolic trait into proseFont.
                appendInlineChildren(inlines,
                                     font: proseFont,
                                     traits: bold ? .bold : [],
                                     extra: [:])
            }
            // Close the cell paragraph. This rendered-only newline carries no
            // source segment (like a list marker), so it never shifts the map.
            out.append(NSAttributedString(string: "\n"))
            applyTableCellStyle(over: NSRange(location: cellStart, length: out.length - cellStart),
                                table: table, row: row, column: column, alignments: alignments, isHeader: row == 0)
        }

        /// Append a rendered-only empty cell (padding a short row out to the
        /// table's column count). No inline content, no source consumed — just an
        /// `NSTextTableBlock` paragraph so the grid stays rectangular.
        mutating func appendEmptyTableCell(table: NSTextTable,
                                           row: Int, column: Int,
                                           alignments: [Table.ColumnAlignment?]) {
            let cellStart = out.length
            out.append(NSAttributedString(string: "\n"))
            applyTableCellStyle(over: NSRange(location: cellStart, length: out.length - cellStart),
                                table: table, row: row, column: column, alignments: alignments, isHeader: row == 0)
        }

        /// Build the `NSTextTableBlock` for `(row, column)` and stamp its
        /// paragraph style (block + column alignment) over `range` — the cell
        /// content already appended. Runs strictly AFTER the append, so it only
        /// overlays `.paragraphStyle`; it cannot touch `out.length`, the scan
        /// cursor, or any recorded segment (same discipline as the code-card and
        /// list-indent styling).
        func applyTableCellStyle(over range: NSRange,
                                 table: NSTextTable,
                                 row: Int, column: Int,
                                 alignments: [Table.ColumnAlignment?],
                                 isHeader: Bool) {
            guard range.length > 0 else { return }
            // Known limitation: GFM cell spans (colspan/rowspan) are flattened to
            // 1×1 — a spanned cell renders as a normal cell followed by empty
            // placeholder cell(s). Safe (no crash, no text loss — cmark emits the
            // spanned-over cells as empty nodes) and vanishingly rare in
            // transcript prose; honoring spans is deferred.
            let block = NSTextTableBlock(table: table,
                                         startingRow: row, rowSpan: 1,
                                         startingColumn: column, columnSpan: 1)
            block.setBorderColor(MarkdownStyle.tableBorder)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            // Comfortable cell padding, a touch more room horizontally than
            // vertically (columns need breathing room more than rows do); set
            // edges individually since the two axes differ (the old 5pt-all-edges
            // approximation read cramped).
            block.setWidth(MarkdownStyle.tableCellHorizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(MarkdownStyle.tableCellHorizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(MarkdownStyle.tableCellVerticalPadding, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(MarkdownStyle.tableCellVerticalPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
            // Header row gets a subtle fill so it's visibly distinct from body
            // rows at a glance — the owner specifically called out that the old
            // renderer's tables lacked this distinction.
            if isHeader {
                block.backgroundColor = MarkdownStyle.tableHeaderBackground
            }

            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            style.lineBreakMode = .byWordWrapping
            // Per-column alignment from GFM `columnAlignments` (nil → left).
            style.alignment = Self.nsAlignment(alignments.indices.contains(column) ? alignments[column] : nil)
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }

        /// Map a GFM column alignment to an `NSTextAlignment` (default left).
        static func nsAlignment(_ a: Table.ColumnAlignment?) -> NSTextAlignment {
            switch a {
            case .center: return .center
            case .right: return .right
            case .left, .none: return .left
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
                // Inline code keeps the monospaced identity, sized down a notch
                // off baseFont for a tighter, chip-like scale (a plain same-size
                // monospace run read as oversized next to prose). A real chip
                // would want a border + rounded corners, but
                // `NSAttributedString.backgroundColor` can't draw either — the
                // smaller font plus a modestly-more-defined fill is the closest
                // tasteful approximation without custom glyph drawing (out of
                // scope). Its literal is the `.code` string; map it forward-scan
                // like any other preserved text.
                // Inline code is distinguished by its MONOSPACE font against the
                // proportional prose — NO background chip. Backticked spans in
                // agent messages are frequent and often arbitrary (an email, a
                // bare number, a whole error line), so a per-span background reads
                // as random gray boxes; the monospace face alone marks it as a
                // literal without the visual noise. (Find highlighting still uses
                // `.backgroundColor` on a match; with no chip there's nothing to
                // clash with or restore.)
                var attrs = extra
                attrs[.font] = NSFont(descriptor: baseFont.fontDescriptor, size: baseFont.pointSize * MarkdownStyle.inlineCodeFontScale) ?? baseFont
                attrs[.foregroundColor] = NSColor.labelColor
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
                // Comfortable card padding: horizontal inset on every line via
                // head/tail indent, vertical inset via the first/last line's
                // paragraph spacing (see the doc above for why that has to be
                // split per-line rather than one uniform style).
                style.headIndent = MarkdownStyle.codeCardHorizontalPadding
                style.firstLineHeadIndent = MarkdownStyle.codeCardHorizontalPadding
                style.tailIndent = -MarkdownStyle.codeCardHorizontalPadding
                style.lineBreakMode = .byCharWrapping
                if index == 0 { style.paragraphSpacingBefore = MarkdownStyle.codeCardVerticalPadding }
                if index == lineRanges.count - 1 { style.paragraphSpacing = MarkdownStyle.codeCardVerticalPadding }
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
                         unmappableSourceRanges: unmappable)
        }
    }
}

/// Appearance-resolved style tokens for markdown bodies. Colors are DYNAMIC
/// `NSColor`s so the same instance resolves per appearance; the render cache is
/// keyed by `isDark` and rebuilt on an appearance flip, so a baked
/// `.backgroundColor` chip stays correct without live re-resolution.
///
/// These tokens are Agent Sessions' OWN palette — tuned for readability against
/// AgentsView as a UX-pattern reference (hierarchy, a distinct code card, a
/// visibly distinct table header, restrained inline chips), NOT as a color
/// spec to copy. No AgentsView hex value (its Catppuccin-derived `#1e1e2e` /
/// `#0d0d14` / `#cdd6f4`) appears here; every color below is either a system
/// semantic color (already appearance-correct by definition) or a hand-rolled
/// alpha wash resolved per-appearance the same way `inlineCodeChip` always has.
private enum MarkdownStyle {
    /// Tasteful middle ground for the inline-code chip: distinct enough to read
    /// as a chip (the owner disliked the old near-invisible ~5% wash) without
    /// becoming the heavy gray box the owner also rejected earlier. Inline code
    /// already reads as distinct because prose is proportional and code is
    /// monospaced — this is reinforcement, not the primary signal — so the bump
    /// stays modest (~9–10%) rather than matching a bordered-chip look we can't
    /// actually draw (`.backgroundColor` can't paint a border or radius).
    static var inlineCodeChip: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(white: 1.0, alpha: 0.10) : NSColor(white: 0.0, alpha: 0.09)
        }
    }
    /// Relative size of the inline-code font vs. `baseFont` — a tighter,
    /// chip-like scale-down so an inline code run reads as a smaller inset
    /// element rather than same-size monospace competing with the surrounding
    /// prose; 0.9x stays comfortably legible while still reading smaller.
    static let inlineCodeFontScale: CGFloat = 0.9

    /// Fenced-code-block card fill: a restrained, genuinely dark editor-style
    /// card in BOTH appearances — the distinctive "this is code" signal the old
    /// flat/adaptive-gray treatment lacked — built from our own neutral dark
    /// tone (not a copied Catppuccin swatch) and tuned slightly lighter in dark
    /// mode so the card still reads as recessed against a dark chat background.
    static var codeBlockBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // A SUBTLE inset — NOT a heavy near-black slab. Light-gray in light
            // mode, a gently-recessed tone in dark mode: enough to read as a
            // code block without a black box dominating the transcript.
            return isDark ? NSColor(calibratedWhite: 0.22, alpha: 1.0) : NSColor(calibratedWhite: 0.94, alpha: 1.0)
        }
    }
    /// Code-card text uses the standard label color — with a subtle (not dark)
    /// card fill, normal text contrast reads correctly in both appearances.
    static var codeBlockText: NSColor { .labelColor }
    /// Link text color — the standard control accent.
    static var linkColor: NSColor { .linkColor }
    /// Line spacing between wrapped lines of prose/list text. A comfortable
    /// reading rhythm — NSAttributedString adds no inter-line spacing by
    /// default (unlike web line-height), which reads cramped without it.
    static let proseLineSpacing: CGFloat = 7
    /// Heading rhythm: gentle spacing above a heading so it reads as section
    /// hierarchy rather than just larger inline text.
    static let headingSpacingBefore: CGFloat = 11
    static let headingSpacingAfter: CGFloat = 5

    /// Heading font-size ramp, expressed as a ratio of the prose (1em) size —
    /// H1 noticeably larger, tapering down to body size by H4, so hierarchy
    /// reads as gentle emphasis rather than a billboard.
    static func headingEmRatio(for level: Int) -> CGFloat {
        switch level {
        case 1: return 1.35
        case 2: return 1.2
        case 3: return 1.1
        default: return 1.0
        }
    }

    /// Fenced-code-block card padding (Task 13 restyle): horizontal inset via
    /// head/tail indent, vertical inset via first/last-line paragraph spacing.
    static let codeCardHorizontalPadding: CGFloat = 14
    static let codeCardVerticalPadding: CGFloat = 8

    /// Thin cell border for GFM tables (Task 15). `.separatorColor` is a dynamic
    /// system color that resolves to a hairline divider tone in BOTH appearances
    /// (a faint light line on dark, a faint dark line on light), matching the
    /// system's own table/list separators without hand-picking two swatches.
    static var tableBorder: NSColor { .separatorColor }
    /// Table cell padding — comfortable spacing without the cramped 5pt-all-edges
    /// approximation; a touch more room horizontally than vertically, matching
    /// how a normal table's row height vs. column gutter reads.
    static let tableCellHorizontalPadding: CGFloat = 8
    static let tableCellVerticalPadding: CGFloat = 5
    /// Header row fill: a subtle system-derived wash that makes the header band
    /// visibly distinct from body rows without hand-picking an inset-panel hex.
    /// Same hand-rolled-appearance-aware-alpha technique as `inlineCodeChip`
    /// (there is no bordered system token for "table header fill"), kept a
    /// notch stronger than the inline-code chip since it must read at a glance
    /// across a whole row, not just a few characters.
    static var tableHeaderBackground: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(white: 1.0, alpha: 0.08) : NSColor(white: 0.0, alpha: 0.05)
        }
    }
    /// Blockquote text: the system's own "secondary" semantic label color —
    /// already appearance-correct by definition, matching how the rest of the
    /// app dims de-emphasized text.
    static var blockquoteText: NSColor { .secondaryLabelColor }
    /// Blockquote horizontal indent off the leading edge (paired with the "▎"
    /// bar glyph — see `applyBlockquoteStyle`).
    static let blockquoteIndent: CGFloat = 14
}
