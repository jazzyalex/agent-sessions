import XCTest
@testable import AgentSessions

final class ClaudeStatusServiceTests: XCTestCase {
    func testResolvedTmuxPathPrefersLoginShellPath() {
        let resolved = ClaudeStatusService.resolvedTmuxPath(loginShellPath: "/custom/bin/tmux") { _ in
            XCTFail("Common-path fallback should not run when login shell resolves tmux")
            return false
        }

        XCTAssertEqual(resolved, "/custom/bin/tmux")
    }

    func testResolvedTmuxPathFallsBackToHomebrewWhenLoginShellMisses() {
        let resolved = ClaudeStatusService.resolvedTmuxPath(loginShellPath: "") { path in
            path == "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(resolved, "/opt/homebrew/bin/tmux")
    }

    func testResolvedTmuxPathFallsBackToIntelHomebrewWhenAppleSiliconPathMisses() {
        let resolved = ClaudeStatusService.resolvedTmuxPath(loginShellPath: nil) { path in
            path == "/usr/local/bin/tmux"
        }

        XCTAssertEqual(resolved, "/usr/local/bin/tmux")
    }

    func testTerminalPathCacheCachesWithinTTL() {
        var cache = ClaudeTerminalPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 10_000)

        let first = cache.resolve(at: now) {
            resolveCalls += 1
            return "/opt/homebrew/bin:/usr/bin:/bin"
        }
        let second = cache.resolve(at: now.addingTimeInterval(12)) {
            resolveCalls += 1
            return "/usr/bin:/bin"
        }

        XCTAssertEqual(first, "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(second, "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(resolveCalls, 1)
    }

    func testTerminalPathCacheRefreshesAfterTTLExpiry() {
        var cache = ClaudeTerminalPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 11_000)

        _ = cache.resolve(at: now) {
            resolveCalls += 1
            return "/opt/homebrew/bin:/usr/bin:/bin"
        }
        let refreshed = cache.resolve(at: now.addingTimeInterval(45)) {
            resolveCalls += 1
            return "/usr/bin:/bin"
        }

        XCTAssertEqual(refreshed, "/usr/bin:/bin")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTerminalPathCacheDoesNotCacheFailedResolutions() {
        var cache = ClaudeTerminalPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 12_000)

        let first = cache.resolve(at: now) {
            resolveCalls += 1
            return nil
        }
        let second = cache.resolve(at: now.addingTimeInterval(1)) {
            resolveCalls += 1
            return "/usr/bin:/bin"
        }

        XCTAssertNil(first)
        XCTAssertEqual(second, "/usr/bin:/bin")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTmuxPathCacheCachesWithinTTL() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 1_000)

