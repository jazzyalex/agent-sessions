import XCTest
@testable import AgentSessions

final class ClaudeRunwayParserTests: XCTestCase {

    // MARK: - Token activity parser

    func testTokenActivityParserExtractsIncrementalTokenRate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let t1 = t0.addingTimeInterval(30)
        let t2 = t0.addingTimeInterval(60)
        let text = """
        \(assistantLine(id: "A", at: t0, inputTokens: 1000))
        \(assistantLine(id: "B", at: t1, inputTokens: 2000))
        \(assistantLine(id: "C", at: t2, inputTokens: 3000))
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let activity = ClaudeRunwayTokenActivityParser.activity(identity: identity, now: t2.addingTimeInterval(1))

        // consumed = tokens of B + C (anchor t0 excluded) = 5000 over a 60s span.
        XCTAssertEqual(activity?.tokensPerSecond ?? 0, 5000.0 / 60.0, accuracy: 0.001)
    }

    func testTokenActivityParserDedupesByMessageID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-dedupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let t1 = t0.addingTimeInterval(30)
        let t2 = t0.addingTimeInterval(60)
        // The final turn (id C) is emitted twice — streaming duplicates.
        let text = """
        \(assistantLine(id: "A", at: t0, inputTokens: 1000))
        \(assistantLine(id: "B", at: t1, inputTokens: 2000))
        \(assistantLine(id: "C", at: t2, inputTokens: 3000))
        \(assistantLine(id: "C", at: t2, inputTokens: 3000))
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let activity = ClaudeRunwayTokenActivityParser.activity(identity: identity, now: t2.addingTimeInterval(1))

