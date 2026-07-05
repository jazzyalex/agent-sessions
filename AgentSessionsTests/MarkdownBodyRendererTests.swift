import XCTest
import AppKit
@testable import AgentSessions

final class MarkdownBodyRendererTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func testEmphasisAttributeApplied() {
        let b = MarkdownBodyRenderer.render("*italic*", baseFont: font, isDark: true)
        XCTAssertEqual(b.attributed.string, "italic")
        var found = false
        b.attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: b.attributed.length)) { v, _, _ in
            if let f = v as? NSFont, f.fontDescriptor.symbolicTraits.contains(.italic) { found = true }
        }
        XCTAssertTrue(found)
    }

    func testHeaderIsLargerThanBody() {
        let b = MarkdownBodyRenderer.render("# Title", baseFont: font, isDark: true)
        let f = b.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(f)
        XCTAssertGreaterThan(f!.pointSize, font.pointSize)
        XCTAssertEqual(b.attributed.string, "Title")
    }

    func testParagraphsSeparatedByNewline() {
        let b = MarkdownBodyRenderer.render("one\n\ntwo", baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("one"))
        XCTAssertTrue(b.attributed.string.contains("two"))
    }

    func testInlineCodeMonospacedChip() {
        let b = MarkdownBodyRenderer.render("call `foo()` now", baseFont: font, isDark: true)
        XCTAssertEqual(b.attributed.string, "call foo() now")
        // the code run carries a background color chip attribute
        let codeLoc = (b.attributed.string as NSString).range(of: "foo()").location
        let bg = b.attributed.attribute(.backgroundColor, at: codeLoc, effectiveRange: nil)
        XCTAssertNotNil(bg)
    }

    func testStrongAttributeApplied() {
        let b = MarkdownBodyRenderer.render("**bold**", baseFont: font, isDark: true)
        XCTAssertEqual(b.attributed.string, "bold")
        let f = b.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testProseUsesProportionalFontNotMonospace() {
        // Prose (paragraph text) should render in the proportional system font,
        // NOT the monospaced baseFont — that identity is reserved for code.
        let b = MarkdownBodyRenderer.render("plain prose", baseFont: font, isDark: true)
        let f = b.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(f)
        // The monospaced system font is fixed-pitch; the proportional one is not.
        XCTAssertFalse(f!.isFixedPitch, "prose should not be fixed-pitch monospace")
    }

    func testInlineCodeUsesMonospacedFont() {
        let b = MarkdownBodyRenderer.render("call `foo()` now", baseFont: font, isDark: true)
        let codeLoc = (b.attributed.string as NSString).range(of: "foo()").location
        let f = b.attributed.attribute(.font, at: codeLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.isFixedPitch, "inline code should keep the monospaced identity")
    }

    func testEmptyStringRendersEmpty() {
        let b = MarkdownBodyRenderer.render("", baseFont: font, isDark: true)
        XCTAssertEqual(b.attributed.string, "")
        XCTAssertEqual(b.renderedLength, 0)
        XCTAssertTrue(b.unmappableSourceRanges.isEmpty)
    }

    // MARK: Unmodeled blocks must NEVER render blank (data-loss regression guard)

    func testCodeFenceBlockRendersItsCode() {
        // A fenced code block is the most common assistant payload. The code
        // MUST render + be present (not blank), regardless of T13's card chrome.
        let src = "Here's the fix:\n\n```swift\nlet x = 1\n```\n\nDone."
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("let x = 1"),
                      "code fence body must render, got: \(b.attributed.string.debugDescription)")
        XCTAssertTrue(b.attributed.string.contains("Done."))
        XCTAssertTrue(b.attributed.string.contains("Here's the fix:"))
    }

    // MARK: Task 13 — fenced code block dark inset card

    func testCodeFenceCardHasBackgroundAndMonospacedFont() {
        let src = "```\nlet x = 1\n```"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let loc = (b.attributed.string as NSString).range(of: "let x").location
        let bg = b.attributed.attribute(.backgroundColor, at: loc, effectiveRange: nil)
        XCTAssertNotNil(bg, "fence content must carry the code-card background")
        let f = b.attributed.attribute(.font, at: loc, effectiveRange: nil) as? NSFont
        XCTAssertTrue(f?.isFixedPitch ?? false, "fence content must stay monospaced")
    }

    func testCodeFenceCardHasParagraphIndent() {
        let src = "```\nlet x = 1\n```"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let loc = (b.attributed.string as NSString).range(of: "let x").location
        let style = b.attributed.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(style, "fence content must carry a paragraph style for the card indent")
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0, "card should be indented off the leading edge")
        XCTAssertGreaterThan(style?.firstLineHeadIndent ?? 0, 0)
    }

    func testCodeFenceCardCarriesFindRestoreMarker() {
        // The card background shares `.backgroundColor` with find-highlight
        // paint; `.markdownCodeBlockBg` lets `clearFindHighlights` restore the
        // card fill instead of stripping it (parallel to `.markdownCodeChip`).
        let src = "```\nlet x = 1\n```"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let loc = (b.attributed.string as NSString).range(of: "let x").location
        let marker = b.attributed.attribute(.markdownCodeBlockBg, at: loc, effectiveRange: nil)
        XCTAssertNotNil(marker, "fence content must carry the code-block-bg find-restore marker")
    }

    func testCodeFenceTrimsExactlyOneTrailingNewline() {
        // cmark's CodeBlock.code literal always ends in exactly one trailing
        // `\n` (confirmed against the checked-out swift-markdown package).
        // Left untrimmed it renders as a blank line inside the card before the
        // next block; a single-line fence followed by prose must NOT show a
        // blank line between the code and the following text.
        let src = "```\nlet x = 1\n```\n\nDone."
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        XCTAssertFalse(b.attributed.string.contains("let x = 1\n\n\nDone."),
                       "must not leave the fence's own trailing newline as an extra blank line")
        XCTAssertTrue(b.attributed.string.contains("let x = 1\n\nDone."),
                     "exactly one block-separator blank line between fence and next paragraph, got: \(b.attributed.string.debugDescription)")
    }

    func testCodeFenceMultiLineDoesNotAddInternalParagraphSpacing() {
        // Regression: applying ONE uniform NSParagraphStyle (with both
        // paragraphSpacingBefore and paragraphSpacing set) over a multi-line
        // fence body would insert that spacing at EVERY internal line break,
        // not just the card's top/bottom edge. Internal lines must carry a
        // style with zero spacing-before/after; only the first/last line may
        // carry non-zero edge spacing.
        let src = "```\nline1\nline2\nline3\n```"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let s = b.attributed.string as NSString
        let midLoc = s.range(of: "line2").location
        let style = b.attributed.attribute(.paragraphStyle, at: midLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacingBefore ?? -1, 0, "interior fence line must not carry top edge spacing")
        XCTAssertEqual(style?.paragraphSpacing ?? -1, 0, "interior fence line must not carry bottom edge spacing")
    }

    func testBulletListRendersItemText() {
        // Task 14 adds marker+indent styling, but the item text itself must
        // still render regardless (the T12 data-loss guarantee still holds).
        let src = "- first item\n- second item"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("first item"),
                      "list item text must render, got: \(b.attributed.string.debugDescription)")
        XCTAssertTrue(b.attributed.string.contains("second item"))
    }

    func testOrderedListRendersItemText() {
        let src = "1. alpha\n2. beta"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("alpha"))
        XCTAssertTrue(b.attributed.string.contains("beta"))
    }

    // MARK: Task 14 — bullet + numbered list markers, indent, nesting

    func testBulletListMarkersAndText() {
        let src = "- first\n- second"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let s = b.attributed.string
        XCTAssertTrue(s.contains("first"))
        XCTAssertTrue(s.contains("second"))
        XCTAssertTrue(s.contains("•"), "unordered list must render a bullet marker glyph")
    }

    func testListItemTextIsFindable() {
        // The marker glyph is rendered-only (no source segment); a find match
        // on the item's SOURCE text must still resolve to the correct
        // rendered range past the marker — proves the marker's rendered-side
        // gap doesn't shift the source map.
        let md = "- alpha\n- beta"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        let betaSrc = (md as NSString).range(of: "beta")
        let r = b.renderedRange(forSourceRange: betaSrc)
        XCTAssertNotNil(r)
        XCTAssertEqual((b.attributed.string as NSString).substring(with: r!), "beta")
    }

    func testOrderedListNumbers() {
        let src = "1. one\n2. two"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("1."))
        XCTAssertTrue(b.attributed.string.contains("2."))
    }

    func testOrderedListRespectsCustomStartIndex() {
        // CommonMark lets an ordered list start at any number; markers must
        // continue from `startIndex`, not restart at 1.
        let src = "3. one\n4. two"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("3."))
        XCTAssertTrue(b.attributed.string.contains("4."))
        XCTAssertFalse(b.attributed.string.contains("1."), "must not renumber from 1 when the source starts at 3")
    }

    func testNestedListBothLevelsRenderAndIndentDeeper() {
        // "- a\n  - b": swift-markdown nests the sub-list as a sibling block
        // of the outer item's Paragraph (confirmed against the checked-out
        // package), not a grandchild of the Text leaf. Both "a" and "b" must
        // render, and "b" (depth 1) must carry a strictly deeper headIndent
        // than "a" (depth 0).
        let src = "- a\n  - b"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let s = b.attributed.string as NSString
        XCTAssertTrue(b.attributed.string.contains("a"))
        XCTAssertTrue(b.attributed.string.contains("b"))
        let aLoc = s.range(of: "a").location
        let bLoc = s.range(of: "b").location
        let aStyle = b.attributed.attribute(.paragraphStyle, at: aLoc, effectiveRange: nil) as? NSParagraphStyle
        let bStyle = b.attributed.attribute(.paragraphStyle, at: bLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(aStyle)
        XCTAssertNotNil(bStyle)
        XCTAssertGreaterThan(bStyle!.headIndent, aStyle!.headIndent,
                              "nested item must indent deeper than its parent")
    }

    func testListItemTextCarriesIndentParagraphStyle() {
        let src = "- item one"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let loc = (b.attributed.string as NSString).range(of: "item one").location
        let style = b.attributed.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(style, "list item text must carry a paragraph style for the marker indent")
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0, "list item should be indented off the leading edge")
    }

    func testBlockQuoteRendersText() {
        let src = "> quoted line"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("quoted line"),
                      "block quote text must render, got: \(b.attributed.string.debugDescription)")
    }

    func testEscapedAsteriskRendersLiteralNoCrashNoDrop() {
        // cmark decodes `\*` → `*`, so `Text.string` ("a * b") won't match the
        // source bytes ("a \* b") on the forward scan. The run must STILL render
        // (segment may be absent — that's fine; find degrades to pill).
        let b = MarkdownBodyRenderer.render("a \\* b", baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("a * b"),
                      "escaped asterisk must render as literal '*', got: \(b.attributed.string.debugDescription)")
    }

    // MARK: Task 13 — find-clear restores the code-block card background

    func testClearFindHighlightsRestoresCodeBlockCardBackground() {
        // The card's `.backgroundColor` and a find highlight's `.backgroundColor`
        // share the same attribute key. `applyFindHighlights` starts every call
        // with `clearFindHighlights()`, and a plain find-clear (e.g. closing the
        // find bar) must leave the card fill intact rather than stripping it to
        // nothing — parallel to the Task 12 inline-code-chip guarantee.
        let src = "```\nlet x = 1\n```"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let textView = SelectableBlockTextView()
        textView.textStorage?.setAttributedString(b.attributed)

        let s = b.attributed.string as NSString
        // Read the background AT THE MATCHED characters (where find paints), not
        // at the start of the fence — the highlight only covers the match range.
        let matchRange = s.range(of: "x")
        let matchLoc = matchRange.location
        let originalBG = textView.textStorage?.attribute(.backgroundColor, at: matchLoc, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(originalBG, "precondition: fence content must start with the card background")

        // Simulate a find pass highlighting the "x" then clearing it.
        textView.applyFindHighlights(all: [matchRange], current: matchRange)
        let duringFindBG = textView.textStorage?.attribute(.backgroundColor, at: matchLoc, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(duringFindBG, originalBG, "find highlight should visually override the card fill while active")

        textView.clearFindHighlights()
        let restoredBG = textView.textStorage?.attribute(.backgroundColor, at: matchLoc, effectiveRange: nil) as? NSColor
        XCTAssertEqual(restoredBG, originalBG, "clearing find must restore the code-block card background, not strip it")
    }

    // MARK: Task 15 — GFM tables (NSTextTable), cells unmappable → pill

    func testTableCellsRenderedAndUnmappable() {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        let s = b.attributed.string
        // All four cell texts must render (present + copyable).
        XCTAssertTrue(s.contains("a"), "header cell 'a' must render, got: \(s.debugDescription)")
        XCTAssertTrue(s.contains("b"), "header cell 'b' must render")
        XCTAssertTrue(s.contains("1"), "body cell '1' must render")
        XCTAssertTrue(s.contains("2"), "body cell '2' must render")
        // A find match inside a table cell is unmappable → renderedRange nil
        // (the header pill/count is the fallback, no in-cell paint).
        let cellSrc = (md as NSString).range(of: "1")
        XCTAssertNil(b.renderedRange(forSourceRange: cellSrc),
                     "a match inside a table cell must be unmappable (nil → pill)")
        XCTAssertFalse(b.unmappableSourceRanges.isEmpty,
                       "table cells must register at least one unmappable source range")
    }

    func testTableEveryCellMatchIsUnmappable() {
        // Not just the "1" cell — every cell's source text must fall inside the
        // unmappable table span so no table match ever tries to paint.
        let md = "| a | b |\n|---|---|\n| 1 | 2 |"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        for needle in ["a", "b", "1", "2"] {
            let r = (md as NSString).range(of: needle)
            XCTAssertNil(b.renderedRange(forSourceRange: r),
                         "cell '\(needle)' match must be unmappable (nil → pill)")
        }
    }

    func testTableHeaderCellsAreBold() {
        let md = "| Name | Age |\n|---|---|\n| x | 1 |"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        let s = b.attributed.string as NSString
        let headerLoc = s.range(of: "Name").location
        XCTAssertNotEqual(headerLoc, NSNotFound, "header text must be present")
        let f = b.attributed.attribute(.font, at: headerLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.fontDescriptor.symbolicTraits.contains(.bold),
                      "table header cell text must be bold")
    }

    func testTableCellsCarryTextTableParagraphStyle() {
        // Each cell paragraph must carry an NSTextBlock (the NSTextTable cell) —
        // this is what gives the table its real grid layout + borders and what
        // makes the layout-manager measurement account for the full table height.
        let md = "| a | b |\n|---|---|\n| 1 | 2 |"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        let loc = (b.attributed.string as NSString).range(of: "1").location
        let style = b.attributed.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(style, "table cell must carry a paragraph style")
        XCTAssertFalse(style?.textBlocks.isEmpty ?? true,
                       "table cell paragraph must carry an NSTextTableBlock")
        XCTAssertTrue(style?.textBlocks.first is NSTextTableBlock,
                      "cell's text block must be an NSTextTableBlock")
    }

    func testTableColumnAlignmentRightApplied() {
        // GFM `|---:|` = right alignment; the cell paragraph style must reflect it.
        let md = "| L | R |\n|:---|---:|\n| a | b |"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        let s = b.attributed.string as NSString
        let rLoc = s.range(of: "b").location // right-aligned column cell
        let style = b.attributed.attribute(.paragraphStyle, at: rLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .right, "right-aligned GFM column must produce .right alignment")
    }

    func testTableMeasuresTallerThanSingleLine() {
        // The acceptance gate: a multi-row table must MEASURE (via the same
        // NSLayoutManager `usedRect` path the controller uses for markdown rows)
        // taller than a single line of prose — otherwise the row clips (the
        // Phase-1 ShowAll bug class). This measures the rendered attributed
        // string exactly as `TranscriptBlockListView.measuredHeight(of:width:)`.
        let md = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        let single = MarkdownBodyRenderer.render("one line", baseFont: font, isDark: true)
        let width: CGFloat = 600
        let tableH = Self.measuredHeight(of: b.attributed, width: width)
        let singleH = Self.measuredHeight(of: single.attributed, width: width)
        XCTAssertGreaterThan(tableH, singleH * 2,
                             "a 3-row table must measure well beyond a single line (no clip); table=\(tableH) single=\(singleH)")
    }

    func testTableDoesNotBreakPrecedingAndFollowingProse() {
        // A table between two paragraphs must not swallow or corrupt the
        // surrounding prose — both must still render and remain findable.
        let md = "intro para\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\noutro para"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("intro para"))
        XCTAssertTrue(b.attributed.string.contains("outro para"))
        // Prose outside the table stays mappable (find still paints there).
        let outroSrc = (md as NSString).range(of: "outro para")
        XCTAssertNotNil(b.renderedRange(forSourceRange: outroSrc),
                        "prose after a table must remain find-mappable")
    }

    /// Mirror of `TranscriptBlockListView.measuredHeight(of:width:)` — the
    /// controller's markdown-row measurement path (throwaway NSLayoutManager +
    /// `usedRect`, `lineFragmentPadding = 0`). Kept local so the table
    /// measurement assertion exercises the SAME geometry the row height uses,
    /// without reaching into the (private) view method.
    private static func measuredHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}
