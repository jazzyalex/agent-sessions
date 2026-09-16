import XCTest
@testable import AgentSessions

/// Parser for Cline CLI and Desktop manifests plus adjacent messages files,
/// verified against the redacted stage0 fixtures.
final class ClineSessionParserTests: XCTestCase {
    private func cliManifestURL() -> URL {
        FixturePaths.stage0FixtureURL("agents/cline/cli_tool/cline-cli-tool.json")
    }

    private func desktopManifestURL() -> URL {
        FixturePaths.stage0FixtureURL("agents/cline/desktop_continued/cline-desktop-continued.json")
    }

    // MARK: - CLI fixture

    func testCliPreviewIsLightweightWithAccurateCounts() throws {
        guard let preview = ClineSessionParser.parseFile(at: cliManifestURL()) else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertEqual(preview.source, .cline)
        XCTAssertEqual(preview.id, "cline-cli-tool")
        XCTAssertTrue(preview.events.isEmpty, "preview must carry no events")
        XCTAssertEqual(preview.eventCount, 4)
        XCTAssertEqual(preview.lightweightCommands, 1)
        XCTAssertEqual(preview.model, "poolside/laguna-s-2.1:free")
        XCTAssertEqual(preview.cwd, "/tmp/as-agent-fixture/project")
        XCTAssertEqual(preview.surface, .cli)
    }

    func testCliFullParsePreservesOrderAndRawJSON() throws {
        guard let full = ClineSessionParser.parseFileFull(at: cliManifestURL()) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertEqual(full.source, .cline)
        XCTAssertEqual(full.id, "cline-cli-tool")
        XCTAssertEqual(full.events.count, 5)
        XCTAssertEqual(full.eventCount, 4)
        XCTAssertTrue(full.events.allSatisfy { !$0.rawJSON.isEmpty }, "full parse must preserve raw JSON")

        let kinds = full.events.map(\.kind)
        XCTAssertEqual(kinds, [.user, .meta, .assistant, .tool_call, .error])

        // Text maps under the enclosing message role.
        XCTAssertEqual(full.events[0].text, "Inspect fixture.txt and report its first line.")
        XCTAssertEqual(full.events[2].text, "I will inspect the file.")

        // Thinking becomes meta.
        XCTAssertEqual(full.events[1].kind, .meta)
        XCTAssertEqual(full.events[1].text, "I should read the requested fixture file.")

        // Tool call preserves name and JSON input.
        let call = full.events[3]
        XCTAssertEqual(call.toolName, "run_commands")
        XCTAssertTrue((call.toolInput ?? "").contains("sed -n '1p' fixture.txt"))

        // Tool result with is_error=true becomes an error.
        let result = full.events[4]
        XCTAssertEqual(result.kind, .error)
        XCTAssertEqual(result.toolName, "run_commands")
        XCTAssertEqual(result.toolOutput, "fixture line one")
        XCTAssertEqual(result.messageID, "cline-tool-1")
    }

    func testCliTitlePrefersMetadataTitle() throws {
        guard let full = ClineSessionParser.parseFileFull(at: cliManifestURL()) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertEqual(full.lightweightTitle, "Inspect the fixture file")
    }

