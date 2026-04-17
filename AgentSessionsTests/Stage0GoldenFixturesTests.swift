import XCTest
@testable import AgentSessions

final class Stage0GoldenFixturesTests: XCTestCase {
    func testCodexSmallPreviewAndFull() throws {
        let url = FixturePaths.stage0FixtureURL("agents/codex/small.jsonl")
        let idx = SessionIndexer()

        guard let preview = idx.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .codex)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertGreaterThan(preview.eventCount, 0)
        XCTAssertEqual(preview.cwd, "/tmp/repo")
        XCTAssertFalse(preview.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        guard let full = idx.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .codex)
        XCTAssertFalse(full.events.isEmpty)
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_result }))
    }

    func testCodexLargeAndSchemaDriftParses() throws {
        let idx = SessionIndexer()

        for name in ["agents/codex/large.jsonl", "agents/codex/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = idx.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertTrue(preview.events.isEmpty, "preview should stay lightweight: \(name)")
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = idx.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertFalse(full.events.isEmpty, "full parse should have events: \(name)")
        }
    }

    func testClaudeSmallPreviewAndFull() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/small.jsonl")
        guard let preview = ClaudeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .claude)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertGreaterThan(preview.eventCount, 0)

        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .claude)
        XCTAssertFalse(full.events.isEmpty)
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_result }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .meta }))
    }

    func testClaudeLargeAndSchemaDriftParses() throws {
        for name in ["agents/claude/large.jsonl", "agents/claude/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = ClaudeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testClaudeSchemaDriftAttachmentEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/schema_drift.jsonl")
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(withType: "attachment", in: full.events).isEmpty,
                       "attachment event should survive parsing as .meta")
    }

    func testClaudeSchemaDriftPermissionModeEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/schema_drift.jsonl")
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(withType: "permission-mode", in: full.events).isEmpty,
                       "permission-mode event should survive parsing as .meta")
    }

    func testClaudeSchemaDriftStopHookSummaryEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/schema_drift.jsonl")
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(containing: "\"subtype\":\"stop_hook_summary\"", in: full.events).isEmpty,
                       "stop_hook_summary system event should survive parsing as .meta")
    }

    func testCopilotSmallPreviewAndFull() throws {
        let url = FixturePaths.stage0FixtureURL("agents/copilot/small.jsonl")
        guard let preview = CopilotSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .copilot)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertGreaterThan(preview.eventCount, 0)
        XCTAssertEqual(preview.id, "copilot_stage0_small")
        XCTAssertEqual(preview.model, "gpt-5-mini")
        XCTAssertEqual(preview.cwd, "/tmp/repo")

        guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .copilot)
        XCTAssertFalse(full.events.isEmpty)
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_result }))
    }

    func testCopilotLargeAndSchemaDriftParses() throws {
        for name in ["agents/copilot/large.jsonl", "agents/copilot/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = CopilotSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testCopilotSchemaDriftShutdownEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/copilot/schema_drift.jsonl")
        guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(withType: "session.shutdown", in: full.events).isEmpty,
                       "session.shutdown event should survive parsing as .meta")
    }

    func testCopilotSubdirLayoutV1Parses() throws {
        // Exercises the v1.0.11+ storage layout: <uuid>/events.jsonl
        let name = "agents/copilot/subdir_v1/aaaabbbb-1111-2222-3333-ccccddddeeee/events.jsonl"
        let url = FixturePaths.stage0FixtureURL(name)
        guard let preview = CopilotSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .copilot)
        // Session ID should be the UUID directory name, not "events"
        XCTAssertEqual(preview.id, "aaaabbbb-1111-2222-3333-ccccddddeeee")
        XCTAssertGreaterThan(preview.eventCount, 0)

        guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .copilot)
        XCTAssertFalse(full.events.isEmpty)
    }

    func testDroidSessionStoreAndStreamJSONFixturesParse() throws {
        let paths = [
            "agents/droid/session_store_small.jsonl",
            "agents/droid/session_store_schema_drift.jsonl",
            "agents/droid/session_store_large.jsonl",
            "agents/droid/stream_json_small.jsonl",
            "agents/droid/stream_json_schema_drift.jsonl",
            "agents/droid/stream_json_large.jsonl"
        ]

        for name in paths {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = DroidSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .droid)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = DroidSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .droid)
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testGeminiFixturesParse() throws {
        for name in ["agents/gemini/small.json", "agents/gemini/schema_drift.json", "agents/gemini/large.json"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = GeminiSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .gemini)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .gemini)
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testOpenCodeFixturesParse() throws {
        // v2 fixtures
        for name in ["agents/opencode/storage_v2/session/proj_test/ses_s_stage0_small.json",
                     "agents/opencode/storage_v2/session/proj_test/ses_s_stage0_large.json"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = OpenCodeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .opencode)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)
            XCTAssertNotNil(preview.model)

            guard let full = OpenCodeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .opencode)
            XCTAssertFalse(full.events.isEmpty)
            XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }) || full.events.contains(where: { $0.kind == .assistant }))
        }

        // legacy fixtures (schema drift)
        do {
            let url = FixturePaths.stage0FixtureURL("agents/opencode/storage_legacy/session/proj_test/ses_s_stage0_drift.json")
            guard let preview = OpenCodeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
            XCTAssertEqual(preview.source, .opencode)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = OpenCodeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
            XCTAssertEqual(full.source, .opencode)
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testOpenClawFixturesParse() throws {
        let smallURL = FixturePaths.stage0FixtureURL("agents/openclaw/small.jsonl")
        guard let smallPreview = OpenClawSessionParser.parseFile(at: smallURL) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(smallPreview.source, .openclaw)
        XCTAssertTrue(smallPreview.events.isEmpty)
        XCTAssertGreaterThan(smallPreview.eventCount, 0)
        XCTAssertEqual(smallPreview.model, "openclaw-small")

        guard let smallFull = OpenClawSessionParser.parseFileFull(at: smallURL) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(smallFull.source, .openclaw)
        XCTAssertFalse(smallFull.events.isEmpty)
        XCTAssertTrue(smallFull.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(smallFull.events.contains(where: { $0.kind == .tool_result }))

        for name in ["agents/openclaw/large.jsonl", "agents/openclaw/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = OpenClawSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .openclaw)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = OpenClawSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .openclaw)
            XCTAssertFalse(full.events.isEmpty)
            XCTAssertTrue(full.events.contains { $0.kind == .tool_call || $0.kind == .assistant })
        }
    }

    func testOpenClawParserHandlesCaseAndSnakeCaseVariants() throws {
        let jsonl = """
        {"type":"session","id":"openclaw-variant","version":3,"timestamp":"2026-02-24T13:00:00Z","cwd":"/tmp"}
        {"type":"message","id":"m1","timestamp":"2026-02-24T13:00:01Z","message":{"role":"user","content":[{"type":"text","text":"Run shell status"}]}}
        {"type":"message","id":"m2","timestamp":"2026-02-24T13:00:02Z","message":{"role":"assistant","content":[{"type":"TOOL_CALL","id":"tc1","name":"shell","arguments":{"command":"pwd"}}]}}
        {"type":"message","id":"m3","timestamp":"2026-02-24T13:00:03Z","message":{"role":"tool_result","tool_call_id":"tc1","tool_name":"shell","content":"ok","isError":false}}
        {"type":"message","id":"m4","timestamp":"2026-02-24T13:00:04Z","message":{"role":"tool_result","tool_call_id":"tc2","tool_name":"shell","content":"failed","is_error":true}}
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (jsonl + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let full = OpenClawSessionParser.parseFileFull(at: url) else { return XCTFail("openclaw variant parse nil") }
        let toolCalls = full.events.filter { $0.kind == .tool_call }
        let toolResults = full.events.filter { $0.kind == .tool_result }
        let errors = full.events.filter { $0.kind == .error }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "shell")
        XCTAssertEqual(toolResults.first?.toolName, "shell")
        XCTAssertEqual(errors.first?.toolName, "shell")
    }

    // MARK: - Helpers

    private func metaEvents(withType type: String, in events: [SessionEvent]) -> [SessionEvent] {
        metaEvents(containing: "\"type\":\"\(type)\"", in: events)
    }

    private func metaEvents(containing needle: String, in events: [SessionEvent]) -> [SessionEvent] {
        events.filter { event in
            guard event.kind == .meta, let data = Data(base64Encoded: event.rawJSON),
                  let decoded = String(data: data, encoding: .utf8) else { return false }
            return decoded.contains(needle)
        }
    }
}
