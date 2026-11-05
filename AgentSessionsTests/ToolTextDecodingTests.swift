import XCTest
@testable import AgentSessions

/// Task 7: `ToolTextDecoding` (spec §6.4 steps 2–4, 6–7 and the source map).
final class ToolTextDecodingTests: XCTestCase {
    private typealias V = ToolPayloadValue

    private func textItem(_ s: String, type: String = "input_text") -> V {
        .object(["type": .string(type), "text": .string(s)])
    }

    private func decode(_ s: String) -> DecodedText {
        ToolTextDecoding.decode(value: .string(s), fallback: nil)
    }

    /// Source map contract: rendered ranges are in order and do not overlap, source locations never
    /// go backwards, every range stays inside its string, and a 1:1 entry copies equal text.
    private func assertMapValid(_ d: DecodedText, source: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = Array(d.text.utf16), s = Array(source.utf16)
        var prevRenderedEnd = 0, prevSourceLoc = 0
        for e in d.sourceMap {
            XCTAssertGreaterThanOrEqual(e.rendered.location, prevRenderedEnd, "rendered order", file: file, line: line)
            XCTAssertGreaterThanOrEqual(e.source.location, prevSourceLoc, "source monotone", file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(e.rendered), r.count, "rendered inside text", file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(e.source), s.count, "source inside source", file: file, line: line)
            if e.rendered.length == e.source.length, NSMaxRange(e.rendered) <= r.count, NSMaxRange(e.source) <= s.count {
                XCTAssertEqual(Array(r[e.rendered.location..<NSMaxRange(e.rendered)]),
                               Array(s[e.source.location..<NSMaxRange(e.source)]), "1:1 entry text", file: file, line: line)
            }
            prevRenderedEnd = NSMaxRange(e.rendered)
            prevSourceLoc = e.source.location
        }
    }

    func testContentItemsJoined() {
        let d = ToolTextDecoding.decode(value: .array([textItem("a"), textItem("b", type: "output_text")]), fallback: nil)
        XCTAssertEqual(d.text, "ab")
        XCTAssertEqual(d.shape, .plain)
    }

    func testJSONStringDecodedOnce() {
        let d = decode("\"a\\nb\"")
        XCTAssertEqual(d.text, "a\nb")
        XCTAssertEqual(d.shape, .plain)
        XCTAssertEqual(ToolTextDecoding.decodeJSONString("\"\\\"x\\\"\"", maxDepth: 3), .string("x"))
        XCTAssertNil(ToolTextDecoding.decodeJSONString("plain", maxDepth: 3))
        // Depth is capped at 3 string layers.
        let four = "\"\\\"\\\\\\\"\\\\\\\\\\\\\\\"x\\\\\\\\\\\\\\\"\\\\\\\"\\\"\""
        if case .string(let s)? = ToolTextDecoding.decodeJSONString(four, maxDepth: 3) {
            XCTAssertNotEqual(s, "x")
        }
    }

