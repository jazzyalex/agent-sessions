import XCTest
@testable import AgentSessions

/// Fixtures are an authentic capture from Kimi Code CLI 0.29.1
/// (`~/.kimi-code/sessions/<wd_bucket>/<sessionId>/`). Only the 71KB tools
/// snapshot and the 25KB system prompt were trimmed; every op line is real.
final class KimiSessionParserTests: XCTestCase {
    /// Stages the fixture into the real on-disk layout so the parser exercises
    /// its session-id derivation and its `state.json` sidecar join.
    private func stagedFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kimi-fixture-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root
            .appendingPathComponent("sessions/wd_project_ac3bb318f98e", isDirectory: true)
            .appendingPathComponent("session_9eb1bf57-c1af-48a5-b658-0e8d9fe794f5", isDirectory: true)
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

    func testRejectsFileOutsideTheAgentsLayout() {
        let stray = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wire.jsonl")
        XCTAssertNil(KimiSessionParser.parseFile(at: stray))
    }
}
