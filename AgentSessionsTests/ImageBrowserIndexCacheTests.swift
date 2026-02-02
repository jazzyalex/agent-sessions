import XCTest
@testable import AgentSessions

final class ImageBrowserIndexCacheTests: XCTestCase {
    func testGetOrBuildIndex_Codex_CachesBySignature() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessionsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sessionURL = tmp.appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        let base64 = String(repeating: "A", count: 160)
        let jsonl = #"{"type":"message","role":"user","content":[{"type":"text","text":"hello"},{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(base64)"}}]}"# + "\n"
        try jsonl.data(using: .utf8)!.write(to: sessionURL, options: [.atomic])

        let cacheRoot = tmp.appendingPathComponent("ImageBrowserCache-\(UUID().uuidString)", isDirectory: true)
        let cache = ImageBrowserIndexCache(cacheRootOverride: cacheRoot)

        let session = Session(id: "s1", source: .codex, startTime: nil, endTime: nil, model: nil, filePath: sessionURL.path, fileSizeBytes: nil, eventCount: 0, events: [])
        let first = await cache.getOrBuildIndex(for: session, maxMatches: 10)
        XCTAssertEqual(first.spans.count, 1)

        let second = await cache.getOrBuildIndex(for: session, maxMatches: 10)
        XCTAssertEqual(second.signature, first.signature)
        XCTAssertEqual(second.spans, first.spans)

        // Invalidate by changing file size (signature changes even if mtime resolution is coarse).
        let appended = jsonl + " \n"
        try appended.data(using: .utf8)!.write(to: sessionURL, options: [.atomic])
        let third = await cache.getOrBuildIndex(for: session, maxMatches: 10)
        XCTAssertNotEqual(third.signature.fileSizeBytes, first.signature.fileSizeBytes)
    }

    func testGetOrBuildIndex_Claude_FindsUserImageBlocks() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessionsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sessionURL = tmp.appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        let base64 = String(repeating: "B", count: 160)
        let jsonl = #"{"type":"message","role":"user","content":[{"type":"text","text":"hi"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(base64)"}}]}"# + "\n"
        try jsonl.data(using: .utf8)!.write(to: sessionURL, options: [.atomic])

        let cacheRoot = tmp.appendingPathComponent("ImageBrowserCache-\(UUID().uuidString)", isDirectory: true)
        let cache = ImageBrowserIndexCache(cacheRootOverride: cacheRoot)

        let session = Session(id: "s2", source: .claude, startTime: nil, endTime: nil, model: nil, filePath: sessionURL.path, fileSizeBytes: nil, eventCount: 0, events: [])
        let built = await cache.getOrBuildIndex(for: session, maxMatches: 10)
        XCTAssertEqual(built.spans.count, 1)
        XCTAssertEqual(built.spans.first?.mediaType, "image/png")
    }
}

