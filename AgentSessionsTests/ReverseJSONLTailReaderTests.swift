import XCTest
@testable import AgentSessions

final class ReverseJSONLTailReaderTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReverseJSONLTailReaderTests-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        tempURL = nil
        super.tearDown()
    }

    private func write(_ content: String) {
        try? content.data(using: .utf8)?.write(to: tempURL)
    }

    // MARK: - Last-N-lines of a synthetic file

    func testReturnsLastNLinesInOrder() {
        let lines = (0..<50).map { #"{"n":\#($0)}"# }
        write(lines.joined(separator: "\n") + "\n")

        let result = ReverseJSONLTailReader.readLastLines(url: tempURL, maxBytes: 1_000_000, maxLines: 10)

        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result, Array(lines.suffix(10)))
    }

    // MARK: - File smaller than maxBytes returns everything

    func testFileSmallerThanMaxBytesReturnsAllLines() {
        let lines = (0..<5).map { #"{"n":\#($0)}"# }
        write(lines.joined(separator: "\n") + "\n")

        let result = ReverseJSONLTailReader.readLastLines(url: tempURL, maxBytes: 1_000_000, maxLines: 400)

        XCTAssertEqual(result, lines)
    }

    // MARK: - Partial first line dropped when offset > 0

    func testPartialLeadingLineDroppedWhenChunkStartsMidFile() {
        // Construct lines where the last two lines are short enough that a
        // small maxBytes window starts reading partway through the middle line.
        let lines = [
            #"{"n":0,"pad":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
            #"{"n":1}"#,
            #"{"n":2}"#
        ]
        write(lines.joined(separator: "\n") + "\n")

        // maxBytes small enough to land inside line 0's padding, well past its start.
        let result = ReverseJSONLTailReader.readLastLines(url: tempURL, maxBytes: 20, maxLines: 400)

        // The partial fragment of line 0 must never appear; only complete trailing lines.
        XCTAssertEqual(result, [#"{"n":1}"#, #"{"n":2}"#])
        XCTAssertFalse(result.contains { $0.contains("aaaa") })
    }

    func testNoNewlineInWindowReturnsEmpty() {
        // A single line longer than maxBytes with no newline inside the window at all.
        let huge = "{" + String(repeating: "x", count: 5000) + "}"
        write(huge)

        let result = ReverseJSONLTailReader.readLastLines(url: tempURL, maxBytes: 100, maxLines: 400)

        XCTAssertEqual(result, [])
    }

    // MARK: - Empty / missing file

    func testEmptyFileReturnsEmpty() {
        write("")
        let result = ReverseJSONLTailReader.readLastLines(url: tempURL, maxBytes: 1_000_000, maxLines: 400)
        XCTAssertEqual(result, [])
    }

    func testMissingFileReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReverseJSONLTailReaderTests-does-not-exist-\(UUID().uuidString).jsonl")
        let result = ReverseJSONLTailReader.readLastLines(url: missing, maxBytes: 1_000_000, maxLines: 400)
        XCTAssertEqual(result, [])
    }

    // MARK: - maxLines cap

    func testCapsAtMaxLinesEvenWhenMoreLinesFitInWindow() {
        let lines = (0..<30).map { #"{"n":\#($0)}"# }
        write(lines.joined(separator: "\n") + "\n")

        let result = ReverseJSONLTailReader.readLastLines(url: tempURL, maxBytes: 1_000_000, maxLines: 5)

        XCTAssertEqual(result, Array(lines.suffix(5)))
    }

    // MARK: - parseFileTail behavior (SessionIndexer)

    func testParseFileTailReturnsTailEventsInOrderAndMarksPartiallyHydrated() {
        var lines: [String] = []
        var contentByIndex: [String] = []
        for i in 0..<50 {
            let ts = String(format: "2026-07-01T12:00:%02d.000Z", i % 60)
            let content = i % 2 == 0 ? "user message \(i)" : "assistant reply \(i)"
            let role = i % 2 == 0 ? "user" : "assistant"
            lines.append(#"{"timestamp":"\#(ts)","role":"\#(role)","content":"\#(content)"}"#)
            contentByIndex.append(content)
        }
        write(lines.joined(separator: "\n") + "\n")

        let indexer = SessionIndexer()
        let session = indexer.parseFileTail(at: tempURL, forcedID: "tail-test-id", maxBytes: 1_000_000, maxLines: 10)

        XCTAssertNotNil(session)
        guard let session else { return }

        XCTAssertTrue(session.isPartiallyHydrated)
        XCTAssertEqual(session.id, "tail-test-id")
        XCTAssertEqual(session.source, .codex)
        XCTAssertEqual(session.events.count, 10)

        // Must be the LAST 10 lines, in original file order (indices 40...49).
        let expectedTailTexts = Array(contentByIndex.suffix(10))
        let actualTexts = session.events.map { $0.text ?? "" }
        XCTAssertEqual(actualTexts, expectedTailTexts)
    }

    func testParseFileTailReturnsNilWhenNoTailLinesAvailable() {
        // No newline anywhere -> ReverseJSONLTailReader returns [] -> parseFileTail should return nil.
        write(String(repeating: "x", count: 50))

        let indexer = SessionIndexer()
        let session = indexer.parseFileTail(at: tempURL, maxBytes: 10, maxLines: 400)

        XCTAssertNil(session)
    }
}