    func testCliTimestampsComeFromManifestAndMessages() throws {
        guard let full = ClineSessionParser.parseFileFull(at: cliManifestURL()) else {
            return XCTFail("full parse returned nil")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(full.startTime, iso.date(from: "2026-09-15T21:21:57.131Z"))
        XCTAssertEqual(full.endTime, iso.date(from: "2026-09-15T21:22:44.000Z"))
        // Millisecond message timestamps reach the events.
        XCTAssertNotNil(full.events[0].timestamp)
        XCTAssertGreaterThan(full.events[2].timestamp ?? .distantPast, full.events[0].timestamp ?? .distantPast)
    }

    // MARK: - Desktop fixture

    func testDesktopPreviewAndFull() throws {
        guard let preview = ClineSessionParser.parseFile(at: desktopManifestURL()) else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertEqual(preview.source, .cline)
        XCTAssertEqual(preview.id, "cline-desktop-continued")
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertEqual(preview.eventCount, 5)
        XCTAssertNil(preview.lightweightCommands)
        XCTAssertEqual(preview.surface, .desktop)
        XCTAssertEqual(preview.model, "gpt-5.6-terra")
        XCTAssertEqual(preview.lightweightTitle, "Review the fixture project")

        guard let full = ClineSessionParser.parseFileFull(at: desktopManifestURL()) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertEqual(full.events.count, 5)
        XCTAssertTrue(full.events.allSatisfy { $0.kind == .user || $0.kind == .assistant })
        XCTAssertEqual(full.events.map(\.text), [
            "Review the fixture project.",
            "Focus on the parser contract.",
            "The parser contract is consistent.",
            "Check the follow-up path too.",
            "The continued conversation remains ordered."
        ])
    }

    // MARK: - Manifest rules

    /// The manifest's `messages_path` is an absolute export-time path and must
    /// never be followed — the adjacent messages file is read instead. Both
    /// fixtures carry such a path pointing outside the repo, yet still parse.
    func testAdjacentMessagesFileIsPreferredOverAbsoluteMessagesPath() throws {
        for url in [cliManifestURL(), desktopManifestURL()] {
            let data = try Data(contentsOf: url)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messagesPath = try XCTUnwrap(object["messages_path"] as? String)
            XCTAssertTrue(messagesPath.hasPrefix("/tmp/as-agent-fixture/"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: messagesPath))
            XCTAssertNotNil(ClineSessionParser.parseFileFull(at: url), "\(url.lastPathComponent) must parse via its adjacent messages file")
        }
    }

    /// Stable ID is the manifest's `session_id`, not the primary filename.
    func testManifestSessionIDIsTheStableID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClineIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifestURL = dir.appendingPathComponent("disk-name.json")
        let manifest: [String: Any] = [
            "version": 1,
            "session_id": "manifest-id",
            "source": "cli",
            "started_at": "2026-09-15T21:21:57.131Z"
        ]
        let messages: [String: Any] = ["version": 1, "sessionId": "manifest-id", "messages": []]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try JSONSerialization.data(withJSONObject: messages)
            .write(to: dir.appendingPathComponent("disk-name.messages.json"))

        XCTAssertEqual(ClineSessionParser.parseFileFull(at: manifestURL)?.id, "manifest-id")
    }