        let first = cache.resolve(at: now) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }
        let second = cache.resolve(at: now.addingTimeInterval(10)) {
            resolveCalls += 1
            return "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(first, "/usr/bin/tmux")
        XCTAssertEqual(second, "/usr/bin/tmux")
        XCTAssertEqual(resolveCalls, 1)
    }

    func testTmuxPathCacheRefreshesAfterTTLExpiry() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 2_000)

        _ = cache.resolve(at: now) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }
        let refreshed = cache.resolve(at: now.addingTimeInterval(31)) {
            resolveCalls += 1
            return "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(refreshed, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTmuxPathCacheForceRefreshBypassesTTL() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 3_000)

        _ = cache.resolve(at: now) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }
        let refreshed = cache.resolve(at: now.addingTimeInterval(1), forceRefresh: true) {
            resolveCalls += 1
            return "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(refreshed, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTmuxPathCacheInvalidateClearsCachedState() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 4_000)

        _ = cache.resolve(at: now) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }
        cache.invalidate()
        let refreshed = cache.resolve(at: now.addingTimeInterval(1)) {
            resolveCalls += 1
            return "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(refreshed, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTmuxPathCacheDoesNotCacheFailedResolutions() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 5_000)

        let first = cache.resolve(at: now) {
            resolveCalls += 1
            return nil
        }
        let second = cache.resolve(at: now.addingTimeInterval(1)) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }

        XCTAssertNil(first)
        XCTAssertEqual(second, "/usr/bin/tmux")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testParseUsageJSONRejectsSuccessfulPayloadMissingQuotaWindows() async {
        let service = ClaudeStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let parsed = await service.parseUsageJSONForTesting(#"{"ok":true,"format":"v2"}"#)

        XCTAssertNil(parsed)
    }

    func testParseUsageJSONRejectsV2UnavailablePayload() async {
        let service = ClaudeStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let json = #"{"ok":false,"error":"ui_format_v2","hint":"Claude Code 2.x no longer exposes quota percentages."}"#

        let parsed = await service.parseUsageJSONForTesting(json)
        let message = await service.probeUnavailableMessageForTesting(from: json)

        XCTAssertNil(parsed)
        XCTAssertEqual(
            message,
            "Claude /usage probe unavailable: ui_format_v2. Claude Code 2.x no longer exposes quota percentages."
        )
    }

    func testParseUsageJSONRejectsRateLimitedUnavailablePayload() async {
        let service = ClaudeStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let json = #"{"ok":false,"error":"rate_limited","hint":"Claude Code CLI reported rate limiting in /usage output"}"#

        let parsed = await service.parseUsageJSONForTesting(json)
        let message = await service.probeUnavailableMessageForTesting(from: json)

        XCTAssertNil(parsed)
        XCTAssertEqual(
            message,
            "Claude /usage probe unavailable: rate_limited. Claude Code CLI reported rate limiting in /usage output"
        )
    }

    func testClaudeBuiltInBinaryPathDetection() {
        let home = "/Users/example"

        XCTAssertTrue(AgentUpdateService.isClaudeBuiltinBinaryPath(
            "/Users/example/.local/bin/claude",
            homeDirectory: home
        ))
        XCTAssertTrue(AgentUpdateService.isClaudeBuiltinBinaryPath(
            "/Users/example/.local/share/claude/versions/2.1.185",
            homeDirectory: home
        ))
        XCTAssertFalse(AgentUpdateService.isClaudeBuiltinBinaryPath(
            "/Users/example/.npm-global/bin/claude",
            homeDirectory: home
        ))
    }

    func testClaudeBuiltInUpdateCheckUsesBuiltInUpdaterStatus() {
        let service = AgentUpdateService()
        let path = NSHomeDirectory() + "/.local/bin/claude"

        let result = service.checkForUpdates(
            source: .claude,
            resolvedBinaryPath: path,
            customBinaryPath: nil
        )

        XCTAssertEqual(result.primaryManager.rawValue, AgentPackageManager.builtin.rawValue)
        XCTAssertEqual(result.packageIdentifier, path)
        guard case .builtInUpdaterAvailable = result.status else {
            return XCTFail("Expected built-in updater status, got \(result.status)")
        }
    }

    func testParseUsageJSONAcceptsCompleteQuotaPayload() async {
        let service = ClaudeStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let json = """
        {
          "ok": true,
          "session_5h": { "pct_left": 82, "resets": "in 3h" },
          "week_all_models": { "pct_left": 51, "resets": "in 2d" },
          "week_opus": null
        }
        """

        let parsed = await service.parseUsageJSONForTesting(json)

        XCTAssertEqual(parsed?.sessionRemainingPercent, 82)
        XCTAssertEqual(parsed?.weekAllModelsRemainingPercent, 51)
        guard let parsed else { return XCTFail("Expected parsed snapshot") }
        XCTAssertNotNil(UsageResetText.resetDate(kind: "5h", source: .claude, raw: parsed.sessionResetText))
        XCTAssertNotNil(UsageResetText.resetDate(kind: "Wk", source: .claude, raw: parsed.weekAllModelsResetText))
    }

    func testClaudeUsageCaptureFixtureParsesV1QuotaOutput() throws {
        let fixture = """
        Current session
        82% left
        Resets in 3h

        Current week (all models)
        51% left
        Resets in 2d
        """

        let result = try runClaudeUsageCaptureFixture(fixture)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains(#""ok": true"#))
        XCTAssertTrue(result.stdout.contains(#""pct_left": 82"#))
        XCTAssertTrue(result.stdout.contains(#""pct_left": 51"#))
    }

    func testClaudeUsageCaptureFixtureParsesUsedPercentOutput() throws {
        let fixture = """
        Current session
        ███████████                                        22% used
        Resets 2:30pm (America/Los_Angeles)

        Current week (all models)
        █▌                                                 3% used
        Resets Jun 28 at 5am (America/Los_Angeles)
        """

        let result = try runClaudeUsageCaptureFixture(fixture)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains(#""ok": true"#))
        XCTAssertTrue(result.stdout.contains(#""pct_left": 78"#), result.stdout)
        XCTAssertTrue(result.stdout.contains(#""pct_left": 97"#), result.stdout)
        XCTAssertTrue(result.stdout.contains(#""resets": "2:30pm (America/Los_Angeles)""#), result.stdout)
        XCTAssertTrue(result.stdout.contains(#""resets": "Jun 28 at 5am (America/Los_Angeles)""#), result.stdout)
    }

    func testClaudeUsageCaptureFixtureDetectsV2UnavailableQuotaOutput() throws {
        let fixture = """
        Claude Code v2.1.169

        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine

        Last 24h
        Nothing over 10% in this period

        d to day   w to week
        """

        let result = try runClaudeUsageCaptureFixture(fixture)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains(#""ok":false"#))
        XCTAssertTrue(result.stdout.contains(#""error":"ui_format_v2""#))
        XCTAssertFalse(result.stdout.contains("session_5h"))
        XCTAssertFalse(result.stdout.contains("week_all_models"))
    }

    func testClaudeUsageCaptureFixtureDetectsRateLimitedUsageOutput() throws {
        let fixture = """
        Current session

        Error: Usage endpoint is rate limited. Please try again in a moment.
        """

        let result = try runClaudeUsageCaptureFixture(fixture)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains(#""ok":false"#))
        XCTAssertTrue(result.stdout.contains(#""error":"rate_limited""#))
        XCTAssertFalse(result.stdout.contains("session_5h"))
        XCTAssertFalse(result.stdout.contains("week_all_models"))
    }

    func testClaudeUsageCaptureFixtureRejectsPartialQuotaOutput() throws {
        let fixture = """
        Current session
        82% left
        Resets in 3h
        """

        let result = try runClaudeUsageCaptureFixture(fixture)

        XCTAssertEqual(result.status, 16)
        XCTAssertTrue(result.stdout.contains(#""error":"parsing_failed""#))
        XCTAssertFalse(result.stdout.contains(#""ok": true"#))
    }

    func testCleanupPlannerValidatesExpectedLabelShape() {
        let planner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)

        XCTAssertTrue(planner.isManagedProbeLabel("as-cc-AbCdEf1234g5"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-xy-AbCdEf1234g5"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-cc-ABC123"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-cc-1bCdEf1234g5"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-cc-AbCdEf1234gX"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-cc-AbCdEf12_4g5"))
    }

    func testCleanupPlannerQueueExcludesProtectedAndActiveLabels() {
        let planner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)
        let allLabels: Set<String> = [
            "as-cc-AbCdEf1234g5",
            "as-cc-ZyXwVu9876t4",
            "as-cc-LmNoPq4567r8",
            "as-cc-1badLabel234",
            "other-prefix-AbCdEf1234g5"
        ]
        let protected: Set<String> = ["as-cc-ZyXwVu9876t4"]
        let queue = planner.plannedQueue(
            allLabels: allLabels,
            protectedLabels: protected,
            activeLabel: "as-cc-LmNoPq4567r8"
        )

        XCTAssertEqual(queue, ["as-cc-AbCdEf1234g5"])
    }

    func testCleanupPlannerSocketPathsForManagedLabel() {
        let planner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)

        let paths = planner.socketPaths(uid: 501, label: "as-cc-AbCdEf1234g5")

        XCTAssertEqual(
            paths,
            [
                "/private/tmp/tmux-501/as-cc-AbCdEf1234g5",
                "/tmp/tmux-501/as-cc-AbCdEf1234g5"
            ]
        )
    }

    func testCleanupPlannerSocketPathsRejectUnmanagedLabel() {
        let planner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)

        XCTAssertTrue(planner.socketPaths(uid: 501, label: "as-cc-1bCdEf1234g5").isEmpty)
        XCTAssertTrue(planner.socketPaths(uid: 501, label: "other-label").isEmpty)
    }

    func testParseManagedProbePIDs_matchesOnlyManagedTmuxAndClaudeProbeProcesses() {
        let snapshot = """
          101 /opt/homebrew/bin/tmux -L as-cc-AbCdEf1234g5 new-session -d -s usage
          102 /Users/alexm/.local/bin/claude --model sonnet WORKDIR=/Users/alexm/.config/agent-sessions/claude-probe TMUX=/private/tmp/tmux-501/as-cc-AbCdEf1234g5,123,0
          103 /opt/homebrew/bin/tmux -L other-label new-session -d -s usage
          104 /Users/alexm/.local/bin/claude --model sonnet WORKDIR=/Users/alexm/.config/agent-sessions/claude-probe TMUX=/private/tmp/tmux-501/other-label,123,0
          105 /Users/alexm/.local/bin/claude --model sonnet
        """

        let pids = ClaudeStatusService.parseManagedProbePIDs(
            from: snapshot,
            label: "as-cc-AbCdEf1234g5",
            uid: 501
        )

        XCTAssertEqual(pids, [101, 102])
    }

    func testParseManagedProbePIDs_rejectsUnmanagedLabels() {
        let snapshot = "101 /opt/homebrew/bin/tmux -L as-cc-AbCdEf1234g5 new-session -d -s usage"

        let pids = ClaudeStatusService.parseManagedProbePIDs(
            from: snapshot,
            label: "other-label",
            uid: 501
        )

        XCTAssertTrue(pids.isEmpty)
    }

    private func runClaudeUsageCaptureFixture(_ fixture: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-fixture-\(UUID().uuidString).txt")
        try fixture.write(to: tempURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot
            .appendingPathComponent("AgentSessions")
            .appendingPathComponent("Resources")
            .appendingPathComponent("claude_usage_capture.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_USAGE_CAPTURE_FIXTURE"] = tempURL.path
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