    func testWholeStringJSONPrettyPrinted() {
        let d = decode(#"{"a":1,"p":"x\/y"}"#)
        XCTAssertEqual(d.shape, .json)
        XCTAssertTrue(d.text.contains("\n"))
        XCTAssertFalse(d.text.contains("\\/"))
        XCTAssertTrue(d.text.contains("x/y"))
        assertMapValid(d, source: #"{"a":1,"p":"x\/y"}"#)
        // JSON in a string literal is decoded through the layer.
        XCTAssertEqual(decode(#""{\"a\":1}""#).shape, .json)
    }

    func testBigJSONStaysPlain() {
        let big = #"{"a":""# + String(repeating: "x", count: 300 * 1024) + #""}"#
        let d = decode(big)
        XCTAssertEqual(d.shape, .plain)
        XCTAssertEqual(d.text, big)
    }

    func testJSONInsideProseStaysText() {
        let s = #"result: {"a":1}"#
        let d = decode(s)
        XCTAssertEqual(d.text, s)
        XCTAssertEqual(d.shape, .plain)
    }

    func testJSONLinesDetected() {
        let s = "{\"a\":1,\"b\":2}\n{\"a\":3,\"b\":4}\n"
        let d = decode(s)
        XCTAssertEqual(d.shape, .jsonLines)
        XCTAssertEqual(d.text, "{\"a\":1,\"b\":2}\n{\"a\":3,\"b\":4}")
        XCTAssertEqual(decode("{\"a\":1}\n{\"b\":2}").shape, .plain, "different key sets")
        XCTAssertEqual(decode("{\"a\":1}\nnot json").shape, .plain)
    }

    func testANSIStrippedAndCRLFNormalized() {
        let s = "\u{1B}[31mred\u{1B}[0m\r\nline\ttab\r\n\u{1B}]0;title\u{07}end\r\n\r\n  \r\n"
        let d = decode(s)
        XCTAssertEqual(d.text, "red\nline\ttab\nend")
        XCTAssertEqual(ToolTextDecoding.normalize("a\r\nb\n\n\n"), "a\nb")
        XCTAssertEqual(ToolTextDecoding.normalize("keep \n"), "keep ")
        assertMapValid(d, source: s)
    }

    func testLineNumberFormsAllDetected() {
        let forms: [(String, String)] = [
            ("  1→a\n  2→b\n  3→", "arrow"),
            ("1\ta\n2\tb\n3\t", "tab"),
            ("1:a\n2:b\n3:", "colon"),
            ("1|a\n2|b\n3|", "pipe"),
            ("1 | a\n2 | b\n3 | ", "spaced pipe"),
        ]
        for (src, name) in forms {
            guard let r = ToolTextDecoding.stripLineNumbers(src) else { XCTFail("\(name) not detected"); continue }
            XCTAssertEqual(r.gutter, [1, 2, 3], name)
            XCTAssertEqual(r.text, "a\nb\n", name)
            let d = decode(src)
            XCTAssertEqual(d.shape, .lineNumbered(gutter: [1, 2, 3]), name)
            XCTAssertEqual(d.text, "a\nb\n", name)   // one text line per gutter entry
        }
        // Numbers start anywhere but must rise by exactly 1.
        XCTAssertEqual(ToolTextDecoding.stripLineNumbers("10\tx\n11\ty")?.gutter, [10, 11])
        XCTAssertNil(ToolTextDecoding.stripLineNumbers("1\tx\n3\ty"))
        XCTAssertNil(ToolTextDecoding.stripLineNumbers("1\tx"), "needs 2 numbered lines")
        XCTAssertNil(ToolTextDecoding.stripLineNumbers("1\tx\n2: y"), "mixed forms")
        XCTAssertNil(ToolTextDecoding.stripLineNumbers("1\tx\nplain"))
        XCTAssertEqual(ToolTextDecoding.stripLineNumbers("1\tx\n\n2\ty")?.gutter ?? [], [1, nil, 2])
    }

    func testSourceMapRoundTrips() {
        let sources = [
            "\u{1B}[1mhello\u{1B}[0m\r\nworld\r\n",
            "  1→alpha\n  2→beta\n  3→gamma\n",
            "{\"a\":1,\"b\":[1,2],\"c\":{\"d\":\"x\\/y\"}}",
            "{ \"a\": 1,\n \"b\": 2 }",
            "{\"b\":1,\"a\":2}",
            "plain text é 😀 end\n\n",
        ]
        for src in sources {
            let d = decode(src)
            assertMapValid(d, source: src)
            XCTAssertFalse(d.sourceMap.isEmpty, src)
        }
        // Inserted pretty-print characters map to zero-length source ranges.
        let json = decode("{\"a\":1}")
        XCTAssertTrue(json.sourceMap.contains { $0.source.length == 0 && $0.rendered.length > 0 })
        // Rendered ranges together cover every source-derived character.
        let ansi = decode("\u{1B}[1mhello\u{1B}[0m")
        XCTAssertEqual(ansi.sourceMap.map { $0.rendered.length }.reduce(0, +), 5)
    }

    func testBase64ImageItemBecomesImageShape() {
        let obj: V = .object(["type": .string("input_image"), "image_url": .string("data:image/png;base64,AAAA")])
        let d = ToolTextDecoding.decode(value: obj, fallback: nil)
        XCTAssertEqual(d.shape, .image)
        XCTAssertEqual(d.text, "[image]")
        XCTAssertFalse(d.text.contains("base64"))
        let arr = ToolTextDecoding.decode(value: .array([obj]), fallback: nil)
        XCTAssertEqual(arr.shape, .image)
        XCTAssertEqual(arr.text, "[image]")
        // Mixed text + image stays text with an [image] line.
        let mixed = ToolTextDecoding.decode(value: .array([textItem("a"), obj, textItem("b")]), fallback: nil)
        XCTAssertEqual(mixed.shape, .plain)
        XCTAssertEqual(mixed.text, "a\n[image]\nb")
    }

    func testBinaryTextObjectBecomesPlaceholder() {
        let data = String(repeating: "A", count: 16384)   // 16384 base64 chars = 12288 bytes
        let obj: V = .object(["encoding": .string("base64"), "data": .string(data)])
        let d = ToolTextDecoding.decode(value: obj, fallback: nil)
        XCTAssertEqual(d.shape, .binary(bytes: 12288))
        XCTAssertEqual(d.text, "binary data (12 KB)")
    }

    func testFallbackUsedWhenNoValueAndStructuredObjectPretty() {
        XCTAssertEqual(ToolTextDecoding.decode(value: nil, fallback: "hi\r\n").text, "hi")
        XCTAssertEqual(ToolTextDecoding.decode(value: nil, fallback: nil).text, "")
        let d = ToolTextDecoding.decode(value: .object(["k": .string("a/b")]), fallback: nil)
        XCTAssertEqual(d.shape, .json)
        XCTAssertTrue(d.text.contains("a/b"))
    }

    func testMarkdownShapeIsConservative() {
        XCTAssertEqual(decode("# Title\n\n- one\n- two").shape, .markdown)
        XCTAssertEqual(decode("# comment\nls output").shape, .plain)
    }
}
