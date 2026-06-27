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

    func testAntigravityMarkdownImageScannerFindsLocalMarkdownImages() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("preview.png", isDirectory: false)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL, options: [.atomic])
        let encodedFileURL = root.appendingPathComponent("space image.png", isDirectory: false)
        try Data([0x89, 0x50]).write(to: encodedFileURL, options: [.atomic])

        let markdown = """
        # Walkthrough
        ![Preview](preview.png)
        ![Encoded](\(encodedFileURL.absoluteString))
        ![Remote](https://example.com/remote.png)
        """
        let markdownURL = root.appendingPathComponent("walkthrough.md", isDirectory: false)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let matches = try AntigravityMarkdownImageScanner.scanFile(at: markdownURL, maxMatches: 10)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].lineIndex, 1)
        XCTAssertEqual(matches[0].fileURL.path, imageURL.path)
        XCTAssertEqual(matches[0].mediaType, "image/png")
        XCTAssertEqual(matches[0].fileSizeBytes, 4)
        XCTAssertEqual(matches[1].lineIndex, 2)
        XCTAssertEqual(matches[1].fileURL.path, encodedFileURL.path)
    }

    func testAntigravityInlineImageMappingUsesFirstArtifactBlockWithoutUserPrompt() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)", isDirectory: true)
        let conversation = root.appendingPathComponent("conv-abc", isDirectory: true)
        try fm.createDirectory(at: conversation, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let imageURL = conversation.appendingPathComponent("preview.png", isDirectory: false)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL, options: [.atomic])

        let markdownURL = conversation.appendingPathComponent("walkthrough.md", isDirectory: false)
        try """
        # Walkthrough
        ![Preview](preview.png)
        """.write(to: markdownURL, atomically: true, encoding: .utf8)

        guard let session = AntigravitySessionParser.parseFileFull(at: markdownURL) else {
            return XCTFail("parse returned nil")
        }

        let mapped = SessionInlineImageMapper.imagesByUserBlockIndex(for: session)
        XCTAssertEqual(mapped.keys.sorted(), [0])
        XCTAssertEqual(mapped[0]?.count, 1)
        XCTAssertEqual(mapped[0]?.first?.payload.mediaType, "image/png")
        XCTAssertNil(mapped[0]?.first?.userPromptIndex)
    }

    func testAntigravityImageBrowserIndexRebuildsLegacyEmptyCache() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)", isDirectory: true)
        let conversation = root.appendingPathComponent("conv-cache", isDirectory: true)
        try fm.createDirectory(at: conversation, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let imageURL = conversation.appendingPathComponent("preview.png", isDirectory: false)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL, options: [.atomic])

        let markdownURL = conversation.appendingPathComponent("walkthrough.md", isDirectory: false)
        try """
        # Walkthrough
        ![Preview](preview.png)
        """.write(to: markdownURL, atomically: true, encoding: .utf8)

        guard let session = AntigravitySessionParser.parseFileFull(at: markdownURL) else {
            return XCTFail("parse returned nil")
        }

        let attrs = try fm.attributesOfItem(atPath: markdownURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let signature = ImageBrowserFileSignature(filePath: markdownURL.path,
                                                  fileSizeBytes: size,
                                                  modifiedAtUnixSeconds: Int64(modified.timeIntervalSince1970))
        let legacyEmpty = ImageBrowserStoredIndex(signature: signature,
                                                 spans: [],
                                                 openCodeImages: nil,
                                                 copilotAttachments: nil,
                                                 antigravityImages: nil,
                                                 createdAtUnixSeconds: Int64(Date().timeIntervalSince1970))
        let cache = ImageBrowserIndexCache(cacheRootOverride: root.appendingPathComponent("cache", isDirectory: true))
        await cache.saveIndex(legacyEmpty, forPath: markdownURL.path)

        let rebuilt = await cache.getOrBuildIndex(for: session, maxMatches: 10)
        XCTAssertEqual(rebuilt.antigravityImages?.count, 1)
        XCTAssertEqual(rebuilt.antigravityImages?.first?.filePath, imageURL.path)
    }

}
