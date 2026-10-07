import XCTest
@testable import AgentSessions

final class SessionInfoQuickFactsTests: XCTestCase {
    func testQuickFactsUseLoadedMetadataWithoutTranscriptEvents() {
        let session = Session(
            id: "session-1",
            source: .qwen,
            startTime: nil,
            endTime: nil,
            model: "qwen3-coder",
            filePath: "/tmp/session.jsonl",
            eventCount: 24,
            events: [],
            cwd: "/tmp/project",
            repoName: "project",
            lightweightTitle: "  Fix the parser  ",
            reasoningEffort: "high")

        let facts = SessionInfoQuickFacts(session: session)

        XCTAssertEqual(facts.source, .qwen)
        XCTAssertEqual(facts.sessionID, "session-1")
        XCTAssertEqual(facts.currentModel.value, "qwen3-coder")
        XCTAssertEqual(facts.currentModel.provenance, .currentModel)
        XCTAssertEqual(facts.firstObservedModel.unavailableReason, .unsupported)
        XCTAssertEqual(facts.reasoningEffort.value, "high")
        XCTAssertEqual(facts.reasoningEffort.provenance, .currentConfiguration)
        XCTAssertEqual(facts.title.value, "Fix the parser")
        XCTAssertEqual(facts.title.provenance, .sessionMetadata)
    }

    func testQuickFactsCoverEveryRegisteredSource() {
        for source in SessionSource.allCases {
            let session = Session(
                id: "\(source.rawValue)-session",
                source: source,
                startTime: nil,
                endTime: nil,
                model: "model-\(source.rawValue)",
                filePath: "/tmp/\(source.rawValue).jsonl",
                eventCount: 0,
                events: [])

            let facts = SessionInfoQuickFacts(session: session)

            XCTAssertEqual(facts.source, source)
            XCTAssertEqual(facts.currentModel.value, "model-\(source.rawValue)", "\(source)")
            XCTAssertEqual(facts.currentModel.provenance, .currentModel, "\(source)")
        }
    }

    func testFirstObservedModelDistinguishesUnsupportedFromPendingTelemetry() {
        let unsupported = Session(
            id: "qwen-session",
            source: .qwen,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/qwen.jsonl",
            eventCount: 0,
            events: [])
        let supported = Session(
            id: "claude-session",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/claude.jsonl",
            eventCount: 0,
            events: [])
        let sqliteBacked = Session(
            id: "opencode-session",
            source: .opencode,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/opencode.db",
            eventCount: 0,
            events: [])
        let legacyOpenCode = Session(
            id: "opencode-legacy-session",
            source: .opencode,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/opencode-session.json",
            eventCount: 0,
            events: [])

        XCTAssertEqual(
            SessionInfoQuickFacts(session: unsupported).firstObservedModel.unavailableReason,
            .unsupported)
        XCTAssertEqual(
            SessionInfoQuickFacts(session: supported).firstObservedModel.unavailableReason,
            .notLoaded)
        XCTAssertEqual(
            SessionInfoQuickFacts(session: sqliteBacked).firstObservedModel.unavailableReason,
            .notLoaded)
        XCTAssertEqual(
            SessionInfoQuickFacts(session: legacyOpenCode).firstObservedModel.unavailableReason,
            .unsupported)
    }

    func testQuickFactsPreferCustomTitleAndDoNotUseEmptyMetadata() {
        let session = Session(
            id: "session-2",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: "gpt",
            filePath: "/tmp/session.jsonl",
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: "fallback",
            customTitle: "  renamed  ")

        XCTAssertEqual(SessionInfoQuickFacts(session: session).title.value, "renamed")

        let empty = Session(
            id: "session-3",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: " ",
            filePath: "/tmp/session.jsonl",
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: " ")
        let emptyFacts = SessionInfoQuickFacts(session: empty)
        XCTAssertEqual(emptyFacts.currentModel.unavailableReason, SessionInfoUnavailableReason.notRecorded)
        XCTAssertEqual(emptyFacts.title.unavailableReason, SessionInfoUnavailableReason.notLoaded)
    }

    func testMetadataSanitizerRemovesPromptPayloadsFromModelAndTitle() {
        XCTAssertEqual(
            SessionInfoMetadataSanitizer.model(
                "gemini-2.5-pro\n\n# Instructions\nYou are a helpful assistant.",
                source: .antigravity),
            "gemini-2.5-pro")
        XCTAssertNil(
            SessionInfoMetadataSanitizer.title(
                "<system-reminder>internal instructions</system-reminder>",
                source: .hermes))
        XCTAssertNil(
            SessionInfoMetadataSanitizer.title(
                "2026-10-07T20:15:00Z",
                source: .cursor))
        XCTAssertEqual(
            SessionInfoMetadataSanitizer.title("  Fix the\tparser  ", source: .copilot),
            "Fix the parser")
    }

