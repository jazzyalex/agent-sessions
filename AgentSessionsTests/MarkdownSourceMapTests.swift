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
}
