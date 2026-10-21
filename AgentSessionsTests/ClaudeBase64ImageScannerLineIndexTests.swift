import XCTest
@testable import AgentSessions

final class ClaudeBase64ImageScannerLineIndexTests: XCTestCase {
    private func writeTempJSONL(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBase64ImageScannerLineIndexTests-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        guard let data = text.data(using: .utf8) else {
            XCTFail("Failed to encode fixture as UTF-8")
            return url
        }
        try data.write(to: url)
        return url
    }

    func testSpansComputeExpectedLineIndexes() throws {
        let jsonl = """
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"no image"}]}}
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"with image"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJDRA=="}}]}}
        {"type":"tool_result","output":"noop"}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let located = try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.count, 1)
        XCTAssertEqual(located[0].lineIndex, 1)
        XCTAssertEqual(located[0].span.mediaType, "image/png")
        XCTAssertEqual(located[0].span.base64PayloadLength, "QUJDRA==".count)
    }

    // Claude Code 2.1.303+ repeats user messages (with their images) in
    // `api-request-blob` request-log lines. Only the real user line counts,
    // whether `type` comes first (as written) or last on the blob line.
    func testSkipsImagesInsideRequestLogBlobLines() throws {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"QUJDRA=="}}]}]}}
        {"type":"api-request-blob","hash":"b1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"QUJDRA=="}}]}]}}
        {"hash":"b2","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJDRA=="}}]},"type":"api-request-blob"}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let located = try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.map(\.lineIndex), [0])
    }

    // With maxMatches 1 the scanner used to stop at the first span, before a late
    // `type` key could drop it, so a file holding only a request-log copy reported an image.
    func testRequestLogLineWithLateTypeDoesNotCountAsAnImageUnderMaxMatchesOne() throws {
        let jsonl = """
        {"hash":"b2","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJDRA=="}}]},"type":"api-request-blob"}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(ClaudeBase64ImageScanner.fileContainsUserBase64Image(at: url))
        XCTAssertEqual(try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 1).count, 0)
    }

    func testMaxMatchesStillCapsResults() throws {
        let image = #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJDRA=="}}"#
        let jsonl = """
        {"type":"user","message":{"role":"user","content":[\(image),\(image)]}}
        {"type":"user","message":{"role":"user","content":[\(image)]}}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(ClaudeBase64ImageScanner.fileContainsUserBase64Image(at: url))
        XCTAssertEqual(try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 1).map(\.lineIndex), [0])
        XCTAssertEqual(try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 20).map(\.lineIndex), [0, 0, 1])
    }

    // Line numbers must match `JSONLReader`, which skips blank lines, because Claude
    // event ids carry the reader's count and image placement compares the two.
    func testBlankLinesDoNotAdvanceTheLineIndex() throws {
        let jsonl = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n\n\r\n"
            + "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJDRA==\"}}]}}\n"
        let url = try writeTempJSONL(jsonl)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 20).map(\.lineIndex), [1])
        // The parser's ids put the image record on the same line.
        let session = try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url))
        XCTAssertEqual(session.events.map { ClaudeSessionParser.sourceLineIndex(forEventID: $0.id) }, [0, 1])
    }

    func testDoesNotMatchEscapedImageJSONInsideToolOutputString() throws {
        let jsonl = """
        {"type":"tool_result","output":"example \\\"type\\\":\\\"image\\\", \\\"source\\\":{\\\"type\\\":\\\"base64\\\", \\\"media_type\\\":\\\"image/png\\\", \\\"data\\\":\\\"QUJDRA==\\\"}"}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let located = try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.count, 0)
    }
}

