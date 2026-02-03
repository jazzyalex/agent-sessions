import XCTest
@testable import AgentSessions

final class AgentImageScannerTests: XCTestCase {
    func testCopilotAttachmentScannerFindsImageAttachments() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("example.png", isDirectory: false)
        try Data([0x01]).write(to: imageURL, options: [.atomic])

        let jsonl = """
        {"type":"user.message","data":{"content":"hi","attachments":[{"type":"file","path":"\(imageURL.path)","displayName":"example.png"}]}}
        {"type":"assistant.message","data":{"content":"ok"}}
        """
        let eventsURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        try jsonl.write(to: eventsURL, atomically: true, encoding: .utf8)

        let matches = try CopilotAttachmentScanner.scanFile(at: eventsURL, maxMatches: 10)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].eventSequenceIndex, 1)
        XCTAssertEqual(matches[0].fileURL.path, imageURL.path)
        XCTAssertTrue(matches[0].mediaType.hasPrefix("image/"))
        XCTAssertEqual(matches[0].fileSizeBytes, 1)
    }

    func testGeminiInlineDataImageScannerSpanDecodes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let decodedExpected = Data("hello".utf8)
        let base64 = decodedExpected.base64EncodedString()
        let json = """
        {"history":[{"role":"user","parts":[{"text":"Describe this image:"},{"inlineData":{"mimeType":"image/png","data":"\(base64)"}}]}]}
        """
        let sessionURL = root.appendingPathComponent("session.json", isDirectory: false)
        try json.write(to: sessionURL, atomically: true, encoding: .utf8)

        let spans = try GeminiInlineDataImageScanner.scanFile(at: sessionURL, maxMatches: 10)
        XCTAssertEqual(spans.count, 1)
        guard spans.count == 1 else { return }
        XCTAssertEqual(spans[0].itemIndex, 1)
        XCTAssertEqual(spans[0].span.mediaType, "image/png")

        let decoded = try CodexSessionImagePayload.decodeImageData(url: sessionURL,
                                                                  span: spans[0].span,
                                                                  maxDecodedBytes: 1024 * 1024)
        XCTAssertEqual(decoded, decodedExpected)
    }
}
