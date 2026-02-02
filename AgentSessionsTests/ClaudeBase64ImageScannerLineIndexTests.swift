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

