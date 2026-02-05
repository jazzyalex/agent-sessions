import XCTest

final class OpenClawBase64ImageScannerLogicTests: XCTestCase {
    func testScansUserImageBlocks() throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/6X+qS8AAAAASUVORK5CYII="
        let line = """
        {"type":"message","message":{"role":"user","content":[{"type":"image","data":"\(pngBase64)","mimeType":"image/png"}]}}
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let located = try OpenClawBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 10)
        XCTAssertEqual(located.count, 1)

        let item = located[0]
        XCTAssertEqual(item.lineIndex, 0)
        XCTAssertEqual(item.span.mediaType, "image/png")

        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: item.span.base64PayloadOffset)
        let slice = try fh.read(upToCount: item.span.base64PayloadLength) ?? Data()

        guard let decoded = Data(base64Encoded: slice, options: [.ignoreUnknownCharacters]) else {
            XCTFail("Expected base64 payload to decode")
            return
        }
        XCTAssertGreaterThanOrEqual(decoded.count, 8)
        XCTAssertEqual(Array(decoded.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testIgnoresNonUserRoles() throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/6X+qS8AAAAASUVORK5CYII="
        let line = """
        {"type":"message","message":{"role":"assistant","content":[{"type":"image","data":"\(pngBase64)","mimeType":"image/png"}]}}
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let located = try OpenClawBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 10)
        XCTAssertEqual(located.count, 0)
    }

    func testRoleAfterContentStillCountsAsUserLine() throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/6X+qS8AAAAASUVORK5CYII="
        let line = """
        {"type":"message","message":{"content":[{"type":"image","data":"\(pngBase64)","mimeType":"image/png"}],"role":"user"}}
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let located = try OpenClawBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 10)
        XCTAssertEqual(located.count, 1)
        XCTAssertEqual(located.first?.span.mediaType, "image/png")
    }

    func testScansRealisticEnvelopeWithExtraStringFields() throws {
        let jpgBase64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SEhAUEBIXFxcXFxcaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaH//2wBDARESEhgVGBgaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaH//wAARCAAQABADASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGrAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAQUCcf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQMBAT8Bj//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQIBAT8Bj//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEABj8Cf//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAT8h/9k="
        let line = """
        {"type":"message","id":"8d440f48","parentId":"20351b27","timestamp":"2026-02-04T01:06:58.680Z","message":{"role":"user","content":[{"type":"text","text":"hello"},{"type":"image","data":"\(jpgBase64)","mimeType":"image/jpeg"}],"timestamp":1770167218671}}
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let located = try OpenClawBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 10)
        XCTAssertEqual(located.count, 1)
        XCTAssertEqual(located.first?.span.mediaType, "image/jpeg")
    }
}