    func testMismatchedMessagesIdentityIsRejectedInPreviewAndFullParse() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClineMismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifestURL = dir.appendingPathComponent("expected.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "session_id": "expected",
            "source": "desktop",
            "started_at": "2026-09-15T21:21:57.131Z"
        ]).write(to: manifestURL)
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessionId": "different",
            "messages": []
        ]).write(to: dir.appendingPathComponent("expected.messages.json"))

        XCTAssertNil(ClineSessionParser.parseFile(at: manifestURL))
        XCTAssertNil(ClineSessionParser.parseFileFull(at: manifestURL))
    }

    func testUnknownBlockTypeSurvivesAsMeta() {
        let block: [String: Any] = ["type": "mystery_block", "payload": "xyz"]
        let events = ClineSessionParser.eventsForBlockDictionary(block,
                                                                role: "assistant",
                                                                messageID: "m1",
                                                                time: nil,
                                                                messageIndex: 0,
                                                                blockIndex: 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .meta)
        XCTAssertTrue(events[0].rawJSON.contains("mystery_block"))
    }

    func testToolResultWithoutErrorFlagIsToolResult() {
        let block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": "t1",
            "name": "run_commands",
            "content": "ok",
            "is_error": false
        ]
        let events = ClineSessionParser.eventsForBlockDictionary(block,
                                                                role: "assistant",
                                                                messageID: "m1",
                                                                time: nil,
                                                                messageIndex: 0,
                                                                blockIndex: 0)
        XCTAssertEqual(events[0].kind, .tool_result)
        XCTAssertEqual(events[0].toolOutput, "ok")
    }

    func testTitleFallsBackToPromptThenFirstUserText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClineTitle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func writeManifest(id: String, metadataTitle: String?, prompt: String?) -> URL {
            let manifestURL = dir.appendingPathComponent("\(id).json")
            var manifest: [String: Any] = [
                "version": 1,
                "session_id": id,
                "source": "cli",
                "started_at": "2026-09-15T21:21:57.131Z",
                "model": "m",
                "cwd": "/tmp/p"
            ]
            if let prompt { manifest["prompt"] = prompt }
            if let metadataTitle { manifest["metadata"] = ["title": metadataTitle] }
            try! JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            let messages: [String: Any] = [
                "version": 1,
                "sessionId": id,
                "messages": [
                    ["role": "user", "ts": 1789507317131, "id": "u1",
                     "content": [["type": "text", "text": "First user text"]]]
                ]
            ]
            try! JSONSerialization.data(withJSONObject: messages)
                .write(to: dir.appendingPathComponent("\(id).messages.json"))
            return manifestURL
        }

        let withTitle = writeManifest(id: "t1", metadataTitle: "Meta title", prompt: "Prompt title")
        XCTAssertEqual(ClineSessionParser.parseFile(at: withTitle)?.lightweightTitle, "Meta title")

        let withPrompt = writeManifest(id: "t2", metadataTitle: nil, prompt: "Prompt title")
        XCTAssertEqual(ClineSessionParser.parseFile(at: withPrompt)?.lightweightTitle, "Prompt title")

        let withUser = writeManifest(id: "t3", metadataTitle: nil, prompt: nil)
        XCTAssertEqual(ClineSessionParser.parseFile(at: withUser)?.lightweightTitle, "First user text")
    }

    func testFullParseLimitAndReportedSizeCoverManifestAndMessages() throws {
        let manifestURL = cliManifestURL()
        let messagesURL = ClineSessionDiscovery.messagesFile(forManifest: manifestURL)
        let manifestSize = try XCTUnwrap(manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let messagesSize = try XCTUnwrap(messagesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let combinedSize = manifestSize + messagesSize

        XCTAssertGreaterThan(messagesSize, 0)
        XCTAssertNil(ClineSessionParser.parseFileFull(at: manifestURL,
                                                      maxBytes: combinedSize - 1))
        let parsed = try XCTUnwrap(ClineSessionParser.parseFileFull(at: manifestURL,
                                                                    maxBytes: combinedSize))
        XCTAssertEqual(parsed.fileSizeBytes, combinedSize)
    }

    func testPreviewLimitBoundsWholeMessagesObjectGraph() throws {
        let manifestURL = cliManifestURL()
        let combinedSize = ClineSessionParser.combinedFileSize(forManifest: manifestURL)
        XCTAssertNil(ClineSessionParser.parseFile(at: manifestURL, maxBytes: combinedSize - 1))
        XCTAssertNotNil(ClineSessionParser.parseFile(at: manifestURL, maxBytes: combinedSize))
    }

    func testReloadStatChangesWhenOnlyMessagesFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClineStat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifestURL = dir.appendingPathComponent("stat.json")
        let messagesURL = dir.appendingPathComponent("stat.messages.json")
        try Data("{}".utf8).write(to: manifestURL)
        try Data("{}".utf8).write(to: messagesURL)
        let before = try XCTUnwrap(ClineSessionIndexer.fileStat(for: manifestURL))

        try Data("{\"messages\":[]}".utf8).write(to: messagesURL)
        let after = try XCTUnwrap(ClineSessionIndexer.fileStat(for: manifestURL))
        XCTAssertNotEqual(before, after)
    }

    func testMalformedExistingMessagesFileFailsFullParseWithoutDroppingPreview() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClinePartial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifestURL = dir.appendingPathComponent("partial.json")
        let manifest: [String: Any] = [
            "version": 1,
            "session_id": "partial",
            "source": "cli",
            "started_at": "2026-09-15T21:21:57.131Z",
            "prompt": "Keep the list row"
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try Data("{\"messages\":[".utf8)
            .write(to: dir.appendingPathComponent("partial.messages.json"))

        XCTAssertEqual(ClineSessionParser.parseFile(at: manifestURL)?.lightweightTitle,
                       "Keep the list row")
        XCTAssertNil(ClineSessionParser.parseFileFull(at: manifestURL),
                     "a transient partial write must not become an authoritative empty transcript")
    }

    func testMissingMessagesFileFailsFullParseWithoutDroppingPreview() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClineMissingCompanion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifestURL = dir.appendingPathComponent("missing.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "session_id": "missing",
            "source": "cli",
            "started_at": "2026-09-15T21:21:57.131Z",
            "prompt": "Keep the existing transcript"
        ]).write(to: manifestURL)

        XCTAssertEqual(ClineSessionParser.parseFile(at: manifestURL)?.lightweightTitle,
                       "Keep the existing transcript")
        XCTAssertNil(ClineSessionParser.parseFileFull(at: manifestURL),
                     "a missing companion must not clear an already-loaded transcript")
    }

    func testUnsupportedContractVersionFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClineVersion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifestURL = dir.appendingPathComponent("future.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "session_id": "future",
            "source": "cli"
        ]).write(to: manifestURL)
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessionId": "future",
            "messages": []
        ]).write(to: dir.appendingPathComponent("future.messages.json"))

        XCTAssertNil(ClineSessionParser.parseFile(at: manifestURL))
        XCTAssertNil(ClineSessionParser.parseFileFull(at: manifestURL))

        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "session_id": "future",
            "source": "cli"
        ]).write(to: manifestURL)
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessionId": "future",
            "messages": []
        ]).write(to: dir.appendingPathComponent("future.messages.json"))

        XCTAssertNil(ClineSessionParser.parseFile(at: manifestURL))
        XCTAssertNil(ClineSessionParser.parseFileFull(at: manifestURL))
    }
}
