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

    func testInlineCodeIsMonospacedWithNoBackgroundChip() {
        let b = MarkdownBodyRenderer.render("call `foo()` now", baseFont: font, isDark: true)
        XCTAssertEqual(b.attributed.string, "call foo() now")
        let codeLoc = (b.attributed.string as NSString).range(of: "foo()").location
        // Inline code is marked by the monospaced font, NOT a background chip
        // (backgrounds on arbitrary backticked spans read as random gray boxes).
        let f = b.attributed.attribute(.font, at: codeLoc, effectiveRange: nil) as? NSFont
        XCTAssertTrue(f?.isFixedPitch ?? false, "inline code must stay monospaced")
        let bg = b.attributed.attribute(.backgroundColor, at: codeLoc, effectiveRange: nil)
        XCTAssertNil(bg, "inline code must NOT carry a background chip")
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

    // MARK: Element restyle — code block, table header, heading ramp, inline
    // code, blockquote (own palette, not a copy of any reference app's colors)

    func testCodeFenceCardUsesSubtleInsetWithAdaptiveText() {
        // Restyle (#2): the code card is a SUBTLE inset — light-gray in light
        // mode, a gently-recessed tone in dark mode — with the standard adaptive
        // label color, NOT the old near-black slab with fixed off-white text.
        // The fill and text are dynamic colors, so resolve each against a
        // specific appearance rather than reading them context-free.
        let src = "```\nlet x = 1\n```"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let loc = (b.attributed.string as NSString).range(of: "let x").location
        let bg = b.attributed.attribute(.backgroundColor, at: loc, effectiveRange: nil) as? NSColor
        let fg = b.attributed.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(bg)
        XCTAssertNotNil(fg)

        func brightness(_ color: NSColor, in appearanceName: NSAppearance.Name) -> CGFloat {
            var out: CGFloat = -1
            NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
                out = color.usingColorSpace(.deviceRGB)!.brightnessComponent
            }
            return out
        }

        // Fill: light inset in light mode (NOT a dark slab); recessed-but-not-black
        // in dark mode (NOT a bright panel).
        XCTAssertGreaterThan(brightness(bg!, in: .aqua), 0.85,
                             "light-mode code fill should be a light inset, not a dark slab")
        let darkFill = brightness(bg!, in: .darkAqua)
        XCTAssertGreaterThan(darkFill, 0.12, "dark-mode code fill should be recessed, not pure black")
        XCTAssertLessThan(darkFill, 0.40, "dark-mode code fill should stay a subtle inset, not a bright panel")

        // Text adapts (standard label): dark in light mode, light in dark mode —
        // not a fixed off-white independent of appearance.
        XCTAssertLessThan(brightness(fg!, in: .aqua), 0.4, "code text should be dark in light mode")
        XCTAssertGreaterThan(brightness(fg!, in: .darkAqua), 0.6, "code text should be light in dark mode")
    }

    func testTableHeaderCellHasDistinctBackground() {
        // The owner specifically called out that tables lacked a visibly
        // distinct header row; the restyle gives header (row 0) cells a fill
        // that body-row cells do NOT carry.
        let md = "| Name | Age |\n|---|---|\n| x | 1 |"
        let b = MarkdownBodyRenderer.render(md, baseFont: font, isDark: true)
        let s = b.attributed.string as NSString
        let headerLoc = s.range(of: "Name").location
        let bodyLoc = s.range(of: "x").location
        let headerStyle = b.attributed.attribute(.paragraphStyle, at: headerLoc, effectiveRange: nil) as? NSParagraphStyle
        let bodyStyle = b.attributed.attribute(.paragraphStyle, at: bodyLoc, effectiveRange: nil) as? NSParagraphStyle
        let headerBlock = headerStyle?.textBlocks.first as? NSTextTableBlock
        let bodyBlock = bodyStyle?.textBlocks.first as? NSTextTableBlock
        XCTAssertNotNil(headerBlock?.backgroundColor, "header cell must carry a background fill")
        XCTAssertNil(bodyBlock?.backgroundColor, "body cell must NOT carry the header fill")
    }

    func testHeadingSizeRampDescendsFromH1ToH3() {
        // AgentsView-inspired gentle em ramp: H1 > H2 > H3 > body, tapering off
        // rather than a flat per-level bump that once pushed H1 to 25pt.
        let h1 = MarkdownBodyRenderer.render("# one", baseFont: font, isDark: true)
        let h2 = MarkdownBodyRenderer.render("## two", baseFont: font, isDark: true)
        let h3 = MarkdownBodyRenderer.render("### three", baseFont: font, isDark: true)
        let body = MarkdownBodyRenderer.render("plain", baseFont: font, isDark: true)
        let f1 = (h1.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        let f2 = (h2.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        let f3 = (h3.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        let fBody = (body.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
        XCTAssertNotNil(f1); XCTAssertNotNil(f2); XCTAssertNotNil(f3); XCTAssertNotNil(fBody)
        XCTAssertGreaterThan(f1!, f2!, "H1 must be larger than H2")
        XCTAssertGreaterThan(f2!, f3!, "H2 must be larger than H3")
        XCTAssertGreaterThan(f3!, fBody!, "H3 must still be larger than body prose")
    }

    func testInlineCodeFontIsSmallerThanBody() {
        // Restyle: inline code is sized down a notch off baseFont for a
        // tighter, chip-like scale rather than same-size monospace.
        let b = MarkdownBodyRenderer.render("call `foo()` now", baseFont: font, isDark: true)
        let codeLoc = (b.attributed.string as NSString).range(of: "foo()").location
        let codeFont = b.attributed.attribute(.font, at: codeLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(codeFont)
        XCTAssertLessThan(codeFont!.pointSize, font.pointSize, "inline code font should be smaller than the base/body font")
    }

    func testBlockquoteTextCarriesSecondaryColorAndIndent() {
        // Blockquotes previously fell through the generic unmodeled-block path
        // with NO styling. The restyle gives them a secondary text color and an
        // indent (approximating a left border, which NSAttributedString can't
        // draw natively).
        let src = "> quoted line"
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        let s = b.attributed.string as NSString
        let loc = s.range(of: "quoted line").location
        XCTAssertNotEqual(loc, NSNotFound)
        let fg = b.attributed.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
        XCTAssertEqual(fg, NSColor.secondaryLabelColor, "blockquote text should use the secondary label color")
        let style = b.attributed.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0, "blockquote should be indented off the leading edge")
    }

    func testFindHighlightOnInlineCodeClearsToNoBackground() {
        // Inline code has no background chip, so a find match paints a highlight
        // and clearing it must return the run to NO background (nothing to
        // restore), not leave a stray fill behind.
        let b = MarkdownBodyRenderer.render("call `foo()` now", baseFont: font, isDark: true)
        let textView = SelectableBlockTextView()
        textView.textStorage?.setAttributedString(b.attributed)
        let s = b.attributed.string as NSString
        let matchRange = s.range(of: "foo")
        XCTAssertNil(textView.textStorage?.attribute(.backgroundColor, at: matchRange.location, effectiveRange: nil),
                     "inline code starts with no background")
        textView.applyFindHighlights(all: [matchRange], current: matchRange)
        XCTAssertNotNil(textView.textStorage?.attribute(.backgroundColor, at: matchRange.location, effectiveRange: nil),
                        "find highlight paints a background")
        textView.clearFindHighlights()
        XCTAssertNil(textView.textStorage?.attribute(.backgroundColor, at: matchRange.location, effectiveRange: nil),
                     "clearing find leaves inline code with no background")
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
