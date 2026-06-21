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

}
