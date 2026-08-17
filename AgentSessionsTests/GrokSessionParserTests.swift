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

    // MARK: - Format drift tolerance
    //
    // Grok used to be the one parser that decoded its sidecar through a Codable
    // struct, so a single vendor change to one field's type threw and took the
    // whole sidecar with it. These pin the alert-not-crash contract the other
    // twelve agents already had: unknown additions are ignored, and a field that
    // goes missing or changes shape costs exactly that field.

    /// A vendor adding keys — to the sidecar and to transcript records alike —
    /// must parse byte-identically to the same session without them.
    func testUnknownNewFieldsAreIgnored() throws {
        let baselineTranscript = """
        {"type":"user","content":[{"type":"text","text":"map the repo"}],"prompt_index":0}
        {"type":"assistant","content":"Mapping.","tool_calls":[{"id":"call-1","name":"read_file","arguments":"{\\"target_file\\":\\"/tmp/x\\"}"}]}
        {"type":"tool_result","content":"ok","tool_call_id":"call-1"}
        """
        let driftedTranscript = """
        {"type":"user","content":[{"type":"text","text":"map the repo","brand_new_part_key":1}],"prompt_index":0,"brand_new_key":{"a":[1,2]}}
        {"type":"assistant","content":"Mapping.","tool_calls":[{"id":"call-1","name":"read_file","arguments":"{\\"target_file\\":\\"/tmp/x\\"}","brand_new_call_key":true}],"brand_new_key":"x"}
        {"type":"tool_result","content":"ok","tool_call_id":"call-1","brand_new_key":[]}
        """
        let baselineSummary = """
        {"info":{"id":"\(sessionID)","cwd":"/tmp/as-agent-lab/grok/project"},"generated_title":"Repo map","created_at":"2026-07-31T10:13:27.574131Z","updated_at":"2026-07-31T10:20:00.000000Z","current_model_id":"grok-4.5","num_chat_messages":3}
        """
        let driftedSummary = """
        {"info":{"id":"\(sessionID)","cwd":"/tmp/as-agent-lab/grok/project","brand_new_info_key":7},"generated_title":"Repo map","created_at":"2026-07-31T10:13:27.574131Z","updated_at":"2026-07-31T10:20:00.000000Z","current_model_id":"grok-4.5","num_chat_messages":3,"brand_new_top_key":{"nested":"value"}}
        """

        let baseline = try XCTUnwrap(GrokSessionParser.parseFileFull(at: stage(transcript: baselineTranscript, summary: baselineSummary)))
        let drifted = try XCTUnwrap(GrokSessionParser.parseFileFull(at: stage(transcript: driftedTranscript, summary: driftedSummary)))

        XCTAssertEqual(drifted.id, baseline.id)
        XCTAssertEqual(drifted.title, baseline.title)
        XCTAssertEqual(drifted.model, baseline.model)
        XCTAssertEqual(drifted.lightweightCwd, baseline.lightweightCwd)
        XCTAssertEqual(drifted.startTime, baseline.startTime)
        XCTAssertEqual(drifted.endTime, baseline.endTime)
        XCTAssertEqual(drifted.eventCount, baseline.eventCount)
        XCTAssertEqual(drifted.events.map { $0.id }, baseline.events.map { $0.id })
        XCTAssertEqual(drifted.events.map { $0.kind }, baseline.events.map { $0.kind })
        XCTAssertEqual(drifted.events.map { $0.text }, baseline.events.map { $0.text })
        XCTAssertEqual(drifted.events.map { $0.toolName }, baseline.events.map { $0.toolName })
    }

    /// A sidecar field that goes missing, or arrives as a different type, costs
    /// exactly that field. Before the Codable removal a single one of these threw
    /// and the session lost its id, cwd, title, model and both timestamps at once.
    func testSidecarFieldOfTheWrongTypeCostsOnlyThatField() throws {
        let transcript = #"{"type":"user","content":[{"type":"text","text":"hi"}],"prompt_index":0}"#
        // `created_at` is now an object, `num_chat_messages` a string, and
        // `reasoning_effort` is gone entirely.
        let summary = """
        {"info":{"id":"\(sessionID)","cwd":"/tmp/as-agent-lab/grok/project"},"generated_title":"Repo map","created_at":{"iso":"2026-07-31T10:13:27.574131Z"},"updated_at":"2026-07-31T10:20:00.000000Z","current_model_id":"grok-4.5","num_chat_messages":"3"}
        """
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: stage(transcript: transcript, summary: summary)))

        // Survives: everything whose type did not change.
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.title, "Repo map")
        XCTAssertEqual(session.model, "grok-4.5")
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-agent-lab/grok/project")
        XCTAssertNotNil(session.endTime)
        XCTAssertEqual(session.events.count, 1)
        // Degrades to nil, and nothing else: the object-shaped `created_at`.
        XCTAssertNil(session.startTime)
        XCTAssertNil(session.reasoningEffort)
    }

    /// A sidecar that is unreadable, empty, or no longer a JSON object leaves the
    /// transcript fully parseable — identity falls back to the directory name.
    func testUnusableSidecarStillYieldsATranscriptSession() throws {
        let transcript = #"{"type":"user","content":[{"type":"text","text":"hi"}],"prompt_index":0}"#
        for summary in ["{}", "[]", "not json at all"] {
            let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: stage(transcript: transcript, summary: summary)),
                                        "sidecar \(summary) must not lose the session")
            XCTAssertEqual(session.id, sessionID)
            XCTAssertEqual(session.events.count, 1)
            XCTAssertEqual(session.title, "hi", "title falls back to the first genuine prompt")
            XCTAssertNil(session.startTime)
        }
    }

    /// A transcript record that loses a currently-required field degrades within
    /// the record: an untyped record is skipped, a contentless assistant still
    /// yields its tool calls, and neither aborts the session.
    func testTranscriptRecordsMissingRequiredFieldsDegradeInPlace() throws {
        let transcript = """
        {"content":[{"type":"text","text":"a record with no type at all"}],"prompt_index":0}
        {"type":"user","content":[{"type":"text","text":"real prompt"}],"prompt_index":1}
        {"type":"assistant","tool_calls":[{"id":"call-1","name":"read_file","arguments":"{}"}]}
        {"type":"assistant"}
        {"type":"tool_result","tool_call_id":"call-1"}
        """
        let summary = """
        {"info":{"id":"\(sessionID)","cwd":"/tmp/as-agent-lab/grok/project"}}
        """
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: stage(transcript: transcript, summary: summary)))

        // Line 0 (no `type`) contributes nothing; every later line keeps its own
        // line index, so ids stay pinned to physical transcript lines.
        XCTAssertEqual(session.events.map { $0.id }, ["1-u", "2-t0", "3-m", "4-r"])
        XCTAssertEqual(session.events.map { $0.kind }, [.user, .tool_call, .meta, .tool_result])
        // A contentless assistant carrying calls still emits the call...
        XCTAssertEqual(session.events[1].toolName, "read_file")
        // ...and one carrying nothing at all becomes a meta placeholder, not a drop.
        XCTAssertNil(session.events[2].text)
        // A tool_result with no `content` keeps its correlation id and yields no output.
        XCTAssertEqual(session.events[3].messageID, "call-1")
        XCTAssertNil(session.events[3].toolOutput)
        // Non-meta count: user + tool_call + tool_result.
        XCTAssertEqual(session.eventCount, 3)
        XCTAssertEqual(session.title, "real prompt")
    }
}
