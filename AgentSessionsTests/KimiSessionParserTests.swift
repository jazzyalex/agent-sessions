import XCTest
@testable import AgentSessions

/// Fixtures are an authentic capture from Kimi Code CLI 0.29.2
/// (`~/.kimi-code/sessions/<wd_bucket>/<sessionId>/`). Only the tools snapshot
/// and system prompt were trimmed and `$HOME` was rewritten to `/Users/fixture`;
/// every op line is otherwise real.
final class KimiSessionParserTests: XCTestCase {
    private let fixtureSessionID = "session_1bcbe023-4f7e-4971-9dc9-43b8756045b0"

    /// Stages the fixture into the real on-disk layout so the parser exercises
    /// its session-id derivation and its `state.json` sidecar join.
    private func stagedFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kimi-fixture-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root
            .appendingPathComponent("sessions/wd_codex-history_205016864bd1", isDirectory: true)
            .appendingPathComponent(fixtureSessionID, isDirectory: true)
        let mainDir = sessionDir.appendingPathComponent("agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = repoRoot.appendingPathComponent("Resources/Fixtures/stage0/agents/kimi")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("small.jsonl"),
                                         to: mainDir.appendingPathComponent("wire.jsonl"))
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("state.json"),
                                         to: sessionDir.appendingPathComponent("state.json"))

        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return mainDir.appendingPathComponent("wire.jsonl")
    }

    func testParseFileDerivesIDAndJoinsSidecar() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: stagedFixture()))

        XCTAssertEqual(session.id, fixtureSessionID)
        XCTAssertEqual(session.source, .kimi)
        XCTAssertEqual(session.surface, .cli)
        XCTAssertEqual(session.lightweightCwd, "/Users/fixture/Repository/Codex-History")
        XCTAssertEqual(session.repoName, "Codex-History")
        XCTAssertEqual(session.lightweightTitle, "hi")
        XCTAssertTrue(session.events.isEmpty, "lightweight parse must not materialise events")
    }

    /// Regression: real `config.update` ops carry `modelAlias`, never a bare
    /// `model`. An earlier implementation looked only for `model`/`config.model`
    /// and silently produced a nil model for every Kimi session.
    func testResolvesModelFromModelAliasNotBareModelKey() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: stagedFixture()))

        XCTAssertEqual(session.model, "kimi-k2.7-code")
    }

    func testTimestampsComeFromEpochMilliseconds() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: stagedFixture()))

        let start = try XCTUnwrap(session.startTime)
        let end = try XCTUnwrap(session.endTime)
        XCTAssertEqual(start.timeIntervalSince1970, 1785612803.281, accuracy: 0.002)
        XCTAssertLessThanOrEqual(start, end)
    }

    func testUserTurnsComeFromAppendMessageOps() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        let users = session.events.filter { $0.kind == .user }
        XCTAssertEqual(users.count, 13)
        XCTAssertEqual(users.prefix(5).compactMap(\.text),
                       ["hi", "hi", "hi", "run ls command", "cat /nonexistent-file-xyz"])
    }

    /// REGRESSION — the defect a fixture without assistant output concealed.
    /// The agent loop streams its answer as `context.append_loop_event` /
    /// `content.part`, NOT as `context.append_message`. Mapping that family to
    /// `.meta` renders a transcript containing the user's prompts and nothing
    /// else.
    func testAssistantAnswerComesFromLoopContentParts() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        let assistant = session.events.filter { $0.kind == .assistant }
        XCTAssertEqual(assistant.count, 6)
        XCTAssertEqual(assistant.first?.text, "Hi there! How can I help you today?")
        XCTAssertTrue(assistant.contains { $0.text?.contains("output of `ls`") == true })
    }

    /// `think` parts are reasoning, not the answer, and must stay out of the
    /// rendered body — otherwise the model's private deliberation is shown as
    /// if it were the reply.
    func testThinkPartsAreNotRenderedAsAssistantText() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        XCTAssertFalse(session.events.contains { $0.kind == .assistant && $0.text?.contains("The user has sent") == true })
        let thinkLines = session.events.filter { $0.rawJSON.contains("\"type\":\"think\"") }
        XCTAssertFalse(thinkLines.isEmpty, "fixture should contain think parts")
        XCTAssertTrue(thinkLines.allSatisfy { $0.kind == .meta })
    }

    func testToolCallsAndResultsComeFromLoopEvents() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        let calls = session.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(calls.count, 19)
        XCTAssertEqual(Set(calls.compactMap(\.toolName)),
                       ["Bash", "Agent", "Glob", "Write", "ExitPlanMode", "Read", "Grep"])
        XCTAssertEqual(calls.first?.toolName, "Bash")
        XCTAssertEqual(calls.first?.toolInput, #"{"command":"ls"}"#)
        XCTAssertEqual(calls.first?.messageID, "Bash_0")

        let results = session.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.count, 18, "19 results, one of which failed and becomes .error")
        XCTAssertEqual(results.first?.messageID, "Bash_0")
        XCTAssertTrue(results.first?.toolOutput?.contains("AgentSessions.xcodeproj") == true)
    }

    /// A failed tool must surface as `.error`, not as an ordinary result —
    /// otherwise `cat /nonexistent-file-xyz` reads in the transcript as though
    /// it succeeded and returned the error text.
    func testFailedToolResultBecomesErrorEvent() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        let errors = session.events.filter { $0.kind == .error }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.messageID, "Bash_2")
        XCTAssertNotNil(errors.first?.toolOutput)
    }

    /// Plan mode and compaction are session-level bookkeeping: they carry no
    /// renderable content and must not be mistaken for conversation.
    func testPlanModeAndCompactionFamiliesStayMeta() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        for family in ["plan_mode.enter", "plan_mode.exit", "full_compaction.begin",
                       "full_compaction.complete", "context.apply_compaction"] {
            let matches = session.events.filter { $0.rawJSON.contains("\"type\":\"\(family)\"") }
            XCTAssertFalse(matches.isEmpty, "fixture should contain \(family)")
            XCTAssertTrue(matches.allSatisfy { $0.kind == .meta }, "\(family) must resolve to .meta")
        }
    }

    /// Subagent journals live beside the main one at `agents/<agentId>/wire.jsonl`
    /// and use the identical schema. Discovery excludes them from the session
    /// list, but the parser must still read one correctly if handed the path —
    /// the id it derives is the parent session's, since the id comes from the
    /// session directory two levels up.
    func testSubagentJournalParsesWithTheParentSessionID() throws {
        let wire = try stagedFixture()
        let agentDir = wire.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agent-0", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: repoRoot.appendingPathComponent("Resources/Fixtures/stage0/agents/kimi/subagent_agent-0.jsonl"),
            to: agentDir.appendingPathComponent("wire.jsonl"))

        let subagent = try XCTUnwrap(
            KimiSessionParser.parseFileFull(at: agentDir.appendingPathComponent("wire.jsonl")))

        XCTAssertEqual(subagent.id, fixtureSessionID)
        XCTAssertTrue(subagent.events.contains { $0.kind == .tool_call })
        XCTAssertTrue(subagent.events.contains { $0.kind == .assistant })
    }

    /// A tool_call event is what drives `Session.hasToolCallEvent`, which the
    /// commands-only filters key off.
    func testSessionReportsHavingToolCalls() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        XCTAssertTrue(session.hasToolCallEvent)
    }

    /// Every op family the fixture contains that carries no renderable content
    /// must survive as `.meta` rather than being dropped.
    func testNonMessageOpFamiliesSurviveAsMeta() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        for family in ["metadata", "tools.set_active_tools", "llm.request",
                       "llm.tools_snapshot", "turn.prompt", "usage.record",
                       "permission.record_approval_result"] {
            let matches = session.events.filter { $0.rawJSON.contains("\"type\":\"\(family)\"") }
            XCTAssertFalse(matches.isEmpty, "fixture should contain \(family)")
            XCTAssertTrue(matches.allSatisfy { $0.kind == .meta }, "\(family) must resolve to .meta")
        }
    }

    /// `turn.prompt` duplicates the text of its `context.append_message`. It must
    /// resolve to `.meta` so prompts are not counted or rendered twice.
    func testTurnPromptDoesNotDuplicateUserMessages() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        let prompts = session.events.filter { $0.rawJSON.contains("\"type\":\"turn.prompt\"") }
        XCTAssertEqual(prompts.count, 8)
        XCTAssertTrue(prompts.allSatisfy { $0.kind == .meta })
    }

    /// step.begin/step.end are loop bookkeeping and carry no renderable content.
    func testLoopBookkeepingEventsStayMeta() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        for family in ["step.begin", "step.end"] {
            let matches = session.events.filter { $0.rawJSON.contains("\"type\":\"\(family)\"") }
            XCTAssertFalse(matches.isEmpty, "fixture should contain \(family)")
            XCTAssertTrue(matches.allSatisfy { $0.kind == .meta })
        }
    }

    func testUnknownFutureOpTypeSurvivesAsMeta() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"kimi.future_event","somethingNew":{"a":1},"time":1785612899999}"# + "\n").utf8))
        try handle.close()

        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: wire))

        let drift = session.events.filter { $0.rawJSON.contains("kimi.future_event") }
        XCTAssertEqual(drift.count, 1)
        XCTAssertEqual(drift.first?.kind, .meta)
    }

    /// An unknown *loop* event must also degrade to .meta rather than being
    /// mistaken for content.
    func testUnknownLoopEventSurvivesAsMeta() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"context.append_loop_event","event":{"type":"kimi.future_loop"},"time":1785612899998}"# + "\n").utf8))
        try handle.close()

        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: wire))

        let drift = session.events.filter { $0.rawJSON.contains("kimi.future_loop") }
        XCTAssertEqual(drift.count, 1)
        XCTAssertEqual(drift.first?.kind, .meta)
    }

    func testEventCountExcludesMetaOps() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        // 13 user + 6 assistant + 19 tool_call + 18 tool_result + 1 error
        XCTAssertEqual(session.eventCount, 57)
    }

    /// The preview path streams and stops at its line cap, so it must succeed on
    /// a journal far larger than the full-parse ceiling without materialising it.
    /// A regression here (slurping the file) would show up as a stall on every
    /// scan, since parseLightweight runs over every discovered session.
    func testPreviewParseHandlesJournalLargerThanFullParseCeiling() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.seekToEnd()
        let filler = (#"{"type":"llm.request","kind":"loop","time":1785612899000}"# + "\n").data(using: .utf8)!
        for _ in 0..<400 { try handle.write(contentsOf: filler) }
        try handle.truncate(atOffset: UInt64(KimiSessionParser.defaultFullParseMaxBytes + 1))
        try handle.close()

        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: wire))

        XCTAssertEqual(session.id, fixtureSessionID)
        XCTAssertEqual(session.lightweightCwd, "/Users/fixture/Repository/Codex-History")
    }

    func testParseFileFullSkipsOversizedFileUnlessExplicitlyAllowed() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.truncate(atOffset: UInt64(KimiSessionParser.defaultFullParseMaxBytes + 1))
        try handle.close()

        XCTAssertNil(KimiSessionParser.parseFileFull(at: wire))
        XCTAssertEqual(KimiSessionParser.parseFileFull(at: wire, allowLargeFile: true)?.id, fixtureSessionID)
    }

    func testRejectsFileOutsideTheAgentsLayout() {
        let stray = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wire.jsonl")
        XCTAssertNil(KimiSessionParser.parseFile(at: stray))
    }
}
