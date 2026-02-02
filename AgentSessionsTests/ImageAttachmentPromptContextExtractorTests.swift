import XCTest
@testable import AgentSessions

final class ImageAttachmentPromptContextExtractorTests: XCTestCase {
    func testClaudeExtractPromptTextFromNearbyTextFields() throws {
        let jsonl = """
        {"type":"message","role":"user","content":[{"type":"text","text":"fix this TypeError, useEffect firing twice"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo="}}]}
        """
        let url = try writeTempJSONL(contents: jsonl)
        defer { try? FileManager.default.removeItem(at: url) }

        let spans = try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 10)
        XCTAssertEqual(spans.count, 1)
        let span = spans[0].span

        let extracted = ImageAttachmentPromptContextExtractor.extractPromptText(url: url, span: span)
        XCTAssertEqual(extracted, "fix this TypeError, useEffect firing twice")
    }

    func testCodexExtractPromptTextFromNearbyTextFields() throws {
        let jsonl = """
        {"type":"message","role":"user","content":[{"type":"text","text":"show me the bug in this code"},{"type":"image_url","image_url":{"url":"data:image/png;base64,QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo="}}]}
        """
        let url = try writeTempJSONL(contents: jsonl)
        defer { try? FileManager.default.removeItem(at: url) }

        let located = try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: 10)
        XCTAssertEqual(located.count, 1)
        let span = located[0].span

        let extracted = ImageAttachmentPromptContextExtractor.extractPromptText(url: url, span: span)
        XCTAssertEqual(extracted, "show me the bug in this code")
    }

    private func writeTempJSONL(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessionsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        try contents.data(using: .utf8)!.write(to: url, options: [.atomic])
        return url
    }
}

