import XCTest
@testable import AgentSessions

/// The fixture reproduces the Grok CLI 1.0.0 transcript schema
/// (`chat_format_version: 1`) as verified by `scripts/grok_chat_schema_probe.py`
/// across 141 real sessions: every record type the parser handles is present,
/// including a synthetic `user` turn, a `backend_tool_call`, an assistant reply
/// with an empty `content` but live `tool_calls`, and an image content part.
final class GrokSessionParserTests: XCTestCase {
    private let sessionID = "019f6851-7ec4-7ef0-97d3-03f3eee38755"

    /// Stages the fixture into the real on-disk layout so the parser exercises
    /// its session-id derivation and its `summary.json` sidecar join.
    private func stagedFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grok-fixture-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            // Grok percent-encodes the working directory into the bucket name.
            .appendingPathComponent("%2Ftmp%2Fas-agent-lab%2Fgrok%2Fproject", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = repoRoot.appendingPathComponent("Resources/Fixtures/stage0/agents/grok")
        for name in ["chat_history.jsonl", "summary.json"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name),
                                             to: sessionDir.appendingPathComponent(name))
        }

        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return sessionDir.appendingPathComponent("chat_history.jsonl")
    }

    func testParsesIdentityFromSidecar() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.source, .grok)
        XCTAssertEqual(session.model, "grok-4.5")
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-agent-lab/grok/project")
        XCTAssertEqual(session.lightweightRepoName, "project")
        XCTAssertEqual(session.reasoningEffort, "high")
        XCTAssertEqual(session.surface, .cli)
    }

    /// The transcript carries no per-record time, so both bounds come from the
    /// sidecar's RFC 3339 timestamps.
    func testTimestampsComeFromSidecar() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        let start = try XCTUnwrap(session.startTime)
        let end = try XCTUnwrap(session.endTime)
        XCTAssertEqual(start.timeIntervalSince1970, 1785492807.574131, accuracy: 0.001)
        XCTAssertLessThan(start, end)
    }

    func testTitlePrefersGeneratedTitle() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))
        XCTAssertEqual(session.lightweightTitle, "Read hello.py and summarize what it prints")
    }

    func testAssistantToolCallsBecomeToolCallEvents() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        let calls = session.events.filter { $0.kind == .tool_call }
        // Two assistant tool calls plus the server-side backend_tool_call.
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.first?.toolName, "read_file")
        // `arguments` arrives as a JSON string and is passed through verbatim.
        XCTAssertEqual(calls.first?.toolInput,
                       "{\"target_file\":\"/tmp/as-agent-lab/grok/project/hello.py\"}")
        XCTAssertTrue(calls.contains { $0.toolName == "web_search" })
    }

    /// An assistant record with empty `content` still has to yield its tool
    /// calls; emitting only a meta event there would lose the call entirely.
    func testAssistantWithEmptyContentStillEmitsToolCall() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        let terminalCall = session.events.first { $0.toolName == "run_terminal_cmd" }
        XCTAssertNotNil(terminalCall)
        XCTAssertEqual(terminalCall?.kind, .tool_call)
    }

    func testToolResultsKeyBackToTheirCall() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        let results = session.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.count, 2)
        let ids = Set(results.compactMap { $0.messageID })
        XCTAssertTrue(ids.contains("call-00000000-0000-4000-8000-000000000002-0"))
        XCTAssertEqual(results.first?.toolOutput, "print(\"hello from the grok fixture\")\n")
    }

    /// Reasoning renders from `summary[].text`; `encrypted_content` is opaque
    /// and must never surface in the transcript body.
    func testReasoningRendersSummaryTextOnly() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        let thinking = session.events.filter { $0.role == "thinking" }
        XCTAssertEqual(thinking.count, 2)
        XCTAssertEqual(thinking.first?.kind, .meta)
        XCTAssertTrue(thinking.first?.text?.hasPrefix("[thinking] ") == true)
        XCTAssertFalse(session.events.contains { $0.text?.contains("<opaque>") == true })
    }

    func testUserContentPartsFlattenIncludingImages() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        let users = session.events.filter { $0.kind == .user }
        XCTAssertEqual(users.count, 3)
        XCTAssertEqual(users.last?.text, "[image]\nHere is a screenshot for reference.")
    }

    /// The preview pass must not report a truncated event count for list rows,
    /// so it takes `num_chat_messages` from the sidecar instead of counting.
    func testLightweightParseUsesSidecarMessageCount() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFile(at: url))

        XCTAssertEqual(session.eventCount, 11)
        XCTAssertTrue(session.events.isEmpty)
        XCTAssertEqual(session.lightweightCommands, 3)
    }
}
