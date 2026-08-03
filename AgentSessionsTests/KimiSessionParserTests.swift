import XCTest
@testable import AgentSessions

/// Fixtures are an authentic capture from Kimi Code CLI 0.29.1
/// (`~/.kimi-code/sessions/<wd_bucket>/<sessionId>/`). Only the 71KB tools
/// snapshot and the 25KB system prompt were trimmed; every op line is real.
final class KimiSessionParserTests: XCTestCase {
    /// Stages the fixture into the real on-disk layout so the parser exercises
    /// its session-id derivation and its `state.json` sidecar join.
    private func stagedFixture() throws -> URL {
        try stagedFixture(wire: "small.jsonl",
                          state: "state.json",
                          sessionID: "session_9eb1bf57-c1af-48a5-b658-0e8d9fe794f5")
    }

    /// A second authentic capture, taken on a funded account, that actually
    /// exercises the model's own output: 6 assistant replies, 19 tool calls
    /// across 8 tools, a failed `Bash`, plan mode, and a compaction.
    private func stagedAssistantToolsFixture() throws -> URL {
        try stagedFixture(wire: "assistant_tools.jsonl",
                          state: "assistant_tools.state.json",
                          sessionID: "session_1bcbe023-4f7e-4971-9dc9-43b8756045b0")
    }

    private func stagedFixture(wire: String, state: String, sessionID: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kimi-fixture-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root
            .appendingPathComponent("sessions/wd_project_ac3bb318f98e", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let mainDir = sessionDir.appendingPathComponent("agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = repoRoot.appendingPathComponent("Resources/Fixtures/stage0/agents/kimi")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(wire),
                                         to: mainDir.appendingPathComponent("wire.jsonl"))
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(state),
                                         to: sessionDir.appendingPathComponent("state.json"))

        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return mainDir.appendingPathComponent("wire.jsonl")
    }

