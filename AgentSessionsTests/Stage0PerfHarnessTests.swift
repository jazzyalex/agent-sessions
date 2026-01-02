import XCTest
@testable import AgentSessions

final class Stage0PerfHarnessTests: XCTestCase {
    func testStage0PerfHarness() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTSESSIONS_PERF"] == "1")

        let codexURL = FixturePaths.stage0FixtureURL("agents/codex/large.jsonl")
        let claudeURL = FixturePaths.stage0FixtureURL("agents/claude/large.jsonl")
        let geminiURL = FixturePaths.stage0FixtureURL("agents/gemini/large.json")
        let opencodeURL = FixturePaths.stage0FixtureURL("agents/opencode/storage_v2/session/proj_test/ses_s_stage0_large.json")
        let copilotURL = FixturePaths.stage0FixtureURL("agents/copilot/large.jsonl")
        let droidURL = FixturePaths.stage0FixtureURL("agents/droid/stream_json_large.jsonl")

        let clock = ContinuousClock()

        var sessions: [Session] = []
        sessions.reserveCapacity(6)

        let parseStart = clock.now
        do {
            let idx = SessionIndexer()
            if let s = idx.parseFileFull(at: codexURL) { sessions.append(s) }
            if let s = ClaudeSessionParser.parseFileFull(at: claudeURL) { sessions.append(s) }
            if let s = GeminiSessionParser.parseFileFull(at: geminiURL) { sessions.append(s) }
            if let s = OpenCodeSessionParser.parseFileFull(at: opencodeURL) { sessions.append(s) }
            if let s = CopilotSessionParser.parseFileFull(at: copilotURL) { sessions.append(s) }
            if let s = DroidSessionParser.parseFileFull(at: droidURL) { sessions.append(s) }
        }
        let parseElapsed = clock.now - parseStart
        XCTAssertGreaterThan(sessions.count, 0)

        // Search: run a representative query over the parsed corpus.
        let searchStart = clock.now
        let filters = Filters(query: "line2",
                              dateFrom: nil,
                              dateTo: nil,
                              model: nil,
                              kinds: Set(SessionEventKind.allCases),
                              repoName: nil,
                              pathContains: nil)
        var matches = 0
        for _ in 0..<200 {
            matches += FilterEngine.filterSessions(sessions, filters: filters).count
        }
        let searchElapsed = clock.now - searchStart
        XCTAssertGreaterThanOrEqual(matches, 0)

        // Transcript build: ensure large sessions can be rendered without crashing.
        let transcriptStart = clock.now
        let tf: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        for s in sessions {
            _ = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: tf, mode: .normal)
        }
        let transcriptElapsed = clock.now - transcriptStart

        // 10k-message transcript: synthetic but representative scaling check.
        let largeSessionStart = clock.now
        var events: [SessionEvent] = []
        events.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let kind: SessionEventKind = (i % 2 == 0) ? .user : .assistant
            let role = (kind == .user) ? "user" : "assistant"
            events.append(SessionEvent(id: "synthetic-\(i)",
                                       timestamp: nil,
                                       kind: kind,
                                       role: role,
                                       text: "Message \(i)",
                                       toolName: nil,
                                       toolInput: nil,
                                       toolOutput: nil,
                                       messageID: nil,
                                       parentID: nil,
                                       isDelta: false,
                                       rawJSON: "{}"))
        }
        let synthetic = Session(id: "synthetic",
                                source: .codex,
                                startTime: nil,
                                endTime: nil,
                                model: "synthetic",
                                filePath: "/tmp/synthetic",
                                fileSizeBytes: nil,
                                eventCount: events.count,
                                events: events)
        _ = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: synthetic, filters: tf, mode: .normal)
        let largeSessionElapsed = clock.now - largeSessionStart

        // Keep as a harness, not a strict perf gate.
        _ = parseElapsed
        _ = searchElapsed
        _ = transcriptElapsed
        _ = largeSessionElapsed
    }
}
