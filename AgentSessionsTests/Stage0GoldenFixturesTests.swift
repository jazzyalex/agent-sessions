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
}

