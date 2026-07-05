import XCTest
@testable import AgentSessions

final class MarkdownSourceMapTests: XCTestCase {
    private func body(_ md: String) -> RenderedBody {
        MarkdownBodyRenderer.render(md, baseFont: .monospacedSystemFont(ofSize: 13, weight: .regular), isDark: true)
    }

    // Every source offset NOT inside consumed syntax must map to a rendered
    // offset whose character equals the source character.
    func testSourceMapRoundTripPlainText() {
        let src = "hello world"
        let b = body(src)
        let srcNS = src as NSString
        let renderedNS = b.attributed.string as NSString
        for i in 0..<srcNS.length {
            guard let r = b.renderedRange(forSourceRange: NSRange(location: i, length: 1)) else { continue }
            XCTAssertEqual(renderedNS.substring(with: r), srcNS.substring(with: NSRange(location: i, length: 1)))
        }
    }

    func testBoldConsumedSyntaxMapsInnerText() {
        let src = "a **bold** b"          // '**' consumed; 'bold' preserved
        let b = body(src)
        let renderedNS = b.attributed.string as NSString
        // source offset of 'b' in 'bold' is 4
        let r = b.renderedRange(forSourceRange: NSRange(location: 4, length: 4)) // "bold"
        XCTAssertNotNil(r)
        XCTAssertEqual(renderedNS.substring(with: r!), "bold")
    }

    func testRangeSpanningConsumedSyntaxReturnsNil() {
        let src = "a **bold** b"
        let b = body(src)
        // a source range starting at the '*' (offset 2) crosses a consumed boundary
        XCTAssertNil(b.renderedRange(forSourceRange: NSRange(location: 2, length: 4)))
    }

    func testRenderedPlainTextDropsSyntax() {
        XCTAssertEqual(body("**hi**").attributed.string, "hi")
        XCTAssertEqual(body("a `code` b").attributed.string, "a code b")
    }

    // Extra coverage: round-trip must also hold across bold / inline-code / header
    // (the inner preserved text must map back to itself, per-character).
    func testSourceMapRoundTripAcrossInlineAndHeader() {
        for src in ["a **bold** b", "call `foo()` now", "# Title here", "plain _em_ tail"] {
            let b = body(src)
            let srcNS = src as NSString
            let renderedNS = b.attributed.string as NSString
            for i in 0..<srcNS.length {
                guard let r = b.renderedRange(forSourceRange: NSRange(location: i, length: 1)) else { continue }
                XCTAssertLessThanOrEqual(NSMaxRange(r), renderedNS.length, "range out of bounds for \(src) @\(i)")
                XCTAssertEqual(renderedNS.substring(with: r),
                               srcNS.substring(with: NSRange(location: i, length: 1)),
                               "char mismatch for \(src) @\(i)")
            }
        }
    }

    // A source range with zero coverage (fully inside consumed syntax) must be nil.
    func testFullyConsumedSyntaxReturnsNil() {
        let src = "a **bold** b"
        let b = body(src)
        // offsets 2..3 are the leading '**' — entirely consumed
        XCTAssertNil(b.renderedRange(forSourceRange: NSRange(location: 2, length: 2)))
    }

    // MARK: Task 13 — fence content stays mappable (⌘F works inside a code card)

    func testFenceContentIsFindableViaSourceMap() {
        let src = "text before\n```\nneedle here\n```"
        let b = body(src)
        let srcNS = src as NSString
        let needleSrc = srcNS.range(of: "needle")
        let r = b.renderedRange(forSourceRange: needleSrc)
        XCTAssertNotNil(r, "fence inner text must be mappable (identity segment)")
        XCTAssertEqual((b.attributed.string as NSString).substring(with: r!), "needle")
    }

    func testFenceContentRoundTripsPerCharacterDespiteTrailingNewlineTrim() {
        // The renderer trims exactly one trailing `\n` off `CodeBlock.code`
        // before mapping it; every character of the code BODY itself (not the
        // trimmed newline) must still round-trip per-character like plain text.
        let src = "```\nlet x = 1\n```"
        let b = body(src)
        let srcNS = src as NSString
        let renderedNS = b.attributed.string as NSString
        let codeSrcRange = srcNS.range(of: "let x = 1")
        for offset in 0..<codeSrcRange.length {
            let srcRange = NSRange(location: codeSrcRange.location + offset, length: 1)
            guard let r = b.renderedRange(forSourceRange: srcRange) else {
                return XCTFail("fence body character @\(offset) must stay mappable")
            }
            XCTAssertEqual(renderedNS.substring(with: r), srcNS.substring(with: srcRange))
        }
    }

