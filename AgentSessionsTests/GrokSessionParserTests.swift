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
        let sessionDir = try makeSessionDirectory()

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = repoRoot.appendingPathComponent("Resources/Fixtures/stage0/agents/grok")
        for name in ["chat_history.jsonl", "summary.json"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name),
                                             to: sessionDir.appendingPathComponent(name))
        }

        return sessionDir.appendingPathComponent("chat_history.jsonl")
    }

    /// Stages arbitrary transcript and sidecar content into the same layout, for
    /// shapes the shared fixture deliberately does not cover.
    private func stage(transcript: String, summary: String) throws -> URL {
        let sessionDir = try makeSessionDirectory()
        let url = sessionDir.appendingPathComponent("chat_history.jsonl")
        try transcript.write(to: url, atomically: true, encoding: .utf8)
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"),
                          atomically: true,
                          encoding: .utf8)
        return url
    }

    private func makeSessionDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grok-fixture-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            // Grok percent-encodes the working directory into the bucket name.
            .appendingPathComponent("%2Ftmp%2Fas-agent-lab%2Fgrok%2Fproject", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return sessionDir
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

    /// A preview that reached EOF counted the whole transcript, so it reports its
    /// own exact non-meta total rather than the sidecar's `num_chat_messages`.
    /// The fixture's 11 records hold 9 non-meta events: the sidecar counts the
    /// `system` record and both `reasoning` records, all three of which render
    /// as meta.
    func testLightweightParseCountsNonMetaEventsWhenNotTruncated() throws {
        let url = try stagedFixture()
        let session = try XCTUnwrap(GrokSessionParser.parseFile(at: url))

        XCTAssertEqual(session.eventCount, 9)
        XCTAssertTrue(session.events.isEmpty)
        XCTAssertEqual(session.lightweightCommands, 3)

        // The list estimate must agree with what a full parse actually renders,
        // or `Session.messageCount`'s max() pins the larger number forever.
        let full = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))
        XCTAssertEqual(full.events.filter { $0.kind != .meta }.count, session.eventCount)
    }

    /// The sidecar owns the title, so loading the transcript must not override it.
    ///
    /// Grok's first `user` record is an injected `<user_info>`/`<user_query>` context
    /// preamble, not a real prompt. Title derivation used to run as soon as events were
    /// present, which produced a literal `<user_query> hi </user_query>` for a real
    /// session whose sidecar said "Triada Architecture Coupling and Module Map".
    func testSidecarTitleSurvivesAFullParse() throws {
        let transcript = """
        {"type":"user","content":[{"type":"text","text":"<user_info>\\nOS Version: macos\\n</user_info>\\n<user_query> hi </user_query>"}]}
        {"type":"assistant","content":"I'll map the repo's layout and module boundaries."}
        """
        let summary = """
        {"info":{"id":"\(sessionID)","cwd":"/tmp/as-agent-lab/grok/project"},"generated_title":"Triada Architecture Coupling and Module Map","num_chat_messages":2}
        """
        let url = try stage(transcript: transcript, summary: summary)

        let full = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))
        XCTAssertFalse(full.events.isEmpty, "guard: this must be the events-loaded path")
        XCTAssertEqual(full.title, "Triada Architecture Coupling and Module Map")

        let preview = try XCTUnwrap(GrokSessionParser.parseFile(at: url))
        XCTAssertEqual(preview.title, full.title, "opening a session must not change its title")
    }

    /// Grok records the subagent relationship in the parent's tree, never in the child's
    /// sidecar, so a fan-out otherwise lists as several unrelated top-level sessions.
    func testSubagentParentageResolvesFromTheParentTree() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grok-subagent-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: root) }

        let bucket = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("%2Ftmp%2Fas-agent-lab%2Fgrok%2Fproject", isDirectory: true)
        let parentID = "019ffca4-ef74-7a12-af00-5d758029446f"
        let childID = "019ffca9-afc8-76f1-8ddf-f1e30b218aa4"

        func writeSession(_ id: String, title: String) throws -> URL {
            let dir = bucket.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let transcript = dir.appendingPathComponent("chat_history.jsonl")
            try #"{"type":"user","content":[{"type":"text","text":"map the repo"}],"prompt_index":0}"#
                .write(to: transcript, atomically: true, encoding: .utf8)
            // Deliberately no `parent_session_id` — the real sidecars carry none.
            try #"{"info":{"id":"\#(id)","cwd":"/tmp/as-agent-lab/grok/project"},"generated_title":"\#(title)"}"#
                .write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
            return transcript
        }

        let parentTranscript = try writeSession(parentID, title: "User Initial Greeting")
        let childTranscript = try writeSession(childID, title: "Triada Architecture Coupling and Module Map")

        let metaDir = bucket
            .appendingPathComponent(parentID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(childID, isDirectory: true)
        try fm.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try #"{"parent_session_id":"\#(parentID)","child_session_id":"\#(childID)","subagent_type":"explore","description":"Architecture module map","status":"completed"}"#
            .write(to: metaDir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        let child = try XCTUnwrap(GrokSessionParser.parseFile(at: childTranscript))
        XCTAssertEqual(child.parentSessionID, parentID)
        XCTAssertEqual(child.subagentType, "explore")

        // The parent owns a `subagents/` tree but is nobody's child.
        let parent = try XCTUnwrap(GrokSessionParser.parseFile(at: parentTranscript))
        XCTAssertNil(parent.parentSessionID)
        XCTAssertNil(parent.subagentType)
    }

    /// A transcript of nothing but `system` and `reasoning` records renders no
    /// visible content, so it has to report zero messages. The sidecar's raw
    /// record count includes all three, and taking it verbatim let an empty
    /// session claim three messages and slip past the hide-zero and hide-low
    /// list filters.
    func testMetaOnlyTranscriptReportsNoMessages() throws {
        let transcript = """
        {"type":"system","content":"You are Grok."}
        {"type":"reasoning","summary":[{"text":"Considering the request."}]}
        {"type":"reasoning","summary":[{"text":"Still considering."}]}
        """
        let summary = """
        {"info":{"id":"\(sessionID)","cwd":"/tmp/as-agent-lab/grok/project"},"num_chat_messages":3}
        """
        let url = try stage(transcript: transcript, summary: summary)
        let session = try XCTUnwrap(GrokSessionParser.parseFile(at: url))

        XCTAssertEqual(session.eventCount, 0)
        XCTAssertEqual(session.messageCount, 0)
    }
}