    func testQuickFactsMarkUnsafeMetadataAmbiguous() {
        let session = Session(
            id: "unsafe-metadata",
            source: .copilot,
            startTime: nil,
            endTime: nil,
            model: "model-1",
            filePath: "/tmp/copilot.jsonl",
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: "<user_query>raw prompt</user_query>")

        let facts = SessionInfoQuickFacts(session: session)

        XCTAssertEqual(facts.currentModel.value, "model-1")
        XCTAssertEqual(facts.title.unavailableReason, .ambiguous)
    }

    func testQuickFactsIdentityDoesNotUseDelimiterConcatenation() {
        let first = Session(
            id: "id\u{1F}known:currentModel:v",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/first.jsonl",
            eventCount: 0,
            events: [])
        let second = Session(
            id: "id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: "v\u{1F}unavailable:notRecorded",
            filePath: "/tmp/second.jsonl",
            eventCount: 0,
            events: [])

        XCTAssertNotEqual(
            SessionInfoQuickFacts(session: first).identity,
            SessionInfoQuickFacts(session: second).identity)
    }

    func testTelemetryTimeoutIsAnExplicitUnavailableReason() {
        XCTAssertEqual(SessionInfoUnavailableReason.timedOut.displayName, "Timed out")
        XCTAssertEqual(
            SessionInfoTelemetryLoadState.unavailable(.timedOut),
            .unavailable(.timedOut))
    }
}

final class SessionInfoMetricsTests: XCTestCase {
    func testMetricsRecordTheRequiredSignals() {
        let metrics = SessionInfoMetrics()

        metrics.recordModelFirstPaint(duration: 0.012)
        metrics.recordTelemetryFinished(duration: 0.025, bytesScanned: 512)
        metrics.recordCacheHit()
        metrics.recordInFlightJoin()
        metrics.recordDuplicateParse()
        metrics.beginTranscript(path: "/tmp/session.jsonl")
        metrics.beginTelemetry(path: "/tmp/session.jsonl")
        metrics.endTelemetry(path: "/tmp/session.jsonl")
        metrics.endTranscript(path: "/tmp/session.jsonl")

        let snapshot = metrics.snapshot
        XCTAssertEqual(snapshot.modelFirstPaintCount, 1)
        XCTAssertEqual(snapshot.telemetryRequestCount, 1)
        XCTAssertEqual(snapshot.telemetryBytesScanned, 512)
        XCTAssertEqual(snapshot.cacheHitCount, 1)
        XCTAssertEqual(snapshot.inFlightJoinCount, 1)
        XCTAssertEqual(snapshot.duplicateParseCount, 1)
        XCTAssertEqual(snapshot.transcriptTelemetryOverlapCount, 1)
        XCTAssertEqual(snapshot.modelFirstPaintTotalMilliseconds, 12, accuracy: 0.001)
        XCTAssertEqual(snapshot.telemetryDurationTotalMilliseconds, 25, accuracy: 0.001)
    }

    func testMetricsDoNotDoubleCountRepeatedBeginForTheSamePath() {
        let metrics = SessionInfoMetrics()

        metrics.beginTranscript(path: "/tmp/session.jsonl")
        metrics.beginTranscript(path: "/tmp/session.jsonl")
        metrics.beginTelemetry(path: "/tmp/session.jsonl")
        metrics.endTranscript(path: "/tmp/session.jsonl")
        metrics.endTelemetry(path: "/tmp/session.jsonl")
        // One transcript operation remains active, so a new telemetry episode
        // must still observe the overlap.
        metrics.beginTelemetry(path: "/tmp/session.jsonl")

        XCTAssertEqual(metrics.snapshot.transcriptTelemetryOverlapCount, 2)
    }

    func testResetPreservesInFlightLifetimesForOverlapAccounting() {
        let metrics = SessionInfoMetrics()

        metrics.beginTranscript(path: "/tmp/session.jsonl")
        metrics.reset()
        metrics.beginTelemetry(path: "/tmp/session.jsonl")

        XCTAssertEqual(metrics.snapshot.transcriptTelemetryOverlapCount, 1)

        metrics.endTelemetry(path: "/tmp/session.jsonl")
        metrics.endTranscript(path: "/tmp/session.jsonl")
    }

    func testSessionIdentityKeepsOverlapAccountingSeparateForSharedDatabasePaths() {
        let metrics = SessionInfoMetrics()
        let first = SessionInfoMetricsIdentity(source: .opencode, sessionID: "session-a")
        let second = SessionInfoMetricsIdentity(source: .opencode, sessionID: "session-b")

        metrics.beginTranscript(identity: first)
        metrics.beginTelemetry(identity: second)
        XCTAssertEqual(metrics.snapshot.transcriptTelemetryOverlapCount, 0)

        metrics.beginTelemetry(identity: first)
        XCTAssertEqual(metrics.snapshot.transcriptTelemetryOverlapCount, 1)

        metrics.endTelemetry(identity: first)
        metrics.endTelemetry(identity: second)
        metrics.endTranscript(identity: first)
    }
}
