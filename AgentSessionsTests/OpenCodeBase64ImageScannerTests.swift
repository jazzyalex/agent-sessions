import XCTest
@testable import AgentSessions

final class OpenCodeBase64ImageScannerTests: XCTestCase {
    func testScanSessionPartFiles_FindsDataImageInFileParts() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let storageRoot = tmp.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try "2".data(using: .utf8)!.write(to: storageRoot.appendingPathComponent("migration"), options: [.atomic])

        let sessionURL = storageRoot
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent("ses_test.json", isDirectory: false)
        try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"id":"ses_test"}"#.data(using: .utf8)!.write(to: sessionURL, options: [.atomic])

        let messageID = "msg_test_1"
        let partDir = storageRoot
            .appendingPathComponent("part", isDirectory: true)
            .appendingPathComponent(messageID, isDirectory: true)
        try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)

        let base64 = String(repeating: "A", count: 160)
        let partJSON = #"{"type":"file","mime":"image/png","url":"data:image/png;base64,\#(base64)"}"#
        let partURL = partDir.appendingPathComponent("prt_test.json", isDirectory: false)
        try partJSON.data(using: .utf8)!.write(to: partURL, options: [.atomic])

        XCTAssertTrue(OpenCodeBase64ImageScanner.fileContainsBase64ImageDataURL(sessionFileURL: sessionURL,
                                                                               messageIDs: [messageID]))

        let spans = try OpenCodeBase64ImageScanner.scanSessionPartFiles(sessionFileURL: sessionURL, messageIDs: [messageID], maxMatches: 10)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.messageID, messageID)
        XCTAssertEqual(spans.first?.partFileURL.resolvingSymlinksInPath().path, partURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(spans.first?.span.mediaType, "image/png")
        XCTAssertGreaterThan(spans.first?.span.base64PayloadLength ?? 0, 0)
    }
}
