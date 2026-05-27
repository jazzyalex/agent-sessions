import XCTest
@testable import AgentSessions

final class ImageBrowserIndexCacheTests: XCTestCase {
    @MainActor
    func testImageBrowserUpdateSessionsAllowsDuplicateRawSessionIDs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessionsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let codexURL = tmp.appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        let claudeURL = tmp.appendingPathComponent(UUID().uuidString).appendingPathExtension("jsonl")
        defer {
            try? FileManager.default.removeItem(at: codexURL)
            try? FileManager.default.removeItem(at: claudeURL)
        }
        try Data().write(to: codexURL)
        try Data().write(to: claudeURL)

        let codex = Session(
            id: "shared-session-id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: codexURL.path,
            eventCount: 1,
            events: [makeEvent(id: "codex-0", text: "seed prompt")]
        )
        let duplicateCodex = Session(
            id: "shared-session-id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: codexURL.path,
            eventCount: 1,
            events: [makeEvent(id: "codex-duplicate-0", text: "duplicate prompt")]
        )
        let claude = Session(
            id: "shared-session-id",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: claudeURL.path,
            eventCount: 0,
            events: []
        )

        let viewModel = ImageBrowserViewModel()
        viewModel.updateSessions(allSessions: [duplicateCodex, claude, codex], seedSession: codex)
        viewModel.cancelBackgroundWork()
        let item = ImageBrowserViewModel.Item(
            sessionID: "shared-session-id",
            sessionTitle: "Shared",
            sessionModifiedAt: Date(),
            sessionFileURL: codexURL,
            sessionSource: .codex,
            sessionProject: nil,
            sessionImageIndex: 1,
            lineIndex: 0,
            eventID: "codex-0",
            userPromptIndex: 0,
            payload: .file(fileURL: codexURL, mediaType: "image/png", fileSizeBytes: 0),
            fileSignature: ImageBrowserFileSignature(filePath: codexURL.path, fileSizeBytes: 0, modifiedAtUnixSeconds: 0)
        )

        XCTAssertEqual(viewModel.seedSessionID, "shared-session-id")
        XCTAssertEqual(viewModel.selectedSources, [.codex])
        XCTAssertEqual(Set(viewModel.availableSources), [.codex, .claude])
        XCTAssertEqual(viewModel.loadedUserPromptText(for: item), "seed prompt")
    }

    private func makeEvent(id: String, text: String) -> SessionEvent {
        SessionEvent(
            id: id,
            timestamp: nil,
            kind: .user,
            role: "user",
            text: text,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
    }

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