        // Dedupe collapses the duplicate C, so the rate matches the 3-turn case.
        XCTAssertEqual(activity?.tokensPerSecond ?? 0, 5000.0 / 60.0, accuracy: 0.001)
    }

    func testTokenActivityParserIgnoresStaleActivity() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let t1 = t0.addingTimeInterval(30)
        let text = """
        \(assistantLine(id: "A", at: t0, inputTokens: 1000))
        \(assistantLine(id: "B", at: t1, inputTokens: 2000))
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let staleNow = t1.addingTimeInterval(ClaudeRunwayTokenActivityParser.maximumSampleAge + 1)
        XCTAssertNil(ClaudeRunwayTokenActivityParser.activity(identity: identity, now: staleNow))
    }

    // MARK: - Recent session scanner

    func testRecentSessionScannerDiscoversActiveLogAndSkipsStale() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-scan-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()

        let activeLog = projectDir.appendingPathComponent("active.jsonl")
        let activeText = """
        \(userLine(sessionID: "sess-active", cwd: "/tmp/proj", text: "build the thing", at: now.addingTimeInterval(-40)))
        \(assistantLine(id: "x1", at: now.addingTimeInterval(-5), inputTokens: 1200, sessionID: "sess-active", cwd: "/tmp/proj"))
        """
        try activeText.write(to: activeLog, atomically: true, encoding: .utf8)

        let staleLog = projectDir.appendingPathComponent("stale.jsonl")
        let staleText = """
        \(userLine(sessionID: "sess-stale", cwd: "/tmp/proj", text: "older task", at: now.addingTimeInterval(-400)))
        \(assistantLine(id: "y1", at: now.addingTimeInterval(-300), inputTokens: 800, sessionID: "sess-stale", cwd: "/tmp/proj"))
        """
        try staleText.write(to: staleLog, atomically: true, encoding: .utf8)

        let identities = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.id, "sess-active")
        XCTAssertEqual(identities.first?.displayName, "build the thing")
        let resolvedPaths = (identities.first?.logPaths ?? []).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        XCTAssertEqual(resolvedPaths, [activeLog.resolvingSymlinksInPath().path])
    }

    func testRecentSessionScannerPrefersAITitleOverFirstPrompt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-aititle-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let log = projectDir.appendingPathComponent("session.jsonl")
        let text = """
        \(userLine(sessionID: "sess-1", cwd: "/tmp/proj", text: "do Now — 1.0 release blockers — the long detailed prompt", at: now.addingTimeInterval(-30)))
        {"type":"ai-title","aiTitle":"1.0 release blockers","sessionId":"sess-1"}
        \(assistantLine(id: "z1", at: now.addingTimeInterval(-5), inputTokens: 900, sessionID: "sess-1", cwd: "/tmp/proj"))
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identities = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now)
        XCTAssertEqual(identities.first?.displayName, "1.0 release blockers")
    }

    func testRecentSessionScannerFoldsSubagentsIntoParentSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-subagent-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        let subagentDir = projectDir.appendingPathComponent("sess-parent/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // Parent main transcript carries the session title.
        let parentLog = projectDir.appendingPathComponent("sess-parent.jsonl")
        try """
        {"type":"ai-title","aiTitle":"ship the release","sessionId":"sess-parent"}
        \(assistantLine(id: "p1", at: now.addingTimeInterval(-8), inputTokens: 1000, sessionID: "sess-parent", cwd: "/tmp/proj"))
        """.write(to: parentLog, atomically: true, encoding: .utf8)

        // Subagent transcript shares the parent sessionId; its first prompt is an
        // internal task that must NOT become the row name.
        let subagentLog = subagentDir.appendingPathComponent("agent-abc.jsonl")
        try """
        \(userLine(sessionID: "sess-parent", cwd: "/tmp/proj", text: "You are a subagent: grep the repo", at: now.addingTimeInterval(-6)))
        \(assistantLine(id: "s1", at: now.addingTimeInterval(-3), inputTokens: 2000, sessionID: "sess-parent", cwd: "/tmp/proj"))
        """.write(to: subagentLog, atomically: true, encoding: .utf8)

        let identities = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1, "parent + subagent should collapse to one session")
        XCTAssertEqual(identities.first?.id, "sess-parent")
        XCTAssertEqual(identities.first?.displayName, "ship the release", "parent title wins, never the subagent task")
        XCTAssertEqual(identities.first?.logPaths.count, 2, "both transcripts contribute to cumulative burn")
    }

    func testRecentSessionScannerCapsDistinctSessionsNotSubagentFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-subagent-cap-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        let subagentDir = projectDir.appendingPathComponent("sess-parent/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let parentLog = projectDir.appendingPathComponent("sess-parent.jsonl")
        try """
        {"type":"ai-title","aiTitle":"parent work","sessionId":"sess-parent"}
        \(assistantLine(id: "parent", at: now.addingTimeInterval(-8), inputTokens: 1000, sessionID: "sess-parent", cwd: "/tmp/proj"))
        """.write(to: parentLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: parentLog.path)

        for index in 0..<85 {
            let log = subagentDir.appendingPathComponent("agent-\(index).jsonl")
            try """
            \(assistantLine(id: "sub-\(index)", at: now.addingTimeInterval(-4), inputTokens: 1000, sessionID: "sess-parent", cwd: "/tmp/proj"))
            """.write(to: log, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(TimeInterval(-index))], ofItemAtPath: log.path)
        }

        let otherLog = projectDir.appendingPathComponent("sess-other.jsonl")
        try """
        \(userLine(sessionID: "sess-other", cwd: "/tmp/proj", text: "other active work", at: now.addingTimeInterval(-12)))
        \(assistantLine(id: "other", at: now.addingTimeInterval(-5), inputTokens: 900, sessionID: "sess-other", cwd: "/tmp/proj"))
        """.write(to: otherLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90)], ofItemAtPath: otherLog.path)

        let identities = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.map(\.id), ["sess-parent", "sess-other"])
        XCTAssertEqual(identities.first?.logPaths.count, 86)
    }

    func testDesktopSessionTitlesMapKeysByCliSessionId() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-titles-\(UUID().uuidString)")
        let convoDir = root.appendingPathComponent("convoA/sessionB", isDirectory: true)
        try FileManager.default.createDirectory(at: convoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"sessionId":"local_abc","cliSessionId":"f1d39390-aaaa","title":"Quota meter and runway polish","titleSource":"auto"}
        """.write(to: convoDir.appendingPathComponent("local_abc.json"), atomically: true, encoding: .utf8)
        // A record with an empty title is ignored.
        try """
        {"sessionId":"local_def","cliSessionId":"99999999-bbbb","title":""}
        """.write(to: convoDir.appendingPathComponent("local_def.json"), atomically: true, encoding: .utf8)
        // A non-local file is ignored.
        try "{\"cliSessionId\":\"zzz\",\"title\":\"nope\"}"
            .write(to: convoDir.appendingPathComponent("other.json"), atomically: true, encoding: .utf8)

        let map = ClaudeDesktopSessionTitles.map(root: root)
        XCTAssertEqual(map["f1d39390-aaaa"], "Quota meter and runway polish")
        XCTAssertNil(map["99999999-bbbb"])
        XCTAssertNil(map["zzz"])
    }

    // W7 Task 2b: `records(root:)` enumerates the whole tree every call (there's
    // no cheaper reliable "did anything change" probe for an arbitrarily-nested
    // directory), but caches the parsed record per file path keyed by mtime —
    // an unchanged file is served from cache instead of re-reading + re-parsing
    // its JSON. This was measured running on the main thread once per HUD /
    // transcript-archive-strip rebuild.
    func testDesktopSessionTitlesCachesUnchangedFilesByMtime() throws {
        ClaudeDesktopSessionTitles.debugResetCache()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-titles-cache-\(UUID().uuidString)")
        let convoDir = root.appendingPathComponent("convoA/sessionB", isDirectory: true)
        try FileManager.default.createDirectory(at: convoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = convoDir.appendingPathComponent("local_abc.json")
        try """
        {"sessionId":"local_abc","cliSessionId":"f1d39390-aaaa","title":"First title"}
        """.write(to: fileA, atomically: true, encoding: .utf8)

        // First read: nothing cached yet, so the one file present must be parsed.
        let first = ClaudeDesktopSessionTitles.records(root: root)
        XCTAssertEqual(first["f1d39390-aaaa"]?.title, "First title")
        let afterFirst = ClaudeDesktopSessionTitles.debugParseAndHitCounts()
        XCTAssertEqual(afterFirst.parsed, 1)
        XCTAssertEqual(afterFirst.cacheHits, 0)

        // Second read against the SAME unchanged file: served from cache, no re-parse.
        let second = ClaudeDesktopSessionTitles.records(root: root)
        XCTAssertEqual(second["f1d39390-aaaa"]?.title, "First title")
        let afterSecond = ClaudeDesktopSessionTitles.debugParseAndHitCounts()
        XCTAssertEqual(afterSecond.parsed, 1, "unchanged file must not be re-parsed")
        XCTAssertEqual(afterSecond.cacheHits, 1)

        // Touch the file with a new mtime and a new title: must be re-parsed,
        // and the fresh title must win (cache never serves stale content).
        try """
        {"sessionId":"local_abc","cliSessionId":"f1d39390-aaaa","title":"Renamed title"}
        """.write(to: fileA, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: fileA.path
        )

        let third = ClaudeDesktopSessionTitles.records(root: root)
        XCTAssertEqual(third["f1d39390-aaaa"]?.title, "Renamed title")
        let afterThird = ClaudeDesktopSessionTitles.debugParseAndHitCounts()
        XCTAssertEqual(afterThird.parsed, 2, "a touched file must be re-parsed")
    }

    // MARK: - Loader: burn without a fresh projection (P1)

    func testLoaderShowsBurnWithoutFreshProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-nogate-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let log = projectDir.appendingPathComponent("sess-burn.jsonl")
        try """
        \(assistantLine(id: "b1", at: now.addingTimeInterval(-25), inputTokens: 1000, sessionID: "sess-burn", cwd: "/tmp/proj"))
        \(assistantLine(id: "b2", at: now.addingTimeInterval(-5), inputTokens: 1000, sessionID: "sess-burn", cwd: "/tmp/proj"))
        """.write(to: log, atomically: true, encoding: .utf8)

        // Baseline with NO fresh projection: runout falls back to the reset time.
        let baseline = RunwayProviderBaseline(
            source: .claude,
            remainingPercent: 50,
            resetAt: now.addingTimeInterval(2 * 3600),
            currentRunoutAt: now.addingTimeInterval(2 * 3600),
            observedAt: now,
            hasProjectedRunout: false
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline,
            identities: [],
            now: now,
            maxRows: 4,
            recentSessionsRoot: root
        )

        let snapshot = await ClaudeRunwaySnapshotLoader.snapshot(for: request)
        let row = snapshot?.rows.first { $0.id == "sess-burn" }
        XCTAssertNotNil(row, "active session should produce a row")
        XCTAssertNotEqual(row?.confidence, .waiting, "burn should render, not a waiting spinner")
        XCTAssertGreaterThan(row?.quotaMinutesPerHour ?? 0, 0, "a real burn rate should show without a fresh projection")
    }

    func testLoaderBurnSharpensWhenProjectionLands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-sharpen-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let log = projectDir.appendingPathComponent("sess-sharpen.jsonl")
        try """
        \(assistantLine(id: "s1", at: now.addingTimeInterval(-25), inputTokens: 1000, sessionID: "sess-sharpen", cwd: "/tmp/proj"))
        \(assistantLine(id: "s2", at: now.addingTimeInterval(-5), inputTokens: 1000, sessionID: "sess-sharpen", cwd: "/tmp/proj"))
        """.write(to: log, atomically: true, encoding: .utf8)

        func rate(hasProjection: Bool) async -> Double {
            // With a projection the runout is near (fast burn); without, it falls
            // back to the reset time (slow even-burn).
            let runoutAt = hasProjection ? now.addingTimeInterval(10 * 60) : now.addingTimeInterval(2 * 3600)
            let baseline = RunwayProviderBaseline(
                source: .claude,
                remainingPercent: 50,
                resetAt: now.addingTimeInterval(2 * 3600),
                currentRunoutAt: runoutAt,
                observedAt: now,
                hasProjectedRunout: hasProjection
            )
            let request = CodexRunwaySnapshotRequest(
                baseline: baseline, identities: [], now: now, maxRows: 4, recentSessionsRoot: root
            )
            let snapshot = await ClaudeRunwaySnapshotLoader.snapshot(for: request)
            return snapshot?.rows.first { $0.id == "sess-sharpen" }?.quotaMinutesPerHour ?? 0
        }

        let withoutProjection = await rate(hasProjection: false)
        let withProjection = await rate(hasProjection: true)
        XCTAssertGreaterThan(withoutProjection, 0, "burn shows even without a projection")
        XCTAssertGreaterThan(withProjection, withoutProjection, "rate sharpens to measured velocity once a projection lands")
    }

    // MARK: - RunwayBaselineMath.averageBurnRunout

    /// The whole point of the fix: near reset, the derived rate reflects the
    /// measured average (~36 m/h for 60% used over ~5h), NOT the reset-pinned
    /// fallback (~3600 m/h) that exploded as the denominator shrank.
    func testAverageBurnRunoutDoesNotExplodeNearReset() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let resetAt = now.addingTimeInterval(120) // 2 min to reset
        let runout = try XCTUnwrap(RunwayBaselineMath.averageBurnRunout(
            remainingPercent: 40,
            resetAt: resetAt,
            windowLength: RunwayBaselineMath.fiveHourWindow,
            now: now))
        let providerRate = 40.0 / runout.timeIntervalSince(now) // %/s
        let mPerHour = providerRate * 3 * 3600
        XCTAssertEqual(mPerHour, 36.2, accuracy: 1.0)
        XCTAssertLessThan(mPerHour, 100)
    }

    /// The rate must stay stable as the reset approaches (it depends on
    /// elapsed, not time-to-reset). The old fallback produced ~3600 then
    /// ~21600 m/h for these two inputs.
    func testAverageBurnRunoutRateStableAsResetApproaches() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func mPerHour(secondsToReset: TimeInterval, remaining: Double) throws -> Double {
            let resetAt = now.addingTimeInterval(secondsToReset)
            let runout = try XCTUnwrap(RunwayBaselineMath.averageBurnRunout(
                remainingPercent: remaining,
                resetAt: resetAt,
                windowLength: RunwayBaselineMath.fiveHourWindow,
                now: now))
            return remaining / runout.timeIntervalSince(now) * 3 * 3600
        }
        let near = try mPerHour(secondsToReset: 120, remaining: 40)
        let nearer = try mPerHour(secondsToReset: 20, remaining: 40)
        XCTAssertEqual(near, nearer, accuracy: 1.0)
        XCTAssertLessThan(nearer, 100)
    }

    /// Nothing used yet ⇒ no measurable burn ⇒ nil (caller keeps resetAt).
    func testAverageBurnRunoutNilWhenNothingUsed() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertNil(RunwayBaselineMath.averageBurnRunout(
            remainingPercent: 100,
            resetAt: now.addingTimeInterval(3600),
            windowLength: RunwayBaselineMath.fiveHourWindow,
            now: now))
    }

    /// Defensive: a reset farther out than the window length puts the window
    /// start in the future ⇒ nil rather than a negative elapsed.
    func testAverageBurnRunoutNilWhenWindowStartInFuture() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertNil(RunwayBaselineMath.averageBurnRunout(
            remainingPercent: 40,
            resetAt: now.addingTimeInterval(6 * 3600),
            windowLength: RunwayBaselineMath.fiveHourWindow,
            now: now))
    }

    /// Symmetric guard: a burst 30 s after reset (2% used) must be damped by the
    /// elapsed floor (2%/600s → ~36 m/h), not divided by 30 s (2%/30s → ~720 m/h).
    func testAverageBurnRunoutFloorsEarlyWindowElapsed() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let resetAt = now.addingTimeInterval(RunwayBaselineMath.fiveHourWindow - 30)
        let runout = try XCTUnwrap(RunwayBaselineMath.averageBurnRunout(
            remainingPercent: 98,
            resetAt: resetAt,
            windowLength: RunwayBaselineMath.fiveHourWindow,
            now: now))
        let mPerHour = 98.0 / runout.timeIntervalSince(now) * 3 * 3600
        XCTAssertEqual(mPerHour, 36.0, accuracy: 2.0)
    }

    // MARK: - claudeRequest baseline

    /// End-to-end: with no projection and ~2 min to reset, the baseline the
    /// builder produces must imply a sane burn rate (< 100 m/h), not the
    /// ~3600 m/h the reset-pinned fallback produced.
    func testClaudeRequestDerivesSaneBurnRateNearReset() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let resetAt = now.addingTimeInterval(120)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let resetText = iso.string(from: resetAt)

        let request = try XCTUnwrap(HUDRunwayRequestBuilder.claudeRequest(
            activeRows: [],
            projectedRunoutEnabled: true,
            claudeAgentEnabled: true,
            claudeUsageEnabled: true,
            fiveHourRemainingPercent: 40,
            fiveHourResetText: resetText,
            fiveHourProjectedRunoutAt: nil,
            fiveHourProjectionObservedAt: nil,
            now: now,
            maxRows: 4,
            forceVisible: true))

        let baseline = request.baseline
        let providerRate = baseline.remainingPercent
            / baseline.currentRunoutAt.timeIntervalSince(baseline.observedAt)
        let mPerHour = providerRate * 3 * 3600
        XCTAssertGreaterThan(mPerHour, 0)
        XCTAssertLessThan(mPerHour, 100)
        // Sanity: run-out is pushed well past the imminent reset.
        XCTAssertGreaterThan(baseline.currentRunoutAt, resetAt)
    }

    // MARK: - Track 1: provisional first-burn + idle drop-fast

    func testTokenActivityParserProvisionalRateFromSingleTurn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let turnStart = Date(timeIntervalSince1970: 2_000_000)
        let turnEnd = turnStart.addingTimeInterval(20)   // 20s turn
        // One usage sample preceded by the turn-start (user) line. No second
        // sample yet → the provisional single-turn rate should fire.
        try """
        \(userLine(sessionID: "s", cwd: "/tmp", text: "do it", at: turnStart))
        \(assistantLine(id: "a1", at: turnEnd, inputTokens: 4000, sessionID: "s", cwd: "/tmp"))
        """.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "s", displayName: "s", isGoal: false, logPaths: [log.path])
        let activity = ClaudeRunwayTokenActivityParser.activity(identity: identity, now: turnEnd.addingTimeInterval(1))
        XCTAssertEqual(activity?.tokensPerSecond ?? 0, 4000.0 / 20.0, accuracy: 0.001,
                       "single-turn provisional rate = tokens / turn duration")
    }

    func testTokenActivityParserSkipsProvisionalAcrossResumeGap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-prov-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let oldLine = Date(timeIntervalSince1970: 2_000_000)
        let usageAt = oldLine.addingTimeInterval(3600)   // 1h gap → resume boundary
        try """
        \(userLine(sessionID: "s", cwd: "/tmp", text: "earlier", at: oldLine))
        \(assistantLine(id: "a1", at: usageAt, inputTokens: 4000, sessionID: "s", cwd: "/tmp"))
        """.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "s", displayName: "s", isGoal: false, logPaths: [log.path])
        let activity = ClaudeRunwayTokenActivityParser.activity(identity: identity, now: usageAt.addingTimeInterval(1))
        XCTAssertNil(activity, "a turn after a long idle gap must not yield a fake near-zero provisional rate")
    }

    func testRecentSessionScannerDropsIdleSessionsSoonerThanWorking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-idle-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // Both last wrote 60s ago: past the 45s idle grace, within the 75s working window.
        let idleLog = projectDir.appendingPathComponent("idle.jsonl")
        try """
        \(userLine(sessionID: "sess-idle", cwd: "/tmp/proj", text: "task", at: now.addingTimeInterval(-90)))
        \(assistantLine(id: "i1", at: now.addingTimeInterval(-60), inputTokens: 800, sessionID: "sess-idle", cwd: "/tmp/proj", stopReason: "end_turn"))
        """.write(to: idleLog, atomically: true, encoding: .utf8)

        let workingLog = projectDir.appendingPathComponent("working.jsonl")
        try """
        \(userLine(sessionID: "sess-working", cwd: "/tmp/proj", text: "task", at: now.addingTimeInterval(-90)))
        \(assistantLine(id: "w1", at: now.addingTimeInterval(-60), inputTokens: 800, sessionID: "sess-working", cwd: "/tmp/proj", stopReason: "tool_use"))
        """.write(to: workingLog, atomically: true, encoding: .utf8)

        let ids = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now).map(\.id)
        XCTAssertFalse(ids.contains("sess-idle"), "idle (end_turn) session past the idle grace should drop")
        XCTAssertTrue(ids.contains("sess-working"), "working (tool_use) session within 75s should remain")
    }

    func testLoaderMarksIdleSessionRow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-idlerow-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // Finished its turn 40s ago: within the 45s idle grace (present), but past
        // the 30s burn window (no rate) → a pending row marked idle ("—").
        let log = projectDir.appendingPathComponent("sess-idle.jsonl")
        try """
        \(userLine(sessionID: "sess-idle", cwd: "/tmp/proj", text: "task", at: now.addingTimeInterval(-50)))
        \(assistantLine(id: "i1", at: now.addingTimeInterval(-40), inputTokens: 900, sessionID: "sess-idle", cwd: "/tmp/proj", stopReason: "end_turn"))
        """.write(to: log, atomically: true, encoding: .utf8)

        let baseline = RunwayProviderBaseline(
            source: .claude,
            remainingPercent: 50,
            resetAt: now.addingTimeInterval(2 * 3600),
            currentRunoutAt: now.addingTimeInterval(2 * 3600),
            observedAt: now,
            hasProjectedRunout: false
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline, identities: [], now: now, maxRows: 4, recentSessionsRoot: root
        )
        let snapshot = await ClaudeRunwaySnapshotLoader.snapshot(for: request)
        let row = snapshot?.rows.first { $0.id == "sess-idle" }
        XCTAssertEqual(row?.confidence, .idle, "an idle (end_turn) session with no fresh burn should render as idle, not a spinner")
    }

    // MARK: - Provisional rate must not dominate the cross-session split (F1)

    func testBurnsCapProvisionalRateToMeasuredBurst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        // Session A: a measured two-sample burst (1000 tokens over 20s = 50 tok/s).
        let logA = dir.appendingPathComponent("a.jsonl")
        try """
        \(assistantLine(id: "a1", at: now.addingTimeInterval(-25), inputTokens: 1000, sessionID: "A"))
        \(assistantLine(id: "a2", at: now.addingTimeInterval(-5), inputTokens: 1000, sessionID: "A"))
        """.write(to: logA, atomically: true, encoding: .utf8)
        // Session B: a single steep cache-heavy turn over the 2s clamp floor → a
        // provisional ~50,000 tok/s that, uncapped, would claim ~99% of the split.
        let logB = dir.appendingPathComponent("b.jsonl")
        try """
        \(userLine(sessionID: "B", cwd: "/tmp", text: "go", at: now.addingTimeInterval(-3)))
        \(assistantLine(id: "b1", at: now.addingTimeInterval(-1), inputTokens: 100000, sessionID: "B"))
        """.write(to: logB, atomically: true, encoding: .utf8)

        let identityA = RunwaySessionIdentity(id: "A", displayName: "A", isGoal: false, logPaths: [logA.path])
        let identityB = RunwaySessionIdentity(id: "B", displayName: "B", isGoal: false, logPaths: [logB.path])
        let baseline = RunwayProviderBaseline(
            source: .claude, remainingPercent: 50,
            resetAt: now.addingTimeInterval(2 * 3600),
            currentRunoutAt: now.addingTimeInterval(2 * 3600),
            observedAt: now, hasProjectedRunout: false
        )
        let burns = ClaudeRunwayTokenActivityParser.burns(identities: [identityA, identityB], baseline: baseline, now: now)
        let aBurn = try XCTUnwrap(burns.first { $0.identity.id == "A" })
        let bBurn = try XCTUnwrap(burns.first { $0.identity.id == "B" })
        // B is provisional and capped at A's measured burst, so it claims at most
        // an equal share — never more than the busiest verified session.
        XCTAssertEqual(bBurn.percentPerSecond, aBurn.percentPerSecond, accuracy: aBurn.percentPerSecond * 0.02,
                       "a provisional rate must be capped at the measured peer burst, not dominate the split")
    }

    // MARK: - Desktop-titled idle session keeps idle confidence (F2)

    func testLoaderPreservesIdleForDesktopTitledSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-idletitle-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let desktopRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: desktopRoot) }

        let now = Date()
        // Finished its turn 40s ago: within the 45s idle grace, past the 30s burn
        // window → an idle pending row.
        let log = projectDir.appendingPathComponent("sess-idle.jsonl")
        try """
        \(userLine(sessionID: "sess-titled-idle", cwd: "/tmp/proj", text: "task", at: now.addingTimeInterval(-50)))
        \(assistantLine(id: "i1", at: now.addingTimeInterval(-40), inputTokens: 900, sessionID: "sess-titled-idle", cwd: "/tmp/proj", stopReason: "end_turn"))
        """.write(to: log, atomically: true, encoding: .utf8)
        try writeDesktopSidecar(root: desktopRoot, cliSessionID: "sess-titled-idle", title: "Renamed In Desktop", isArchived: false)

        let baseline = RunwayProviderBaseline(
            source: .claude, remainingPercent: 50,
            resetAt: now.addingTimeInterval(2 * 3600),
            currentRunoutAt: now.addingTimeInterval(2 * 3600),
            observedAt: now, hasProjectedRunout: false
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline, identities: [], now: now, maxRows: 4, recentSessionsRoot: root
        )
        let snapshot = await ClaudeRunwaySnapshotLoader.snapshot(for: request, desktopTitlesRoot: desktopRoot)
        let row = snapshot?.rows.first { $0.id == "sess-titled-idle" }
        XCTAssertEqual(row?.displayName, "Renamed In Desktop", "Desktop title should win")
        XCTAssertEqual(row?.confidence, .idle,
                       "a Desktop-titled idle session must stay idle ('—'), not become a spinner")
    }

    // MARK: - Archived Desktop sessions are excluded from the runway (F5)

    func testLoaderExcludesArchivedDesktopSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-archived-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let desktopRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-arch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: desktopRoot) }

        let now = Date()
        // A working session 5s ago that WOULD show a row — but it is archived.
        let log = projectDir.appendingPathComponent("sess-archived.jsonl")
        try """
        \(userLine(sessionID: "sess-archived", cwd: "/tmp/proj", text: "task", at: now.addingTimeInterval(-15)))
        \(assistantLine(id: "w1", at: now.addingTimeInterval(-5), inputTokens: 1000, sessionID: "sess-archived", cwd: "/tmp/proj", stopReason: "tool_use"))
        """.write(to: log, atomically: true, encoding: .utf8)
        try writeDesktopSidecar(root: desktopRoot, cliSessionID: "sess-archived", title: "Archived Convo", isArchived: true)

        let baseline = RunwayProviderBaseline(
            source: .claude, remainingPercent: 50,
            resetAt: now.addingTimeInterval(2 * 3600),
            currentRunoutAt: now.addingTimeInterval(2 * 3600),
            observedAt: now, hasProjectedRunout: false
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline, identities: [], now: now, maxRows: 4, recentSessionsRoot: root
        )
        let snapshot = await ClaudeRunwaySnapshotLoader.snapshot(for: request, desktopTitlesRoot: desktopRoot)
        XCTAssertNil(snapshot?.rows.first { $0.id == "sess-archived" },
                     "an archived Desktop session should not burn a runway row")
    }

    // MARK: - Helpers

    private func writeDesktopSidecar(root: URL, cliSessionID: String, title: String, isArchived: Bool) throws {
        let dir = root.appendingPathComponent("convo/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["cliSessionId": cliSessionID, "title": title, "isArchived": isArchived]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        try data.write(to: dir.appendingPathComponent("local_\(UUID().uuidString).json"))
    }

    private func assistantLine(id: String,
                               at date: Date,
                               inputTokens: Int,
                               sessionID: String = "session",
                               cwd: String? = nil,
                               stopReason: String? = nil) -> String {
        let cwdField = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
        let stopField = stopReason.map { "\"stop_reason\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"sessionId\":\"\(sessionID)\",\(cwdField)\"timestamp\":\"\(iso(date))\",\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\(stopField)\"usage\":{\"input_tokens\":\(inputTokens),\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func userLine(sessionID: String, cwd: String, text: String, at date: Date) -> String {
        return "{\"type\":\"user\",\"sessionId\":\"\(sessionID)\",\"cwd\":\"\(cwd)\",\"timestamp\":\"\(iso(date))\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