    // Regression: swift-markdown enables cmark smart punctuation by default,
    // which would rewrite the apostrophe in "don't" to a curly ’ inside
    // Text.string — breaking the forward-scan so prose with quotes/apostrophes/
    // dashes gets NO source-map segment and find silently degrades to the pill.
    // `.disableSmartOpts` keeps rendered chars byte-faithful; this asserts the
    // apostrophe run round-trips and the punctuation is preserved verbatim.
    func testSmartPunctuationDisabledSoProseMapsAndStaysLiteral() {
        let src = "don't -- \"quote\""
        let b = body(src)
        // Rendered text preserves the straight apostrophe, double-hyphen, and
        // straight quotes (no ’ – “ ” substitution).
        XCTAssertEqual(b.attributed.string, src)
        // The whole run maps back per character (no missing segment on prose).
        let srcNS = src as NSString
        let renderedNS = b.attributed.string as NSString
        for i in 0..<srcNS.length {
            guard let r = b.renderedRange(forSourceRange: NSRange(location: i, length: 1)) else {
                return XCTFail("apostrophe/quote/dash prose must stay mappable @\(i)")
            }
            XCTAssertEqual(renderedNS.substring(with: r), srcNS.substring(with: NSRange(location: i, length: 1)))
        }
    }

    // MARK: Task 14 — list marker glyphs are rendered-only gaps; item text stays mapped

    // The marker ("•\t" / "N.\t") is a RENDERED-ONLY glyph with no source
    // segment — like a fence's trimmed trailing newline or consumed "**"
    // syntax, it must never shift the mapping of the item text that follows
    // it. Every character of each item's own TEXT (not the "- "/"1. " source
    // syntax, which IS consumed) must round-trip per-character.
    func testBulletListItemTextRoundTripsPerCharacter() {
        let src = "- first item\n- second item"
        let b = body(src)
        let srcNS = src as NSString
        let renderedNS = b.attributed.string as NSString
        for word in ["first item", "second item"] {
            let wordSrc = srcNS.range(of: word)
            for offset in 0..<wordSrc.length {
                let srcRange = NSRange(location: wordSrc.location + offset, length: 1)
                guard let r = b.renderedRange(forSourceRange: srcRange) else {
                    return XCTFail("list item character @\(offset) of \(word.debugDescription) must stay mappable")
                }
                XCTAssertEqual(renderedNS.substring(with: r), srcNS.substring(with: srcRange))
            }
        }
    }

    func testOrderedListItemTextRoundTripsPerCharacter() {
        let src = "1. one\n2. two"
        let b = body(src)
        let srcNS = src as NSString
        let renderedNS = b.attributed.string as NSString
        for word in ["one", "two"] {
            let wordSrc = srcNS.range(of: word)
            for offset in 0..<wordSrc.length {
                let srcRange = NSRange(location: wordSrc.location + offset, length: 1)
                guard let r = b.renderedRange(forSourceRange: srcRange) else {
                    return XCTFail("ordered list item character @\(offset) of \(word.debugDescription) must stay mappable")
                }
                XCTAssertEqual(renderedNS.substring(with: r), srcNS.substring(with: srcRange))
            }
        }
    }

    func testNestedListItemTextStaysMappableAndMonotonic() {
        // "- a\n  - b": the nested item's marker is a SECOND rendered-only gap
        // stacked after the outer item's. The scan cursor must stay monotonic
        // across both, so "b" (which appears later in BOTH source and
        // rendered order) still maps correctly and "a" still maps to its own,
        // earlier, distinct location.
        let src = "- a\n  - b"
        let b = body(src)
        let srcNS = src as NSString
        let renderedNS = b.attributed.string as NSString
        let aSrc = srcNS.range(of: "a")
        let bSrc = srcNS.range(of: "b")
        guard let aR = b.renderedRange(forSourceRange: aSrc) else {
            return XCTFail("outer list item 'a' must stay mappable")
        }
        guard let bR = b.renderedRange(forSourceRange: bSrc) else {
            return XCTFail("nested list item 'b' must stay mappable")
        }
        XCTAssertEqual(renderedNS.substring(with: aR), "a")
        XCTAssertEqual(renderedNS.substring(with: bR), "b")
        XCTAssertLessThan(aR.location, bR.location, "outer item must map before the nested item it contains")
    }
}