    func testParseFileDerivesIDAndJoinsSidecar() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: stagedFixture()))

        XCTAssertEqual(session.id, "session_9eb1bf57-c1af-48a5-b658-0e8d9fe794f5")
        XCTAssertEqual(session.source, .kimi)
        XCTAssertEqual(session.surface, .cli)
        XCTAssertEqual(session.lightweightCwd, "/private/tmp/as-agent-lab/kimi/project")
        XCTAssertEqual(session.repoName, "project")
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
        XCTAssertEqual(start.timeIntervalSince1970, 1784950509.920, accuracy: 0.002)
        XCTAssertLessThanOrEqual(start, end)
    }

    func testParseFileFullBuildsUserEventsFromAppendMessageOps() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        let users = session.events.filter { $0.kind == .user }
        XCTAssertEqual(users.count, 3, "fixture has exactly 3 context.append_message user ops")
        XCTAssertEqual(users.compactMap(\.text), ["hi", "hi", "stop"])
    }

    /// `turn.prompt` duplicates the text of its `context.append_message`. It must
    /// resolve to `.meta` so prompts are not counted or rendered twice.
    func testTurnPromptDoesNotDuplicateUserMessages() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        let prompts = session.events.filter { $0.rawJSON.contains("\"type\":\"turn.prompt\"") }
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts.allSatisfy { $0.kind == .meta })
    }

    /// Every op family the fixture contains that carries no renderable content
    /// must survive as `.meta` rather than being dropped.
    ///
    /// `context.append_loop_event` qualifies *only for this fixture*, whose two
    /// loop events are both `step.begin`. That family is content-bearing in
    /// general — see the assistant/tool tests below.
    func testNonMessageOpFamiliesSurviveAsMeta() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        for family in ["metadata", "tools.set_active_tools", "llm.request",
                       "llm.tools_snapshot", "turn.steer", "turn.cancel",
                       "context.append_loop_event", "permission.set_mode"] {
            let matches = session.events.filter { $0.rawJSON.contains("\"type\":\"\(family)\"") }
            XCTAssertFalse(matches.isEmpty, "fixture should contain \(family)")
            XCTAssertTrue(matches.allSatisfy { $0.kind == .meta }, "\(family) must resolve to .meta")
        }
    }

    func testUnknownFutureOpTypeSurvivesAsMeta() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"kimi.future_event","somethingNew":{"a":1},"time":1784950713999}"# + "\n").utf8))
        try handle.close()

        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: wire))

        let drift = session.events.filter { $0.rawJSON.contains("kimi.future_event") }
        XCTAssertEqual(drift.count, 1)
        XCTAssertEqual(drift.first?.kind, .meta)
    }

    func testEventCountExcludesMetaOps() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        XCTAssertEqual(session.eventCount, 3, "only the 3 user messages are non-meta")
    }

    /// The preview pass discards its events, so `lightweightCommands` is the only
    /// tool-call evidence the "has commands" quick filter has for a session the
    /// user has not opened -- which is every row in the list. When this was nil,
    /// the filter judged every Kimi session command-free and hid the provider
    /// wholesale.
    func testPreviewParseCountsToolCallsForTheHasCommandsFilter() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: stagedAssistantToolsFixture()))

        XCTAssertTrue(session.events.isEmpty, "preview parse must not materialise events")
        XCTAssertEqual(session.lightweightCommands, 19, "the capture makes 19 tool calls")
        XCTAssertTrue(UnifiedSessionIndexer.passesHasCommandsFilter(session))
    }

    /// The counterpart: a capture with no tool calls must still read as
    /// command-free, or the filter becomes a no-op for Kimi. The count stays
    /// nil rather than 0 because the preview only reads the first
    /// `previewLineLimit` lines — "none found so far" is not "none".
    func testPreviewParseReportsNoCommandsForAToolFreeCapture() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: stagedFixture()))

        XCTAssertNil(session.lightweightCommands)
        XCTAssertFalse(UnifiedSessionIndexer.passesHasCommandsFilter(session))
    }

    /// The checked-in capture is exactly `previewLineLimit` lines long with its
    /// last tool call at line 185, so the count test above passes *at* the cap
    /// and says nothing about what happens past it. This pushes the tool calls
    /// beyond the cap: the preview must report nil (it stopped reading before
    /// reaching them, so "none found" is not "none"), while the full parse still
    /// finds them. A `0` here instead of nil would be a positive claim the
    /// preview cannot support, and would short-circuit deep scan.
    func testPreviewTruncationReportsUnknownRatherThanZeroCommands() throws {
        let wire = try stagedAssistantToolsFixture()
        let original = try String(contentsOf: wire, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let envelope = try XCTUnwrap(original.first)
        let toolCallLines = original.filter { $0.contains("\"tool.call\"") }
        XCTAssertFalse(toolCallLines.isEmpty, "fixture must contain tool calls to push past the cap")

        // A real op family, matching the "every fixture line is a real op"
        // convention, and comfortably past `previewLineLimit` (200).
        let filler = (0..<250).map { i in
            "{\"type\":\"llm.request\",\"modelAlias\":\"moonshot-ai/kimi-k2.7-code\",\"model\":\"kimi-k2.7-code\",\"seq\":\(i),\"time\":1750000000000}"
        }
        try ([envelope] + filler + toolCallLines).joined(separator: "\n")
            .appending("\n")
            .write(to: wire, atomically: true, encoding: .utf8)

        let preview = try XCTUnwrap(KimiSessionParser.parseFile(at: wire))
        XCTAssertNil(preview.lightweightCommands, "preview stopped before the tool calls; it cannot claim zero")
        XCTAssertFalse(UnifiedSessionIndexer.passesHasCommandsFilter(preview))

        let full = try XCTUnwrap(KimiSessionParser.parseFileFull(at: wire))
        XCTAssertTrue(full.hasToolCallEvent, "the full parse reads past the cap and must find them")
    }

    /// The working directory must survive a *full* parse, not just the preview:
    /// `effectiveWorkingDirectoryURL` routes Kimi through `Session.cwd`, and a
    /// nil there is what dropped the `cd` from the resume command.
    func testFullParseKeepsTheSidecarWorkingDirectory() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedAssistantToolsFixture()))

        XCTAssertFalse(session.events.isEmpty, "must be exercising the parsed path")
        XCTAssertEqual(session.cwd, session.lightweightCwd)
        XCTAssertNotNil(session.cwd)
    }

    /// The preview path streams and stops at its line cap, so it must succeed on
    /// a journal far larger than the full-parse ceiling without materialising it.
    /// A regression here (slurping the file) would show up as a stall on every
    /// scan, since parseLightweight runs over every discovered session.
    func testPreviewParseHandlesJournalLargerThanFullParseCeiling() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.seekToEnd()
        let filler = (#"{"type":"llm.request","kind":"loop","time":1784950600000}"# + "\n").data(using: .utf8)!
        for _ in 0..<400 { try handle.write(contentsOf: filler) }
        try handle.truncate(atOffset: UInt64(KimiSessionParser.defaultFullParseMaxBytes + 1))
        try handle.close()

        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: wire))

        XCTAssertEqual(session.id, "session_9eb1bf57-c1af-48a5-b658-0e8d9fe794f5")
        XCTAssertEqual(session.lightweightCwd, "/private/tmp/as-agent-lab/kimi/project")
    }

    func testParseFileFullSkipsOversizedFileUnlessExplicitlyAllowed() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.truncate(atOffset: UInt64(KimiSessionParser.defaultFullParseMaxBytes + 1))
        try handle.close()

        XCTAssertNil(KimiSessionParser.parseFileFull(at: wire))
        XCTAssertEqual(KimiSessionParser.parseFileFull(at: wire, allowLargeFile: true)?.id,
                       "session_9eb1bf57-c1af-48a5-b658-0e8d9fe794f5")
    }

    // MARK: - Assistant and tool paths (context.append_loop_event)
    //
    // Regression cover for a parser defect found 2026-08-01: Kimi puts user
    // turns in `context.append_message` but every assistant reply and every
    // tool call in `context.append_loop_event`. A parser reading only the
    // former renders Kimi sessions as user turns alone — this fixture's session
    // surfaced 13 of its 57 real events, and Analytics counted only the 13.

    func testAssistantRepliesComeFromLoopContentParts() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedAssistantToolsFixture()))

        let assistant = session.events.filter { $0.kind == .assistant }
        XCTAssertEqual(assistant.count, 6, "fixture has 6 content.part text parts")
        XCTAssertEqual(assistant.first?.text, "Hi there! How can I help you today?")
        XCTAssertTrue(assistant.allSatisfy { $0.role == "assistant" })
    }

    /// `think` parts are reasoning, not answer text. They must not reach the
    /// transcript body — otherwise the model's private scratchpad renders as a
    /// reply and every assistant count is inflated.
    func testThinkPartsAreNotRenderedAsAssistantText() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedAssistantToolsFixture()))

        let think = session.events.filter { $0.rawJSON.contains("\"type\":\"think\"") }
        XCTAssertEqual(think.count, 22, "fixture has 22 think parts")
        XCTAssertTrue(think.allSatisfy { $0.kind == .meta })
        XCTAssertTrue(session.events.filter { $0.kind == .assistant }
            .allSatisfy { !($0.text ?? "").contains("The user has sent three") })
    }

    func testToolCallsCarryNameAndSerialisedArguments() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedAssistantToolsFixture()))

        let calls = session.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(calls.count, 19)
        XCTAssertEqual(Set(calls.compactMap(\.toolName)),
                       ["Bash", "Agent", "Glob", "Write", "ExitPlanMode", "Read", "Grep"])

        let firstBash = try XCTUnwrap(calls.first { $0.messageID == "Bash_0" })
        XCTAssertEqual(firstBash.toolName, "Bash")
        XCTAssertEqual(firstBash.toolInput, #"{"command":"ls"}"#)
    }

    /// The result's `toolCallId` is what pairs it back to its call, so a
    /// transcript can render them together.
    func testToolResultsCarryOutputAndPairWithTheirCall() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedAssistantToolsFixture()))

        let results = session.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.count, 18, "19 tool.results, one of which is an error")

        let callIDs = Set(session.events.filter { $0.kind == .tool_call }.compactMap(\.messageID))
        let resultIDs = Set(results.compactMap(\.messageID))
        XCTAssertTrue(resultIDs.isSubset(of: callIDs), "every result pairs with a call")

        let firstBash = try XCTUnwrap(results.first { $0.messageID == "Bash_0" })
        XCTAssertEqual(firstBash.toolInput, nil)
        XCTAssertTrue(try XCTUnwrap(firstBash.toolOutput).contains("AgentSessions"))
    }

    /// Failure is flagged by a nested `result.isError`, never at the event's top
    /// level — a parser checking the outer object silently classifies every
    /// failed tool run as a success.
    func testFailedToolResultBecomesErrorEvent() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedAssistantToolsFixture()))

        let errors = session.events.filter { $0.kind == .error }
        XCTAssertEqual(errors.count, 1)
        let failure = try XCTUnwrap(errors.first)
        XCTAssertEqual(failure.messageID, "Bash_2")
        XCTAssertTrue(try XCTUnwrap(failure.toolOutput).contains("No such file or directory"))
    }

    /// `step.begin`/`step.end` bracket the model's work but carry nothing
    /// renderable, so they must stay `.meta` even though their family is
    /// content-bearing.
    func testStepBracketsAndNewOpFamiliesStayMeta() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedAssistantToolsFixture()))

        for marker in ["\"type\":\"step.begin\"", "\"type\":\"step.end\""] {
            let matches = session.events.filter { $0.rawJSON.contains(marker) }
            XCTAssertFalse(matches.isEmpty, "fixture should contain \(marker)")
            XCTAssertTrue(matches.allSatisfy { $0.kind == .meta }, "\(marker) must resolve to .meta")
        }

        for family in ["usage.record", "permission.record_approval_result",
                       "plan_mode.enter", "plan_mode.exit", "full_compaction.begin",
                       "context.apply_compaction", "full_compaction.complete"] {
            let matches = session.events.filter { $0.rawJSON.contains("\"type\":\"\(family)\"") }
            XCTAssertFalse(matches.isEmpty, "fixture should contain \(family)")
            XCTAssertTrue(matches.allSatisfy { $0.kind == .meta }, "\(family) must resolve to .meta")
        }
    }

    /// The count that reaches Analytics. Before loop events were parsed this
    /// session reported 13 — its user turns alone.
    func testEventCountIncludesAssistantAndToolEvents() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedAssistantToolsFixture()))

        // 13 = 8 human prompts (one per turn.prompt) + 5 injected <system-reminder>
        // notices. Kimi appends those as ordinary user messages, and AS classifies
        // them the same way Claude's are — this is not a human-prompt count.
        let users = session.events.filter { $0.kind == .user }.count
        XCTAssertEqual(users, 13)
        XCTAssertEqual(session.eventCount, 57, "13 user + 6 assistant + 19 call + 18 result + 1 error")
    }

    /// The fixture is exactly `previewLineLimit` (200) lines, so the preview path
    /// currently sees all of it. Appending drift lines here — the convention used
    /// on `small.jsonl` — would push them past the cap, where `parseFileFull` and
    /// the weekly scan still see them but `parseFile` silently does not. This
    /// pins the two paths together so that divergence fails loudly instead.
    func testPreviewAndFullParseAgreeAtThePreviewLineCap() throws {
        let wire = try stagedAssistantToolsFixture()

        let preview = try XCTUnwrap(KimiSessionParser.parseFile(at: wire))
        let full = try XCTUnwrap(KimiSessionParser.parseFileFull(at: wire))

        XCTAssertEqual(preview.eventCount, full.eventCount,
                       "fixture grew past previewLineLimit — append drift lines to small.jsonl instead")
    }

    func testAssistantToolsFixtureResolvesIdentityAndModel() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: stagedAssistantToolsFixture()))

        XCTAssertEqual(session.id, "session_1bcbe023-4f7e-4971-9dc9-43b8756045b0")
        XCTAssertEqual(session.model, "kimi-k2.7-code")
        XCTAssertEqual(session.lightweightCwd, "/private/tmp/as-agent-lab/kimi/project")
    }

    /// Subagent journals live beside the main one at `agents/<agentId>/wire.jsonl`
    /// and use the identical schema — the `Agent` tool call in the
    /// assistant-tools capture produced this one. Discovery excludes them from
    /// the session list by design, but the parser must still read one correctly
    /// if handed the path. The id it derives is the *parent* session's, because
    /// the id comes from the session directory two levels above `agents/`.
    func testSubagentJournalParsesWithTheParentSessionID() throws {
        let wire = try stagedAssistantToolsFixture()
        let agentDir = wire.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agent-0", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: repoRoot.appendingPathComponent("Resources/Fixtures/stage0/agents/kimi/subagent_agent-0.jsonl"),
            to: agentDir.appendingPathComponent("wire.jsonl"))

        let subagent = try XCTUnwrap(
            KimiSessionParser.parseFileFull(at: agentDir.appendingPathComponent("wire.jsonl")))

        XCTAssertEqual(subagent.id, "session_1bcbe023-4f7e-4971-9dc9-43b8756045b0")
        XCTAssertTrue(subagent.events.contains { $0.kind == .assistant })
        XCTAssertTrue(subagent.events.contains { $0.kind == .tool_call })
    }

    func testRejectsFileOutsideTheAgentsLayout() {
        let stray = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wire.jsonl")
        XCTAssertNil(KimiSessionParser.parseFile(at: stray))
    }
}
