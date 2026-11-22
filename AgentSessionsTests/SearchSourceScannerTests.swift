import XCTest
@testable import AgentSessions

final class SearchSourceScannerTests: XCTestCase {
    private func fixture(_ records: [[String: Any]], source: SessionSource = .claude) throws -> Session {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.jsonl")
        let data = try records.map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        try data.write(to: file)
        return Session(id: "synthetic", source: source, startTime: nil, endTime: nil, model: nil,
            filePath: file.path, fileSizeBytes: data.count, eventCount: records.count, events: [],
            cwd: nil, repoName: nil, lightweightTitle: "Synthetic fixture")
    }
    private func message(_ text: String) -> [String: Any] {
        ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
    }
    private func scan(_ session: Session, _ query: String) async throws -> SearchScanResult {
        let tokenizer = try SearchTokenizer()
        return await SearchSourceScanner.scan(session: session, query: try SearchQuery(query, tokenizer: tokenizer))
    }

    func testAndAccumulatesAcrossEventsWhilePhraseStaysWithinField() async throws {
        let session = try fixture([message("alpha"), message("beta")])
        let and = try await scan(session, "alpha AND beta")
        XCTAssertEqual(and.truth, .yes); XCTAssertTrue(and.summary.complete)
        let phrase = try await scan(session, "\"alpha beta\"")
        XCTAssertEqual(phrase.truth, .no); XCTAssertTrue(phrase.summary.complete)
    }

    func testPreservedClaudeOutputBeyondRawJSONSanitizerAndLiteralOmissionMarker() async throws {
        let output = String(repeating: "ordinary output ", count: 900) + "needle-final [OMITTED legitimate source]"
        let session = try fixture([["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "tool-1", "content": output]
        ]]]])
        let result = try await scan(session, "\"needle final\"")
        XCTAssertEqual(result.truth, .yes); XCTAssertTrue(result.summary.complete)
        XCTAssertLessThanOrEqual(result.snippet?.utf16.count ?? 0, 512)
        let marker = try await scan(session, "\"OMITTED legitimate\"")
        XCTAssertEqual(marker.truth, .yes)
    }

    func testStreamSampleIndexesToolResultTextAndToolOutputWithoutDuplication() {
        let shared = "sharedtoolresultordinarytoken"
        let textOnly = "textonlytoolresultordinarytoken"
        let events = [
            SessionEvent(id: "shared", timestamp: nil, kind: .tool_result, role: "tool",
                         text: shared, toolName: nil, toolInput: nil, toolOutput: shared,
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}"),
            SessionEvent(id: "text-only", timestamp: nil, kind: .tool_result, role: "tool",
                         text: textOnly, toolName: nil, toolInput: nil, toolOutput: nil,
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
        ]

        var sample = SessionSearchTextBuilder.StreamSample()
        for event in events {
            for segment in SearchSourceText.segments(event: event, source: .codex) {
                sample.consume(segment)
            }
        }

        XCTAssertTrue(sample.ordinary.contains(shared))
        XCTAssertTrue(sample.toolIO.contains(shared))
        XCTAssertTrue(sample.ordinary.contains(textOnly))
        XCTAssertTrue(sample.toolIO.contains(textOnly))
        XCTAssertEqual(sample.toolIO.components(separatedBy: shared).count - 1, 1,
                       "text and toolOutput containing the same result should be indexed once")
    }

    func testNotRequiresCompleteCoverageAndMalformedSourceIsNotNoMatch() async throws {
        let session = try fixture([message("alpha")])
        let file = URL(fileURLWithPath: session.filePath)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken}\n".utf8)); try handle.close()
        let negative = try await scan(session, "alpha NOT beta")
        XCTAssertEqual(negative.truth, .unknown)
        XCTAssertTrue(negative.summary.reasons.contains(.malformedRecord))
        let positive = try await scan(session, "alpha")
        XCTAssertEqual(positive.truth, .yes)
        XCTAssertFalse(positive.summary.complete)
    }

    func testResourcePreflightRejectsDeepAndHighFanoutContainersBeforeDecode() throws {
        XCTAssertThrowsError(try SearchSourceScanner.validateJSON(Data((String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8)))
        let array = "[" + Array(repeating: "0", count: 70_000).joined(separator: ",") + "]"
        XCTAssertThrowsError(try SearchSourceScanner.validateJSON(Data(array.utf8)))
        let safe = try SearchSourceScanner.validateJSON(Data("{\"text\":\"synthetic\"}".utf8))
        XCTAssertLessThan(safe, SearchSourceScanner.payloadBytes)
    }

    func testMissingFileCannotProduceCompleteNegative() async throws {
        let session = try fixture([message("alpha")])
        try FileManager.default.removeItem(atPath: session.filePath)
        let result = try await scan(session, "NOT alpha")
        XCTAssertEqual(result.truth, .unknown)
        XCTAssertTrue(result.summary.reasons.contains(.unavailable))
    }

    func testLongIndivisibleTokenIsExplicitResourceLimit() throws {
        let tokenizer = try SearchTokenizer()
        XCTAssertThrowsError(try tokenizer.enumerate(String(repeating: "a", count: 65_537)) { _ in })
    }

    func testEarlierWitnessCannotBecomePositiveWhenLaterTokenStopsExtraction() async throws {
        let text = "alpha " + String(repeating: "z", count: 65_537)
        let session = try fixture([message(text)])

        let result = try await scan(session, "alpha")

        XCTAssertFalse(result.summary.complete)
        XCTAssertTrue(result.summary.reasons.contains(.resourceLimit))
        XCTAssertTrue(result.truth == .unknown,
                      "an earlier token witness is not verified after extraction stops before the source proof")
    }

    func testMutationFromSegmentConsumerReportsSourceChanged() throws {
        let session = try fixture([message("mutation-trigger")])
        let sourceURL = URL(fileURLWithPath: session.filePath)
        var mutated = false

        let summary = SearchSourceScanner.scanSegments(session: session) { segment in
            guard !mutated, segment.kind == .message, segment.text == "mutation-trigger" else { return }
            mutated = true
            let handle = try FileHandle(forWritingTo: sourceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"assistant\"}\n".utf8))
        }

        XCTAssertTrue(mutated, "the fixture event should reach the segment consumer")
        XCTAssertTrue(summary.reasons.contains(.sourceChanged))
        XCTAssertFalse(summary.complete)
    }
}
