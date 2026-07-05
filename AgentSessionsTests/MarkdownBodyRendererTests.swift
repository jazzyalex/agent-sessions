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
        // A fenced code block is the most common assistant payload. T12 doesn't
        // style the fence, but the code MUST render + be present (not blank).
        let src = "Here's the fix:\n\n```swift\nlet x = 1\n```\n\nDone."
        let b = MarkdownBodyRenderer.render(src, baseFont: font, isDark: true)
        XCTAssertTrue(b.attributed.string.contains("let x = 1"),
                      "code fence body must render, got: \(b.attributed.string.debugDescription)")
        XCTAssertTrue(b.attributed.string.contains("Done."))
        XCTAssertTrue(b.attributed.string.contains("Here's the fix:"))
    }

    func testBulletListRendersItemText() {
        // Unordered list is unstyled in T12 but its item text must not vanish.
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
}
