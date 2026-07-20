import XCTest
@testable import AgentSessions

/// Tests for Codex usage parsing across format versions 0.50-0.53
final class CodexUsageParserTests: XCTestCase {

    func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: "jsonl")!
    }

    private func writeTempJSONL(_ objects: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex_usage_dual_limit_\(UUID().uuidString).jsonl")
        let lines = try objects.map { obj -> String in
            let data = try JSONSerialization.data(withJSONObject: obj, options: [])
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeAlertDefaults() -> UserDefaults {
        let suite = "UsageLimitAlertEvaluatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: PreferencesKey.usageLimitNotificationsEnabled)
        defaults.set(true, forKey: PreferencesKey.usageLimitNotificationCodexEnabled)
        defaults.set(true, forKey: PreferencesKey.usageLimitNotificationClaudeEnabled)
        defaults.set(true, forKey: PreferencesKey.usageLimitNotificationApproachingEnabled)
        defaults.set(true, forKey: PreferencesKey.usageLimitNotificationProjectedEnabled)
        defaults.set(true, forKey: PreferencesKey.usageLimitNotificationExhaustedEnabled)
        defaults.set(true, forKey: PreferencesKey.usageLimitNotificationFiveHourResetEnabled)
        defaults.set(10, forKey: PreferencesKey.usageLimitNotificationThresholdPercent)
        return defaults
    }

    // MARK: - Legacy Format (0.50)

    func testParsesLegacyTokenCountFormat() throws {
        // Codex 0.50 used separate token_count events with prompt/completion
        let url = fixtureURL("codex_050_legacy")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()

        XCTAssertGreaterThan(lines.count, 0)

        // Find token_count line with info
        let tokenCountLine = lines.first { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  let info = payload["info"],
                  !(info is NSNull) else { return false }
            return type == "token_count"
        }

        XCTAssertNotNil(tokenCountLine, "Should find legacy token_count with info")
    }

    func testToleratesTokenCountWithNullInfo() throws {
        // Codex sometimes emits token_count with info: null
        let url = fixtureURL("codex_050_legacy")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()

        // Find token_count with null info
        let nullInfoLine = lines.first { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { return false }
            if type == "token_count" {
                if let info = payload["info"], info is NSNull {
                    return true
                }
            }
            return false
        }

        XCTAssertNotNil(nullInfoLine, "Should find token_count with null info")
        // Parser should handle this gracefully without crashing
    }

    // MARK: - Modern Format (0.51+)

    func testParsesTurnCompletedUsageFormat() throws {
        // Codex 0.51+ includes usage object directly on turn.completed
        let url = fixtureURL("codex_051_usage")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()

        var foundUsage = false
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  type == "turn.completed",
                  let usage = payload["usage"] as? [String: Any] else { continue }

            foundUsage = true
            inputTokens = usage["input_tokens"] as? Int
            cachedInputTokens = usage["cached_input_tokens"] as? Int
            outputTokens = usage["output_tokens"] as? Int
            break
        }

        XCTAssertTrue(foundUsage, "Should find turn.completed with usage")
        XCTAssertNotNil(inputTokens, "Should have input_tokens")
        XCTAssertNotNil(cachedInputTokens, "Should have cached_input_tokens")
        XCTAssertNotNil(outputTokens, "Should have output_tokens")
        XCTAssertEqual(inputTokens, 1420)
        XCTAssertEqual(cachedInputTokens, 380)
        XCTAssertEqual(outputTokens, 910)
    }

    // MARK: - Raw Item Events (0.52)

    func testIgnoresRawItemEvents() throws {
        // Codex 0.52 adds verbose raw_item events that should be ignored
        let url = fixtureURL("codex_052_raw")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()

        var rawItemCount = 0
        var usageEventCount = 0

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            if type.contains("raw_item") {
                rawItemCount += 1
            } else if type == "turn.completed" && payload["usage"] != nil {
                usageEventCount += 1
            }
        }

        XCTAssertGreaterThan(rawItemCount, 0, "Fixture should contain raw_item events")
        XCTAssertGreaterThan(usageEventCount, 0, "Fixture should contain usage events")
        // Parser should process usage events without crashing on raw_item
    }

    // MARK: - Rate Limits & Reasoning Tokens (0.53)

    func testParsesReasoningOutputTokens() throws {
        // Codex 0.53 adds reasoning_output_tokens field
        let url = fixtureURL("codex_053_rate_limit")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()

        var foundReasoningTokens = false
        var reasoningTokens: Int?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  type == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let lastUsage = info["last_token_usage"] as? [String: Any] else { continue }

            if let reasoning = lastUsage["reasoning_output_tokens"] as? Int {
                foundReasoningTokens = true
                reasoningTokens = reasoning
                break
            }
        }

        XCTAssertTrue(foundReasoningTokens, "Should find reasoning_output_tokens")
        XCTAssertEqual(reasoningTokens, 128)
    }

    func testExtractsAbsoluteResetTimes() throws {
        // Codex 0.53 provides absolute reset times (epoch seconds or ISO8601)
        let url = fixtureURL("codex_053_rate_limit")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()

        var foundEpochReset = false
        var foundIsoReset = false

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }

            // Check token_count rate_limits for epoch seconds
            if let rateLimits = payload["rate_limits"] as? [String: Any],
               let primary = rateLimits["primary"] as? [String: Any],
               let resetsAt = primary["resets_at"] as? Int {
                foundEpochReset = true
                XCTAssertGreaterThan(resetsAt, 1700000000, "Should be a valid epoch timestamp")
            }

            // Check error payload for ISO8601 reset time
            if let error = payload["error"] as? [String: Any],
               let resetAt = error["resetAt"] as? String {
                foundIsoReset = true
                XCTAssertTrue(resetAt.contains("Z") || resetAt.contains("T"), "Should be ISO8601 format")
            }
        }

        XCTAssertTrue(foundEpochReset, "Should find epoch reset time")
        XCTAssertTrue(foundIsoReset, "Should find ISO8601 reset time")
    }

    func testParsesAccountRateLimitUpdates() throws {
        // Codex 0.53 can emit account/rateLimits/updated notifications
        let url = fixtureURL("codex_053_rate_limit")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()

        var foundAccountUpdate = false

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            if type.contains("rateLimits") || type.contains("rate_limits") {
                foundAccountUpdate = true
                XCTAssertNotNil(payload["rate_limits"], "Should have rate_limits object")
            }
        }

        XCTAssertTrue(foundAccountUpdate, "Should find rate limit update notification")
    }

    func testOAuthNormalizerTagsSnapshotAsOAuthSource() {
        let raw = CodexOAuthRawUsageResponse(
            rateLimit: .init(
                primaryWindow: .init(usedPercent: 4, resetAt: 1_800_000_000, limitWindowSeconds: 18_000),
                secondaryWindow: .init(usedPercent: 1, resetAt: 1_800_100_000, limitWindowSeconds: 604_800)
            )
        )

        let snapshot = CodexOAuthUsageFetcher.normalizeForTesting(raw)

        XCTAssertEqual(snapshot?.limitsSource, .oauth)
        XCTAssertEqual(snapshot?.fiveHourRemainingPercent, 96)
        XCTAssertEqual(snapshot?.weekRemainingPercent, 99)
    }

    func testOAuthNormalizerMarksOnlyReturnedWindowAsAvailable() {
        let raw = CodexOAuthRawUsageResponse(
            rateLimit: .init(
                primaryWindow: .init(usedPercent: 4, resetAt: 1_800_000_000, limitWindowSeconds: 18_000),
                secondaryWindow: nil
            )
        )

        let snapshot = CodexOAuthUsageFetcher.normalizeForTesting(raw)

        XCTAssertEqual(snapshot?.limitsSource, .oauth)
        XCTAssertEqual(snapshot?.fiveHourRemainingPercent, 96)
        XCTAssertEqual(snapshot?.hasFiveHourRateLimit, true)
        XCTAssertEqual(snapshot?.hasWeekRateLimit, false)
    }

    func testCLIRPCProbeTagsSnapshotAsCLIRPCSource() throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "result": [
                "rateLimits": [
                    "primary": [
                        "usedPercent": 4,
                        "resetsAt": 1_800_000_000
                    ],
                    "secondary": [
                        "usedPercent": 1,
                        "resetsAt": 1_800_100_000
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let snapshot = CodexCLIRPCProbe.parseRateLimitsResponseForTesting(data)

        XCTAssertEqual(snapshot?.limitsSource, .cliRPC)
        XCTAssertEqual(snapshot?.fiveHourRemainingPercent, 96)
        XCTAssertEqual(snapshot?.weekRemainingPercent, 99)
    }

    func testCLIRPCProbeMarksOnlyReturnedWindowAsAvailable() throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "result": [
                "rateLimits": [
                    "secondary": [
                        "usedPercent": 1,
                        "resetsAt": 1_800_100_000
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        let snapshot = CodexCLIRPCProbe.parseRateLimitsResponseForTesting(data)

        XCTAssertEqual(snapshot?.limitsSource, .cliRPC)
        XCTAssertEqual(snapshot?.hasFiveHourRateLimit, false)
        XCTAssertEqual(snapshot?.hasWeekRateLimit, true)
        XCTAssertEqual(snapshot?.weekRemainingPercent, 99)
    }

    func testCLIRPCProbeUsesCurrentAppServerArguments() {
        XCTAssertEqual(
            CodexCLIRPCProbe.appServerArgumentsForTesting,
            ["app-server", "--listen", "stdio://"]
        )
        XCTAssertFalse(CodexCLIRPCProbe.appServerArgumentsForTesting.contains("--session-source"))
    }

    // MARK: - Length-based window classification
    //
    // 2026-07-13: OpenAI dropped the 5h window; the weekly window (window_minutes
    // 10080) moved into the `primary` slot with `secondary` null. Windows must be
    // routed by length, not slot position, and uninterpretable data must not show
    // a guessed number.

    func testClassifierRoutesByLengthNotSlotPosition() {
        // Weekly window in the "primary" argument, short window in "secondary".
        let long = CodexRateLimitWindowInput(remainingPercent: 88, resetAt: nil, windowMinutes: 10080)
        let short = CodexRateLimitWindowInput(remainingPercent: 40, resetAt: nil, windowMinutes: 300)
        let routing = CodexRateLimitWindowClassifier.route(long, short)
        XCTAssertEqual(routing.fiveHour?.windowMinutes, 300)
        XCTAssertEqual(routing.weekly?.windowMinutes, 10080)
        XCTAssertFalse(routing.suspect)
    }

    func testClassifierDroppedFiveHourKeepsWeeklyOnlyNotSuspect() {
        let weekly = CodexRateLimitWindowInput(remainingPercent: 88, resetAt: nil, windowMinutes: 10080)
        let routing = CodexRateLimitWindowClassifier.route(weekly, nil)
        XCTAssertNil(routing.fiveHour, "No short window classified")
        XCTAssertEqual(routing.weekly?.remainingPercent, 88)
        XCTAssertFalse(routing.suspect, "A missing window is absence, not suspect")
    }

    func testClassifierLengthlessResponseFallsBackToPositional() {
        // No window declares a length (legacy source): keep primary=5h, secondary=weekly.
        let a = CodexRateLimitWindowInput(remainingPercent: 96, resetAt: nil, windowMinutes: nil)
        let b = CodexRateLimitWindowInput(remainingPercent: 99, resetAt: nil, windowMinutes: nil)
        let routing = CodexRateLimitWindowClassifier.route(a, b)
        XCTAssertEqual(routing.fiveHour?.remainingPercent, 96)
        XCTAssertEqual(routing.weekly?.remainingPercent, 99)
        XCTAssertFalse(routing.suspect)
    }

    func testClassifierUnclassifiableLengthIsSuspectButShowsGoodWindow() {
        let garbage = CodexRateLimitWindowInput(remainingPercent: 50, resetAt: nil, windowMinutes: 9_999_999)
        let weekly = CodexRateLimitWindowInput(remainingPercent: 88, resetAt: nil, windowMinutes: 10080)
        let routing = CodexRateLimitWindowClassifier.route(garbage, weekly)
        XCTAssertTrue(routing.suspect, "An implausible window length is suspect")
        XCTAssertNil(routing.fiveHour)
        XCTAssertEqual(routing.weekly?.windowMinutes, 10080, "The valid weekly window is still shown")
    }

    func testClassifierOutOfRangePercentIsSuspect() {
        let bad = CodexRateLimitWindowInput(remainingPercent: 250, resetAt: nil, windowMinutes: 300)
        let routing = CodexRateLimitWindowClassifier.route(bad, nil)
        XCTAssertTrue(routing.suspect)
        XCTAssertNil(routing.fiveHour)
    }

    func testClassifierTwoWindowsOfSameClassAreSuspect() {
        let longA = CodexRateLimitWindowInput(remainingPercent: 80, resetAt: nil, windowMinutes: 10080)
        let longB = CodexRateLimitWindowInput(remainingPercent: 70, resetAt: nil, windowMinutes: 20160)
        let routing = CodexRateLimitWindowClassifier.route(longA, longB)
        XCTAssertTrue(routing.suspect, "Two long windows can't be disambiguated")
    }

    func testJSONLDroppedFiveHourRoutesWeeklyWindowToWeeklyLine() async throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
        let weeklyReset = Int(now.addingTimeInterval(6 * 24 * 3600).timeIntervalSince1970)
        // Live 2026-07-13 shape: weekly window (10080) in `primary`, no `secondary`.
        let line: [String: Any] = [
            "timestamp": ts,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex",
                    "primary": [
                        "used_percent": 12.0,
                        "window_minutes": 10080,
                        "resets_at": weeklyReset
                    ]
                    // `secondary` intentionally omitted (null in the wild)
                ]
            ]
        ]
        let url = try writeTempJSONL([line])
        defer { try? FileManager.default.removeItem(at: url) }
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let summary = await service.parseTokenCountTailForTesting(url: url)
        XCTAssertNotNil(summary)
        XCTAssertNil(summary?.fiveHour.remainingPercent, "No 5h window → 5h line stays empty")
        XCTAssertEqual(summary?.weekly.remainingPercent, 88, "Weekly window shown on the weekly line, not mislabeled 5h")
        XCTAssertEqual(summary?.suspect, false, "A recognized dropped-5h shape is not suspect")
    }

    func testJSONLFiveHourRestoredRoutesBothWindows() async throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
        let fiveHourReset = Int(now.addingTimeInterval(3 * 3600).timeIntervalSince1970)
        let weeklyReset = Int(now.addingTimeInterval(6 * 24 * 3600).timeIntervalSince1970)
        let line: [String: Any] = [
            "timestamp": ts,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex",
                    "primary": ["used_percent": 30.0, "window_minutes": 300, "resets_at": fiveHourReset],
                    "secondary": ["used_percent": 12.0, "window_minutes": 10080, "resets_at": weeklyReset]
                ]
            ]
        ]
        let url = try writeTempJSONL([line])
        defer { try? FileManager.default.removeItem(at: url) }
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let summary = await service.parseTokenCountTailForTesting(url: url)
        XCTAssertEqual(summary?.fiveHour.remainingPercent, 70, "5h window restored → 5h line populated (auto-recovery)")
        XCTAssertEqual(summary?.weekly.remainingPercent, 88)
        XCTAssertEqual(summary?.suspect, false)
    }

    func testOAuthDroppedFiveHourRoutesWeeklyWindowToWeeklyLine() {
        // primary_window carries the weekly window (limit_window_seconds 604800),
        // secondary_window null. It must land on the weekly line, not "5h".
        let raw = CodexOAuthRawUsageResponse(
            rateLimit: .init(
                primaryWindow: .init(usedPercent: 12, resetAt: 1_800_000_000, limitWindowSeconds: 604_800),
                secondaryWindow: nil
            )
        )
        let snapshot = CodexOAuthUsageFetcher.normalizeForTesting(raw)
        XCTAssertEqual(snapshot?.hasFiveHourRateLimit, false, "No 5h window")
        XCTAssertEqual(snapshot?.hasWeekRateLimit, true)
        XCTAssertEqual(snapshot?.weekRemainingPercent, 88)
        XCTAssertEqual(snapshot?.usageFormatSuspect, false)
    }

    func testOAuthPartlyUninterpretableIsSuspectButShowsGoodWindow() {
        let raw = CodexOAuthRawUsageResponse(
            rateLimit: .init(
                primaryWindow: .init(usedPercent: 12, resetAt: 1_800_000_000, limitWindowSeconds: 604_800),
                secondaryWindow: .init(usedPercent: 5, resetAt: 1_800_100_000, limitWindowSeconds: 999_999_999)
            )
        )
        let snapshot = CodexOAuthUsageFetcher.normalizeForTesting(raw)
        XCTAssertEqual(snapshot?.hasWeekRateLimit, true)
        XCTAssertEqual(snapshot?.weekRemainingPercent, 88)
        XCTAssertEqual(snapshot?.usageFormatSuspect, true, "Garbage window trips the guardrail; the good one still shows")
    }

    func testOAuthFullyUninterpretableReturnsNilSoUIStaysReconnecting() {
        // Nothing placeable → return nil so the app shows its calm reconnecting
        // state, NOT an alarming "can't verify". A length-less/garbage lone window
        // (common on the CLI-RPC/OAuth path during the connect window) must not
        // hijack the meter. Partial drift still surfaces (covered separately).
        let raw = CodexOAuthRawUsageResponse(
            rateLimit: .init(
                primaryWindow: .init(usedPercent: 5, resetAt: 1_800_000_000, limitWindowSeconds: 999_999_999),
                secondaryWindow: nil
            )
        )
        XCTAssertNil(CodexOAuthUsageFetcher.normalizeForTesting(raw),
                     "A zero-window (suspect) response falls through instead of surfacing 'can't verify'")
    }

    func testClassifierLoneLengthlessPrimaryIsSuspect() {
        // Dropped-5h on a length-less source: a lone primary window can't be
        // confirmed as 5h, so it is suspect rather than positionally mislabeled.
        let lone = CodexRateLimitWindowInput(remainingPercent: 88, resetAt: nil, windowMinutes: nil)
        let routing = CodexRateLimitWindowClassifier.route(lone, nil)
        XCTAssertTrue(routing.suspect)
        XCTAssertNil(routing.fiveHour)
        XCTAssertNil(routing.weekly)
    }

    func testClassifierLoneLengthlessSecondaryIsWeekly() {
        let lone = CodexRateLimitWindowInput(remainingPercent: 99, resetAt: nil, windowMinutes: nil)
        let routing = CodexRateLimitWindowClassifier.route(nil, lone)
        XCTAssertEqual(routing.weekly?.remainingPercent, 99)
        XCTAssertNil(routing.fiveHour)
        XCTAssertFalse(routing.suspect)
    }

    func testAuthoritativeReplaceClearsDroppedFiveHourWindow() async {
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        // Seed a snapshot where the 5h window was present from an earlier poll.
        await service.setSnapshotForTesting(
            CodexUsageSnapshot(
                fiveHourRemainingPercent: 40,
                fiveHourResetText: "2026-07-13T18:00:00Z",
                hasFiveHourRateLimit: true,
                fiveHourLimitsSource: .oauth,
                weekRemainingPercent: 88,
                weekResetText: "2026-07-19T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .oauth,
                limitsSource: .oauth
            )
        )
        // Next complete authoritative fetch has only the weekly window (5h dropped).
        let merged = await service.mergeRateLimitSnapshotForTesting(
            CodexUsageSnapshot(
                weekRemainingPercent: 86,
                weekResetText: "2026-07-19T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .oauth,
                limitsSource: .oauth
            ),
            replacesMissingWindows: true
        )
        XCTAssertFalse(merged.hasFiveHourRateLimit, "Dropped 5h window is cleared, not frozen")
        XCTAssertEqual(merged.fiveHourRemainingPercent, 0)
        XCTAssertEqual(merged.fiveHourResetText, "")
        XCTAssertNil(merged.fiveHourLimitsSource)
        XCTAssertTrue(merged.hasWeekRateLimit, "Weekly window preserved/updated")
        XCTAssertEqual(merged.weekRemainingPercent, 86)
    }

    func testFragmentMergeDoesNotClearMissingWindow() async {
        // A tmux /status fragment (requirePositivePercent, not a complete fetch)
        // must stay additive — it never clears a window it simply didn't parse.
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.setSnapshotForTesting(
            CodexUsageSnapshot(
                fiveHourRemainingPercent: 40,
                fiveHourResetText: "2026-07-13T18:00:00Z",
                hasFiveHourRateLimit: true,
                fiveHourLimitsSource: .jsonlFallback,
                weekRemainingPercent: 88,
                weekResetText: "2026-07-19T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .jsonlFallback,
                limitsSource: .jsonlFallback
            )
        )
        let merged = await service.mergeRateLimitSnapshotForTesting(
            CodexUsageSnapshot(
                weekRemainingPercent: 80,
                weekResetText: "2026-07-19T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .statusProbe,
                limitsSource: .statusProbe
            ),
            requirePositivePercent: true
        )
        XCTAssertTrue(merged.hasFiveHourRateLimit, "Fragment must not clear the unparsed 5h window")
        XCTAssertEqual(merged.fiveHourRemainingPercent, 40)
    }

    func testFragmentMergeDoesNotClearSuspectVerdict() async {
        // parseStatusJSON (tmux /status) never computes a format verdict, so a
        // fragment merge must not clobber a real "can't verify" set by the last
        // authoritative (OAuth/CLI-RPC) fetch back to false.
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.setSnapshotForTesting(
            CodexUsageSnapshot(
                weekRemainingPercent: 88,
                weekResetText: "2026-07-19T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .oauth,
                limitsSource: .oauth,
                usageFormatSuspect: true
            )
        )
        let merged = await service.mergeRateLimitSnapshotForTesting(
            CodexUsageSnapshot(
                weekRemainingPercent: 80,
                weekResetText: "2026-07-19T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .statusProbe,
                limitsSource: .statusProbe
            ),
            requirePositivePercent: true
        )
        XCTAssertTrue(merged.usageFormatSuspect, "Fragment merge must not clear a real suspect verdict")
    }

    func testAuthoritativeMergeUpdatesSuspectVerdict() async {
        // A complete authoritative fetch (replacesMissingWindows) owns the format
        // verdict — it both sets and clears `usageFormatSuspect`.
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.setSnapshotForTesting(
            CodexUsageSnapshot(usageFormatSuspect: true)
        )
        let merged = await service.mergeRateLimitSnapshotForTesting(
            CodexUsageSnapshot(
                weekRemainingPercent: 80,
                weekResetText: "2026-07-19T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .oauth,
                limitsSource: .oauth
            ),
            replacesMissingWindows: true
        )
        XCTAssertFalse(merged.usageFormatSuspect, "Authoritative fetch clears a stale suspect verdict")
    }

    func testStatusProbeParserMarksReturnedWindowsAsAvailable() async {
        let json = """
        {
          "ok": true,
          "five_hour": {
            "pct_left": 82,
            "resets": "resets in 3h"
          }
        }
        """

        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let snapshot = await service.parseStatusJSONForTesting(json)

        XCTAssertEqual(snapshot?.limitsSource, .statusProbe)
        XCTAssertEqual(snapshot?.hasFiveHourRateLimit, true)
        XCTAssertEqual(snapshot?.fiveHourLimitsSource, .statusProbe)
        XCTAssertEqual(snapshot?.hasWeekRateLimit, false)
    }

    func testStatusProbeParserIgnoresResetOnlyWindowWithoutPercent() async {
        let json = """
        {
          "ok": true,
          "five_hour": {
            "pct_left": null,
            "resets": "resets in 3h"
          },
          "weekly": {
            "pct_left": 0,
            "resets": "resets in 2d"
          }
        }
        """

        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let snapshot = await service.parseStatusJSONForTesting(json)

        XCTAssertEqual(snapshot?.hasFiveHourRateLimit, false)
        XCTAssertNil(snapshot?.fiveHourLimitsSource)
        XCTAssertEqual(snapshot?.hasWeekRateLimit, true)
        XCTAssertEqual(snapshot?.weekRemainingPercent, 0)
        XCTAssertEqual(snapshot?.weekLimitsSource, .statusProbe)
        XCTAssertEqual(snapshot?.limitsSource, .statusProbe)
    }

    func testPartialAuthoritativeMergeDoesNotMarkWholeSnapshotAuthoritative() async {
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.setSnapshotForTesting(
            CodexUsageSnapshot(
                fiveHourRemainingPercent: 87,
                fiveHourResetText: "2026-03-28T18:00:00Z",
                hasFiveHourRateLimit: true,
                fiveHourLimitsSource: .jsonlFallback,
                weekRemainingPercent: 64,
                weekResetText: "2026-04-01T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .jsonlFallback,
                limitsSource: .jsonlFallback
            )
        )

        let merged = await service.mergeRateLimitSnapshotForTesting(
            CodexUsageSnapshot(
                fiveHourRemainingPercent: 91,
                fiveHourResetText: "2026-03-28T19:00:00Z",
                hasFiveHourRateLimit: true,
                fiveHourLimitsSource: .oauth,
                weekRemainingPercent: 0,
                weekResetText: "",
                hasWeekRateLimit: false,
                weekLimitsSource: nil,
                limitsSource: .oauth
            )
        )

        XCTAssertEqual(merged.fiveHourRemainingPercent, 91)
        XCTAssertEqual(merged.fiveHourLimitsSource, .oauth)
        XCTAssertEqual(merged.weekRemainingPercent, 64)
        XCTAssertEqual(merged.weekLimitsSource, .jsonlFallback)
        XCTAssertNil(merged.limitsSource)
        let hasAuthoritative = await service.hasAuthoritativeLimitsSnapshotForTesting
        XCTAssertFalse(hasAuthoritative)
    }

    func testJSONLFallbackDoesNotOverwriteAuthoritativeLiveLimits() async {
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let previousEventTimestamp = ISO8601DateFormatter().date(from: "2026-03-28T19:05:00Z")
        let summaryEventTimestamp = ISO8601DateFormatter().date(from: "2026-03-28T19:10:00Z")
        let summaryFiveHourReset = ISO8601DateFormatter().date(from: "2026-03-28T17:00:00Z")
        await service.setSnapshotForTesting(
            CodexUsageSnapshot(
                fiveHourRemainingPercent: 91,
                fiveHourResetText: "2026-03-28T19:00:00Z",
                hasFiveHourRateLimit: true,
                fiveHourLimitsSource: .oauth,
                weekRemainingPercent: 44,
                weekResetText: "2026-04-01T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .cliRPC,
                limitsSource: nil,
                usageLine: nil,
                eventTimestamp: previousEventTimestamp
            )
        )

        let merged = await service.applyJSONLFallbackSummaryForTesting(
            RateLimitSummary(
                fiveHour: RateLimitWindowInfo(
                    remainingPercent: 32,
                    resetAt: summaryFiveHourReset,
                    windowMinutes: 300
                ),
                weekly: RateLimitWindowInfo(
                    remainingPercent: 18,
                    resetAt: ISO8601DateFormatter().date(from: "2026-03-31T00:00:00Z"),
                    windowMinutes: nil
                ),
                eventTimestamp: summaryEventTimestamp,
                stale: true,
                sourceFile: nil
            )
        )

        XCTAssertEqual(merged.fiveHourRemainingPercent, 91)
        XCTAssertEqual(merged.fiveHourLimitsSource, .oauth)
        XCTAssertEqual(merged.weekRemainingPercent, 44)
        XCTAssertEqual(merged.weekLimitsSource, .cliRPC)
        XCTAssertEqual(merged.usageLine, "Usage is stale (>3m)")
        XCTAssertEqual(merged.eventTimestamp, summaryEventTimestamp)
        let cachedReset = await service.lastFiveHourResetDateForTesting
        XCTAssertEqual(cachedReset, summaryFiveHourReset)
    }

    func testStatusProbeMergePreservesValidZeroPercentBuckets() async {
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.setSnapshotForTesting(
            CodexUsageSnapshot(
                fiveHourRemainingPercent: 63,
                fiveHourResetText: "2026-03-28T18:00:00Z",
                hasFiveHourRateLimit: true,
                fiveHourLimitsSource: .jsonlFallback,
                weekRemainingPercent: 41,
                weekResetText: "2026-04-01T00:00:00Z",
                hasWeekRateLimit: true,
                weekLimitsSource: .jsonlFallback,
                limitsSource: .jsonlFallback
            )
        )

        let merged = await service.mergeRateLimitSnapshotForTesting(
            CodexUsageSnapshot(
                fiveHourRemainingPercent: 12,
                fiveHourResetText: "2026-03-28T19:00:00Z",
                hasFiveHourRateLimit: true,
                fiveHourLimitsSource: .statusProbe,
                weekRemainingPercent: 0,
                weekResetText: "",
                hasWeekRateLimit: true,
                weekLimitsSource: .statusProbe,
                limitsSource: .statusProbe
            ),
            requirePositivePercent: true
        )

        XCTAssertEqual(merged.fiveHourRemainingPercent, 12)
        XCTAssertEqual(merged.fiveHourLimitsSource, .statusProbe)
        XCTAssertEqual(merged.weekRemainingPercent, 0)
        XCTAssertEqual(merged.weekLimitsSource, .statusProbe)
        XCTAssertEqual(merged.limitsSource, .statusProbe)
        let hasAuthoritative = await service.hasAuthoritativeLimitsSnapshotForTesting
        XCTAssertTrue(hasAuthoritative)
    }

    func testPrefersCodexLimitIDWhenDualLimitBucketsExist() async throws {
        let now = Date()
        let olderTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-6))
        let newerTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
        let resetAt = Int(now.addingTimeInterval(3600).timeIntervalSince1970)

        let codexLine: [String: Any] = [
            "timestamp": olderTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex",
                    "primary": [
                        "used_percent": 20.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 15.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let bengalfoxLine: [String: Any] = [
            "timestamp": newerTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex_bengalfox",
                    "primary": [
                        "used_percent": 0.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 0.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let url = try writeTempJSONL([codexLine, bengalfoxLine])
        defer { try? FileManager.default.removeItem(at: url) }

        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let summary = await service.parseTokenCountTailForTesting(url: url)

        XCTAssertNotNil(summary, "Parser should extract a rate-limit summary")
        XCTAssertEqual(summary?.fiveHour.remainingPercent, 80, "Should prioritize the codex account bucket over spark bucket")
        XCTAssertEqual(summary?.weekly.remainingPercent, 85, "Should keep secondary remaining percentage from codex bucket")
    }

    func testPrefersMissingLimitIDBucketOverNonCodexLimitID() async throws {
        let now = Date()
        let olderTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-6))
        let newerTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
        let resetAt = Int(now.addingTimeInterval(3600).timeIntervalSince1970)

        let unlabeledCodexLine: [String: Any] = [
            "timestamp": olderTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "primary": [
                        "used_percent": 35.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 25.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let bengalfoxLine: [String: Any] = [
            "timestamp": newerTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex_bengalfox",
                    "primary": [
                        "used_percent": 0.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 0.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let url = try writeTempJSONL([unlabeledCodexLine, bengalfoxLine])
        defer { try? FileManager.default.removeItem(at: url) }

        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let summary = await service.parseTokenCountTailForTesting(url: url)

        XCTAssertNotNil(summary, "Parser should extract a rate-limit summary")
        XCTAssertEqual(summary?.fiveHour.remainingPercent, 65, "Should treat missing limit_id in primary rate_limits as preferred codex stream")
        XCTAssertEqual(summary?.weekly.remainingPercent, 75, "Should keep secondary remaining percentage from unlabeled codex stream")
    }

    func testUsageParsingContinuesWhileSearchingForCodexLimitID() async throws {
        let now = Date()
        let olderTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
        let midTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-6))
        let newerTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
        let resetAt = Int(now.addingTimeInterval(3600).timeIntervalSince1970)

        let codexLine: [String: Any] = [
            "timestamp": olderTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex",
                    "primary": [
                        "used_percent": 40.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 30.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let usageLine: [String: Any] = [
            "timestamp": midTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "turn.completed",
                "usage": [
                    "input_tokens": 1200,
                    "cached_input_tokens": 200,
                    "output_tokens": 300,
                    "reasoning_output_tokens": 75,
                    "total_tokens": 1500
                ]
            ]
        ]

        let nonCodexNewestLine: [String: Any] = [
            "timestamp": newerTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex_bengalfox",
                    "primary": [
                        "used_percent": 0.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 0.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let url = try writeTempJSONL([codexLine, usageLine, nonCodexNewestLine])
        defer { try? FileManager.default.removeItem(at: url) }

        let lock = NSLock()
        var snapshots: [CodexUsageSnapshot] = []

        let service = CodexStatusService(
            updateHandler: { snapshot in
                lock.lock()
                snapshots.append(snapshot)
                lock.unlock()
            },
            availabilityHandler: { _ in }
        )
        let summary = await service.parseTokenCountTailForTesting(url: url)

        XCTAssertNotNil(summary, "Parser should still return a preferred codex rate-limit summary")
        XCTAssertEqual(summary?.fiveHour.remainingPercent, 60, "Should return codex primary remaining percent")
        XCTAssertEqual(summary?.weekly.remainingPercent, 70, "Should return codex secondary remaining percent")

        lock.lock()
        let usageSnapshot = snapshots.last
        lock.unlock()

        XCTAssertNotNil(usageSnapshot, "Parser should emit at least one usage snapshot update")
        XCTAssertEqual(usageSnapshot?.lastInputTokens, 1200, "Usage extraction should stay active while searching for codex limit_id")
        XCTAssertEqual(usageSnapshot?.lastCachedInputTokens, 200)
        XCTAssertEqual(usageSnapshot?.lastOutputTokens, 300)
        XCTAssertEqual(usageSnapshot?.lastReasoningOutputTokens, 75)
        XCTAssertEqual(usageSnapshot?.lastTotalTokens, 1500)
    }

    func testUsageLimitAlertEvaluatorAlertsOncePerLowFiveHourWindow() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(45 * 60)
        let snapshot = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 9,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false
        )

        let first = evaluator.evaluate(snapshot: snapshot, now: now)
        let second = evaluator.evaluate(snapshot: snapshot, now: now.addingTimeInterval(60))

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.kind, .approaching)
        XCTAssertEqual(first.first?.window, .fiveHour)
        XCTAssertEqual(second, [])
    }

    func testUsageLimitAlertEvaluatorSchedulesFutureFiveHourReset() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(90 * 60)
        let snapshot = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 3,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false
        )

        let event = evaluator.scheduledFiveHourReset(snapshot: snapshot, now: now)

        XCTAssertEqual(event?.kind, .resetComplete)
        XCTAssertEqual(event?.window, .fiveHour)
        XCTAssertEqual(event?.resetDate, reset)
        XCTAssertTrue(event?.identifier.contains("codex-limit-reset-five-hour") ?? false)
    }

    func testUsageLimitAlertEvaluatorEmitsResetCompleteWhenFiveHourWindowRollsForward() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldReset = now.addingTimeInterval(-60)
        let nextReset = now.addingTimeInterval(5 * 60 * 60)
        let exhausted = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 0,
            fiveHourResetText: formatResetISO8601(oldReset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false
        )
        let recovered = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 100,
            fiveHourResetText: formatResetISO8601(nextReset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false
        )

        _ = evaluator.evaluate(snapshot: exhausted, now: now.addingTimeInterval(-120))
        let events = evaluator.evaluate(snapshot: recovered, now: now)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .resetComplete)
        XCTAssertEqual(events.first?.window, .fiveHour)
    }

    func testUsageLimitAlertEvaluatorSupportsClaudeWeeklyLimit() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        let snapshot = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 80,
            fiveHourResetText: "",
            hasFiveHourRateLimit: false,
            weeklyRemainingPercent: 8,
            weeklyResetText: formatResetISO8601(weeklyReset),
            hasWeeklyRateLimit: true
        )

        let events = evaluator.evaluate(snapshot: snapshot, now: now)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.provider, .claude)
        XCTAssertEqual(events.first?.kind, .approaching)
        XCTAssertEqual(events.first?.window, .weekly)
    }

    func testUsageLimitAlertEvaluatorKeepsBurnETAOnLowAlert() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 40,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false
        )
        let second = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 8,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let events = evaluator.evaluate(snapshot: second, now: now.addingTimeInterval(24 * 60))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .approaching)
        XCTAssertEqual(events.first?.window, .fiveHour)
        XCTAssertEqual(events.first?.projectedSecondsUntilEmpty ?? 0, 6 * 60, accuracy: 0.001)
        XCTAssertEqual(events.first?.title, "Codex 5h usage is low")
        XCTAssertTrue(events.first?.body.contains("8% remaining, burning to empty in about 6m") ?? false)
    }

    func testUsageLimitAlertEvaluatorUsesReadableWeeklyProjectionCopy() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 80,
            fiveHourResetText: "",
            hasFiveHourRateLimit: false,
            weeklyRemainingPercent: 40,
            weeklyResetText: formatResetISO8601(weeklyReset),
            hasWeeklyRateLimit: true
        )
        let second = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 80,
            fiveHourResetText: "",
            hasFiveHourRateLimit: false,
            weeklyRemainingPercent: 20,
            weeklyResetText: formatResetISO8601(weeklyReset),
            hasWeeklyRateLimit: true
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let events = evaluator.evaluate(snapshot: second, now: now.addingTimeInterval(30 * 60))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .projectedExhaustion)
        XCTAssertEqual(events.first?.window, .weekly)
        XCTAssertEqual(events.first?.projectedSecondsUntilEmpty ?? 0, 30 * 60, accuracy: 0.001)
        XCTAssertTrue(events.first?.title.contains("weekly usage is burning fast") ?? false)
        XCTAssertTrue(events.first?.body.contains("20% remaining, burning to empty in about 30m") ?? false)
    }

    func testLimitAlertReadinessFormatterReportsUserFacingStates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let observedAt = now.addingTimeInterval(-60).timeIntervalSince1970
        let runoutAt = now.addingTimeInterval(20 * 60).timeIntervalSince1970

        func readiness(source: String = "OAuth",
                       freshness: String = "fresh",
                       observedAt: Double = observedAt,
                       projection: String = "Waiting for next sample",
                       projectionRunoutAt: Double = 0,
                       projectionObservedAt: Double = 0,
                       delivery: String = "",
                       deliveryAt: Double = 0,
                       notificationsEnabled: Bool = true,
                       providerEnabled: Bool = true,
                       visualEnabled: Bool = true,
                       soundEnabled: Bool = true) -> String {
            LimitAlertReadinessFormatter.text(
                provider: "Codex",
                source: source,
                freshness: freshness,
                observedAt: observedAt,
                projection: projection,
                projectionRunoutAt: projectionRunoutAt,
                projectionObservedAt: projectionObservedAt,
                delivery: delivery,
                deliveryAt: deliveryAt,
                notificationsEnabled: notificationsEnabled,
                providerEnabled: providerEnabled,
                visualEnabled: visualEnabled,
                soundEnabled: soundEnabled,
                now: now
            )
        }

        XCTAssertEqual(readiness(notificationsEnabled: false), "Alerts off")
        XCTAssertEqual(readiness(providerEnabled: false), "Alerts off for Codex")
        XCTAssertEqual(readiness(visualEnabled: false, soundEnabled: false), "Delivery off")
        XCTAssertEqual(readiness(source: "", observedAt: 0), "Waiting for usage data")
        XCTAssertEqual(readiness(freshness: "stale"), "Stale; alerts may be delayed")
        XCTAssertEqual(readiness(observedAt: now.addingTimeInterval(-11 * 60).timeIntervalSince1970), "Stale; alerts may be delayed")
        XCTAssertEqual(readiness(
            projection: "Active ▸21m",
            projectionRunoutAt: runoutAt,
            projectionObservedAt: observedAt
        ), "Watching active 5h burn")
        XCTAssertEqual(readiness(
            delivery: "Banners denied",
            deliveryAt: observedAt,
            visualEnabled: false,
            soundEnabled: true
        ), "Ready; sound only")
        XCTAssertEqual(readiness(
            delivery: "Banners denied",
            deliveryAt: observedAt
        ), "Notifications need attention")
        XCTAssertEqual(readiness(
            projection: "Active ▸21m",
            projectionRunoutAt: runoutAt,
            projectionObservedAt: observedAt,
            delivery: "Banners denied",
            deliveryAt: observedAt
        ), "Notifications need attention")
        XCTAssertEqual(readiness(), "Ready")
    }

    func testUsageLimitAlertEvaluatorRespectsWarningTypeToggles() {
        let defaults = makeAlertDefaults()
        defaults.set(false, forKey: PreferencesKey.usageLimitNotificationApproachingEnabled)
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 8,
            fiveHourResetText: formatResetISO8601(now.addingTimeInterval(30 * 60)),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false
        )

        let events = evaluator.evaluate(snapshot: snapshot, now: now)

        XCTAssertEqual(events, [])
    }

    func testUsageLimitAlertEvaluatorPredictsFastFiveHourExhaustionBeforeLowThreshold() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4.5 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 90,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let second = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 60,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let events = evaluator.evaluate(snapshot: second, now: now.addingTimeInterval(30 * 60))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .projectedExhaustion)
        XCTAssertEqual(events.first?.window, .fiveHour)
        XCTAssertEqual(events.first?.remainingPercent, 60)
    }

    func testUsageLimitProjectionTrackerFormatsCompactRunoutToken() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        let first = UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        )
        let second = UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        )

        XCTAssertNil(tracker.update(with: first, now: firstTime))
        let estimate = tracker.update(with: second, now: secondTime)

        XCTAssertEqual(formatUsageProjectionLabel(runoutAt: estimate?.runoutAt, observedAt: estimate?.observedAt, now: secondTime), "▸44m")
    }

    func testUsageLimitProjectionTrackerShowsBeforeResetMultiHourToken() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(5 * 60)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 96,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        XCTAssertEqual(formatUsageProjectionLabel(runoutAt: estimate?.runoutAt, observedAt: estimate?.observedAt, now: secondTime), "▸2h")
    }

    func testUsageLimitProjectionTrackerStillHidesRunoutAfterReset() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(20 * 60)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 96,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        XCTAssertNil(estimate)
        XCTAssertEqual(tracker.lastDiagnostics, "Run-out after reset")
    }

    func testUsageLimitProjectionTrackerMarksOnTrackWhenRunoutAfterReset() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(20 * 60)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 96,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        // A measured burn that projects run-out after reset is the "on track" state:
        // no early-runout estimate, but we remember when we last measured it fitting.
        XCTAssertNil(estimate)
        XCTAssertEqual(tracker.lastOnTrackObservedAt, secondTime)
    }

    func testUsageLimitProjectionTrackerClearsOnTrackWhenRunningOutEarly() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        // Burning fast enough to run out before reset — that is not the on-track state.
        XCTAssertNotNil(estimate)
        XCTAssertNil(tracker.lastOnTrackObservedAt)
    }

    func testUsageLimitProjectionTrackerHasNoOnTrackBeforeFirstBurn() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: formatResetISO8601(reset),
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        // One sample, no burn measured yet — nothing to smile about.
        XCTAssertNil(tracker.lastOnTrackObservedAt)
    }

    func testUsageOnTrackIsFreshOnlyWithinWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(usageOnTrackIsFresh(observedAt: nil, now: now))
        XCTAssertTrue(usageOnTrackIsFresh(observedAt: now.addingTimeInterval(-120), now: now))
        XCTAssertFalse(usageOnTrackIsFresh(observedAt: now.addingTimeInterval(-4 * 60), now: now))
    }

    func testUsageLimitProjectionTrackerHidesRunoutWhenResetHappensFirst() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000) // 4:24 equivalent
        let secondTime = firstTime.addingTimeInterval(6 * 60) // 4:30 equivalent
        let reset = secondTime.addingTimeInterval(50 * 60) // 5:20 equivalent
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 66,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 60,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        XCTAssertNil(estimate)
        XCTAssertEqual(tracker.lastDiagnostics, "Run-out after reset")
    }

    func testUsageLimitProjectionTrackerHidesRunoutExactlyAtReset() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
        let reset = secondTime.addingTimeInterval(60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 66,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 60,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        XCTAssertNil(estimate)
        XCTAssertEqual(tracker.lastDiagnostics, "Run-out after reset")
    }

    func testUsageLimitProjectionTrackerRetainsProjectionAcrossBriefSameRoundedPercentRefresh() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
        let thirdTime = secondTime.addingTimeInterval(60)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let projected = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        let retained = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: thirdTime
        ), now: thirdTime)

        XCTAssertEqual(retained, projected)
        XCTAssertEqual(retained?.observedAt, secondTime)
        XCTAssertEqual(formatUsageProjectionLabel(runoutAt: retained?.runoutAt, observedAt: retained?.observedAt, now: thirdTime), "▸43m")
    }

    func testUsageLimitProjectionTrackerDoesNotUseSamePercentRefreshAsNextBurnBaseline() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
        let passiveTime = secondTime.addingTimeInterval(60)
        let nextBurnTime = secondTime.addingTimeInterval(6 * 60)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 21,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 21,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: passiveTime
        ), now: passiveTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 20,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: nextBurnTime
        ), now: nextBurnTime)

        XCTAssertEqual(estimate?.observedAt, nextBurnTime)
        XCTAssertEqual(
            formatUsageProjectionLabel(runoutAt: estimate?.runoutAt, observedAt: estimate?.observedAt, now: nextBurnTime),
            "▸2h"
        )
        XCTAssertEqual(tracker.lastDiagnostics, "Active ▸2h")
    }

    // Idle-expiry: once the last measured burn is older than the 3-minute display
    // window, the tracker clears the retained projection and publishes nil — in
    // lockstep with the label gate — rather than holding a "zombie" projection
    // that lingers (armed until runout) behind a merely-hidden label. Mirrors the
    // Codex OAuth idle case where fresh polls keep arriving with no usage drop.
    func testUsageLimitProjectionTrackerClearsRetainedProjectionWhenBurnIsStale() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
        // A fresh idle refresh still inside the window keeps the projection.
        let freshRefresh = secondTime.addingTimeInterval(2 * 60)
        // The next idle refresh crosses the 3-minute burn window.
        let staleTime = secondTime.addingTimeInterval(3 * 60 + 1)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)

        let retainedInWindow = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: freshRefresh
        ), now: freshRefresh)

        // Still fresh: original burn observation retained (observedAt unchanged).
        XCTAssertEqual(retainedInWindow?.observedAt, secondTime)

        let expired = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: staleTime
        ), now: staleTime)

        // Past the window: estimate cleared entirely (nil), not merely gate-hidden.
        XCTAssertNil(expired)
        XCTAssertEqual(tracker.lastDiagnostics, "Projection stale")
    }

    // Idle-expiry must not wedge the tracker: after a stale idle refresh clears
    // the projection, a genuine resume burn re-projects with a fresh observation.
    // (This is the intended slow-burn-across-a-gap behavior — the tracker keeps
    // the pre-gap baseline, so a real usage drop later still projects honestly.)
    func testUsageLimitProjectionTrackerReprojectsAfterStaleClearOnResumeBurn() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let burnTime = firstTime.addingTimeInterval(6 * 60)         // baseline burn 100 -> 88
        let staleRefresh = burnTime.addingTimeInterval(3 * 60 + 1)  // idle, past the window
        let resumeDrop = burnTime.addingTimeInterval(30 * 60)       // usage resumes: 88 -> 70
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: burnTime
        ), now: burnTime)

        // Idle refresh past the 3-minute window: the zombie projection is cleared.
        let cleared = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: staleRefresh
        ), now: staleRefresh)
        XCTAssertNil(cleared)
        XCTAssertEqual(tracker.lastDiagnostics, "Projection stale")

        // Usage genuinely resumes: a fresh drop re-projects with a fresh
        // observation (label shown again), off the retained baseline.
        let resumed = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 70,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: resumeDrop
        ), now: resumeDrop)
        XCTAssertEqual(resumed?.observedAt, resumeDrop)
        XCTAssertNotNil(formatUsageProjectionLabel(runoutAt: resumed?.runoutAt, observedAt: resumed?.observedAt, now: resumeDrop))
    }

    func testUsageLimitProjectionTrackerReportsResetFirstForRetainedProjection() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
        let thirdTime = secondTime.addingTimeInterval(60)
        let initialReset = secondTime.addingTimeInterval(61 * 60)
        let resetMovedBeforeRunout = initialReset.addingTimeInterval(-119)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 11,
            resetText: formatResetISO8601(initialReset),
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let projected = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 10,
            resetText: formatResetISO8601(initialReset),
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime
        ), now: secondTime)
        XCTAssertNotNil(projected)

        let retained = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 10,
            resetText: formatResetISO8601(resetMovedBeforeRunout),
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: thirdTime
        ), now: thirdTime)

        XCTAssertNil(retained)
        XCTAssertEqual(tracker.lastDiagnostics, "Run-out after reset")
    }

    func testUsageLimitProjectionTrackerUsesExactRemainingPercentForClaudeRecentCache() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(2 * 60)
        let reset = firstTime.addingTimeInterval(4.5 * 60 * 60)
        let resetText = formatResetISO8601(reset)

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .claude,
            remainingPercent: 82,
            remainingPercentExact: 82.4,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .claude,
            remainingPercent: 82,
            remainingPercentExact: 81.6,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .recentCached,
            observedAt: secondTime
        ), now: secondTime)

        XCTAssertEqual(formatUsageProjectionLabel(runoutAt: estimate?.runoutAt, observedAt: estimate?.observedAt, now: secondTime), "▸3h 24m")
    }

    func testUsageLimitProjectionTrackerIgnoresStaleCachedData() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
        let resetText = formatResetISO8601(firstTime.addingTimeInterval(4.5 * 60 * 60))

        _ = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 100,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: firstTime
        ), now: firstTime)

        let estimate = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .stale,
            observedAt: secondTime
        ), now: secondTime)

        XCTAssertNil(estimate)
        XCTAssertEqual(tracker.lastDiagnostics, "Stale data")

        let afterStale = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 76,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: secondTime.addingTimeInterval(6 * 60)
        ), now: secondTime.addingTimeInterval(6 * 60))

        XCTAssertNil(afterStale)
        XCTAssertEqual(tracker.lastDiagnostics, "Waiting for next sample")
    }

    func testUsageLimitAlertEvaluatorUsesObservedAtForProjectedExhaustionETA() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let firstObservedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let secondObservedAt = firstObservedAt.addingTimeInterval(6 * 60)
        let deliveryTime = firstObservedAt.addingTimeInterval(30 * 60)
        let reset = firstObservedAt.addingTimeInterval(4.5 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 100,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(firstObservedAt.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true,
            observedAt: firstObservedAt
        )
        let second = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 88,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(firstObservedAt.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true,
            observedAt: secondObservedAt
        )

        _ = evaluator.evaluate(snapshot: first, now: firstObservedAt)
        let events = evaluator.evaluate(snapshot: second, now: deliveryTime)

        XCTAssertEqual(events.first?.kind, .projectedExhaustion)
        XCTAssertEqual(events.first?.projectedSecondsUntilEmpty ?? 0, 44 * 60, accuracy: 0.001)
    }

    func testUsageLimitAlertEvaluatorUsesExactClaudePercentForProjectedExhaustion() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let firstObservedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let secondObservedAt = firstObservedAt.addingTimeInterval(2 * 60)
        let reset = firstObservedAt.addingTimeInterval(4.5 * 60 * 60)
        let weeklyReset = firstObservedAt.addingTimeInterval(2 * 24 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 15,
            fiveHourRemainingPercentExact: 15.8,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(weeklyReset),
            hasWeeklyRateLimit: true,
            observedAt: firstObservedAt,
            sourceDescription: "OAuth"
        )
        let second = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 15,
            fiveHourRemainingPercentExact: 15.2,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(weeklyReset),
            hasWeeklyRateLimit: true,
            observedAt: secondObservedAt,
            sourceDescription: "OAuth"
        )

        _ = evaluator.evaluate(snapshot: first, now: firstObservedAt)
        let events = evaluator.evaluate(snapshot: second, now: secondObservedAt)

        XCTAssertEqual(events.first?.provider, .claude)
        XCTAssertEqual(events.first?.kind, .projectedExhaustion)
        XCTAssertEqual(events.first?.window, .fiveHour)
        XCTAssertEqual(events.first?.remainingPercent, 15)
        XCTAssertEqual(events.first?.projectedSecondsUntilEmpty ?? 0, 50 * 60 + 40, accuracy: 0.001)
    }

    func testUsageLimitProjectionLabelExpiresWhenObservationIsStale() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let runoutAt = observedAt.addingTimeInterval(44 * 60)

        XCTAssertEqual(
            formatUsageProjectionLabel(runoutAt: runoutAt, observedAt: observedAt, now: observedAt.addingTimeInterval(3 * 60)),
            "▸41m"
        )
        XCTAssertNil(
            formatUsageProjectionLabel(runoutAt: runoutAt, observedAt: observedAt, now: observedAt.addingTimeInterval(3 * 60 + 1))
        )
    }

    func testUsageProjectionDiagnosticsTextRecomputesActiveState() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let runoutAt = observedAt.addingTimeInterval(44 * 60)

        XCTAssertEqual(
            formatUsageProjectionDiagnosticsText(
                "Active ▸44m",
                runoutAt: runoutAt.timeIntervalSince1970,
                observedAt: observedAt.timeIntervalSince1970,
                now: observedAt.addingTimeInterval(60)
            ),
            "Active ▸43m"
        )
        XCTAssertEqual(
            formatUsageProjectionDiagnosticsText(
                "Active ▸44m",
                runoutAt: runoutAt.timeIntervalSince1970,
                observedAt: observedAt.timeIntervalSince1970,
                now: observedAt.addingTimeInterval(3 * 60 + 1)
            ),
            "Projection stale"
        )
        XCTAssertEqual(
            formatUsageProjectionDiagnosticsText(
                "Run-out after reset",
                runoutAt: 0,
                observedAt: 0,
                now: observedAt
            ),
            "Run-out after reset"
        )
    }

    func testUsageLimitAlertEvaluatorCanDisablePredictionSeparatelyFromLowThreshold() {
        let defaults = makeAlertDefaults()
        defaults.set(false, forKey: PreferencesKey.usageLimitNotificationProjectedEnabled)
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4.5 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 90,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let second = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 60,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let events = evaluator.evaluate(snapshot: second, now: now.addingTimeInterval(30 * 60))

        XCTAssertEqual(events, [])
    }

    func testUsageLimitAlertEvaluatorFallsBackToLowWarningToggleForProjectedUpgradeDefault() {
        let defaults = makeAlertDefaults()
        defaults.set(false, forKey: PreferencesKey.usageLimitNotificationApproachingEnabled)
        defaults.removeObject(forKey: PreferencesKey.usageLimitNotificationProjectedEnabled)
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4.5 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 90,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let second = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 60,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let events = evaluator.evaluate(snapshot: second, now: now.addingTimeInterval(30 * 60))

        XCTAssertEqual(events, [])
    }

    func testUsageLimitAlertEvaluatorDoesNotPredictFromCachedUsageData() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4.5 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 90,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let cachedSecond = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 60,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true,
            freshness: .recentCached,
            observedAt: now.addingTimeInterval(30 * 60),
            sourceDescription: "OAuth (cached)"
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let events = evaluator.evaluate(snapshot: cachedSecond, now: now.addingTimeInterval(30 * 60))

        XCTAssertEqual(events, [])
    }

    func testUsageLimitAlertEvaluatorAllowsRecentCachedThresholdButIgnoresStaleThreshold() {
        let defaults = makeAlertDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(45 * 60)
        let cachedSnapshot = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 9,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false,
            freshness: .recentCached,
            observedAt: now.addingTimeInterval(-5 * 60),
            sourceDescription: "OAuth (cached)"
        )
        let staleSnapshot = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 9,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 80,
            weeklyResetText: "",
            hasWeeklyRateLimit: false,
            freshness: .stale,
            observedAt: now.addingTimeInterval(-20 * 60),
            sourceDescription: "JSONL fallback"
        )

        let cachedEvents = UsageLimitAlertEvaluator(defaults: defaults).evaluate(snapshot: cachedSnapshot, now: now)
        let staleEvents = UsageLimitAlertEvaluator(defaults: defaults).evaluate(snapshot: staleSnapshot, now: now)

        XCTAssertEqual(cachedEvents.first?.kind, .approaching)
        XCTAssertEqual(staleEvents, [])
    }

    func testUsageLimitDiagnosticsStoreRecordsSnapshotAlertAndScheduledReset() {
        let defaults = makeAlertDefaults()
        let store = UsageLimitAlertDiagnosticsStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(45 * 60)
        let snapshot = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 9,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 72,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true,
            fiveHourFreshness: .fresh,
            weeklyFreshness: .recentCached,
            observedAt: now,
            sourceDescription: nil,
            fiveHourSourceDescription: "OAuth",
            weeklySourceDescription: "JSONL"
        )
        let alert = UsageLimitAlertEvent(
            provider: .codex,
            kind: .approaching,
            window: .fiveHour,
            remainingPercent: 9,
            resetDate: reset,
            identifier: "test-alert"
        )
        let scheduled = UsageLimitAlertEvent(
            provider: .codex,
            kind: .resetComplete,
            window: .fiveHour,
            remainingPercent: 9,
            resetDate: reset,
            identifier: "test-reset"
        )

        store.recordSnapshot(snapshot, now: now)
        store.recordImmediateAlert(alert, now: now.addingTimeInterval(10))
        store.recordDelivery("Banner queued", provider: .codex, now: now.addingTimeInterval(11))
        store.recordScheduledReset(scheduled)

        XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsCodexSource), "5h OAuth / Wk JSONL")
        XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsCodexFreshness), "5h fresh / Wk recent cache")
        XCTAssertEqual(defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsCodexObservedAt), now.timeIntervalSince1970)
        XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsCodexLastAlertSummary), "5h low, 9% left")
        XCTAssertEqual(defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsCodexLastAlertAt), now.addingTimeInterval(10).timeIntervalSince1970)
        XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsCodexDelivery), "Banner queued")
        XCTAssertEqual(defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsCodexDeliveryAt), now.addingTimeInterval(11).timeIntervalSince1970)
        XCTAssertEqual(defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsCodexNextResetReminderAt), reset.timeIntervalSince1970)

        store.clearScheduledReset(provider: .codex)

        XCTAssertEqual(defaults.object(forKey: PreferencesKey.usageLimitDiagnosticsCodexNextResetReminderAt) as? Double, nil)
    }

    func testUsageLimitAlertEvaluatorDedupesProjectedExhaustionPerResetWindow() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4.5 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 90,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let second = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 60,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let third = UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: 40,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let firstProjection = evaluator.evaluate(snapshot: second, now: now.addingTimeInterval(30 * 60))
        let secondProjection = evaluator.evaluate(snapshot: third, now: now.addingTimeInterval(60 * 60))

        XCTAssertEqual(firstProjection.count, 1)
        XCTAssertEqual(firstProjection.first?.kind, .projectedExhaustion)
        XCTAssertEqual(secondProjection, [])
    }

    func testUsageLimitAlertEvaluatorEscalatesProjectedExhaustionWhenEtaWorsens() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4.5 * 60 * 60)
        let first = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 90,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let second = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 60,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let third = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 40,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let firstProjection = evaluator.evaluate(snapshot: second, now: now.addingTimeInterval(30 * 60))
        let escalatedProjection = evaluator.evaluate(snapshot: third, now: now.addingTimeInterval(45 * 60))

        XCTAssertEqual(firstProjection.first?.kind, .projectedExhaustion)
        XCTAssertEqual(escalatedProjection.count, 1)
        XCTAssertEqual(escalatedProjection.first?.kind, .projectedExhaustion)
        XCTAssertTrue(escalatedProjection.first?.body.contains("about 30m") ?? false)
    }

    func testUsageLimitAlertEvaluatorDoesNotProjectExhaustionAfterReset() {
        let defaults = makeAlertDefaults()
        let evaluator = UsageLimitAlertEvaluator(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(15 * 60)
        let first = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 90,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )
        let second = UsageLimitSnapshot(
            provider: .codex,
            fiveHourRemainingPercent: 60,
            fiveHourResetText: formatResetISO8601(reset),
            hasFiveHourRateLimit: true,
            weeklyRemainingPercent: 90,
            weeklyResetText: formatResetISO8601(now.addingTimeInterval(2 * 24 * 60 * 60)),
            hasWeeklyRateLimit: true
        )

        _ = evaluator.evaluate(snapshot: first, now: now)
        let events = evaluator.evaluate(snapshot: second, now: now.addingTimeInterval(30 * 60))

        XCTAssertEqual(events, [])
    }

    func testVisibleLimitRefreshCadenceContracts() {
        XCTAssertEqual(CodexStatusService.visiblePollingIntervalSecondsForTesting(storedInterval: nil), 60)
        XCTAssertEqual(CodexStatusService.visiblePollingIntervalSecondsForTesting(storedInterval: 30), 60)
        XCTAssertEqual(CodexStatusService.visiblePollingIntervalSecondsForTesting(storedInterval: 180), 180)
        XCTAssertEqual(CodexStatusService.visiblePollingIntervalSecondsForTesting(storedInterval: 900), 180)
        XCTAssertEqual(CodexCLIRPCProbe.defaultSuccessCooldownForTesting, 60)

        XCTAssertEqual(ClaudeUsageSourceManager.refreshIntervalForTesting, 60)
        XCTAssertEqual(ClaudeOAuthUsageClient.cacheMaxAgeForTesting, 3 * 60)
        XCTAssertEqual(ClaudeWebUsageClient.cacheMaxAgeForTesting, 3 * 60)
        XCTAssertTrue(ClaudeWebUsageClient.isCacheFreshForTesting(age: 60))
        XCTAssertFalse(ClaudeWebUsageClient.isCacheFreshForTesting(age: 3 * 60 + 1))
        XCTAssertEqual(ClaudeStatusService.visiblePollingIntervalSecondsForTesting(storedInterval: nil), 180)
        XCTAssertEqual(ClaudeStatusService.visiblePollingIntervalSecondsForTesting(storedInterval: 120), 120)
        XCTAssertEqual(ClaudeStatusService.visiblePollingIntervalSecondsForTesting(storedInterval: 900), 180)
    }

    func testKeepsNewestUsageWhenScanningBackToPreferredCodexLimit() async throws {
        let now = Date()
        let codexTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-20))
        let olderUsageTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-12))
        let newerUsageTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-8))
        let nonCodexTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
        let resetAt = Int(now.addingTimeInterval(3600).timeIntervalSince1970)

        let codexLine: [String: Any] = [
            "timestamp": codexTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex",
                    "primary": [
                        "used_percent": 42.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 31.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let olderLegacyUsageLine: [String: Any] = [
            "timestamp": olderUsageTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 900,
                        "cached_input_tokens": 100,
                        "output_tokens": 120,
                        "reasoning_output_tokens": 20,
                        "total_tokens": 1020
                    ]
                ]
            ]
        ]

        let newerTurnUsageLine: [String: Any] = [
            "timestamp": newerUsageTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "turn.completed",
                "usage": [
                    "input_tokens": 2400,
                    "cached_input_tokens": 400,
                    "output_tokens": 360,
                    "reasoning_output_tokens": 80,
                    "total_tokens": 2760
                ]
            ]
        ]

        let nonCodexNewestLine: [String: Any] = [
            "timestamp": nonCodexTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex_bengalfox",
                    "primary": [
                        "used_percent": 5.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 1.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let url = try writeTempJSONL([codexLine, olderLegacyUsageLine, newerTurnUsageLine, nonCodexNewestLine])
        defer { try? FileManager.default.removeItem(at: url) }

        let lock = NSLock()
        var snapshots: [CodexUsageSnapshot] = []

        let service = CodexStatusService(
            updateHandler: { snapshot in
                lock.lock()
                snapshots.append(snapshot)
                lock.unlock()
            },
            availabilityHandler: { _ in }
        )
        let summary = await service.parseTokenCountTailForTesting(url: url)

        XCTAssertNotNil(summary, "Parser should still resolve the preferred codex rate-limit summary")
        XCTAssertEqual(summary?.fiveHour.remainingPercent, 58)
        XCTAssertEqual(summary?.weekly.remainingPercent, 69)

        lock.lock()
        let usageSnapshot = snapshots.last
        lock.unlock()

        XCTAssertNotNil(usageSnapshot, "Parser should emit usage updates during the scan")
        XCTAssertEqual(usageSnapshot?.lastInputTokens, 2400, "Older usage rows must not overwrite the newest usage seen during the same scan")
        XCTAssertEqual(usageSnapshot?.lastCachedInputTokens, 400)
        XCTAssertEqual(usageSnapshot?.lastOutputTokens, 360)
        XCTAssertEqual(usageSnapshot?.lastReasoningOutputTokens, 80)
        XCTAssertEqual(usageSnapshot?.lastTotalTokens, 2760)
    }

    func testFallsBackToOlderUsageWhenNewestUsageIsUnparseable() async throws {
        let now = Date()
        let codexTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-20))
        let validUsageTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-12))
        let malformedUsageTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-8))
        let nonCodexTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
        let resetAt = Int(now.addingTimeInterval(3600).timeIntervalSince1970)

        let codexLine: [String: Any] = [
            "timestamp": codexTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex",
                    "primary": [
                        "used_percent": 22.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 10.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let validOlderUsageLine: [String: Any] = [
            "timestamp": validUsageTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "turn.completed",
                "usage": [
                    "input_tokens": 1700,
                    "cached_input_tokens": 250,
                    "output_tokens": 280,
                    "reasoning_output_tokens": 70,
                    "total_tokens": 1980
                ]
            ]
        ]

        let malformedNewerUsageLine: [String: Any] = [
            "timestamp": malformedUsageTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "turn.completed",
                "usage": [
                    "input_tokens": "not-a-number",
                    "cached_input_tokens": "??",
                    "output_tokens": "n/a",
                    "reasoning_output_tokens": ["invalid"],
                    "total_tokens": NSNull()
                ]
            ]
        ]

        let nonCodexNewestLine: [String: Any] = [
            "timestamp": nonCodexTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex_bengalfox",
                    "primary": [
                        "used_percent": 0.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 0.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let url = try writeTempJSONL([codexLine, validOlderUsageLine, malformedNewerUsageLine, nonCodexNewestLine])
        defer { try? FileManager.default.removeItem(at: url) }

        let lock = NSLock()
        var snapshots: [CodexUsageSnapshot] = []

        let service = CodexStatusService(
            updateHandler: { snapshot in
                lock.lock()
                snapshots.append(snapshot)
                lock.unlock()
            },
            availabilityHandler: { _ in }
        )
        let summary = await service.parseTokenCountTailForTesting(url: url)

        XCTAssertNotNil(summary, "Parser should still resolve preferred codex rate limits")
        XCTAssertEqual(summary?.fiveHour.remainingPercent, 78)
        XCTAssertEqual(summary?.weekly.remainingPercent, 90)

        lock.lock()
        let usageSnapshot = snapshots.last
        lock.unlock()

        XCTAssertNotNil(usageSnapshot, "Parser should still publish decoded usage from older valid rows")
        XCTAssertEqual(usageSnapshot?.lastInputTokens, 1700)
        XCTAssertEqual(usageSnapshot?.lastCachedInputTokens, 250)
        XCTAssertEqual(usageSnapshot?.lastOutputTokens, 280)
        XCTAssertEqual(usageSnapshot?.lastReasoningOutputTokens, 70)
        XCTAssertEqual(usageSnapshot?.lastTotalTokens, 1980)
    }

    func testNullOnlyRecentSessionDoesNotFallBackToOlderFileRateLimits() async throws {
        let now = Date()
        let olderTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-4 * 60 * 60))
        let newerTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let resetAt = Int(now.addingTimeInterval(3600).timeIntervalSince1970)

        let olderCodexLine: [String: Any] = [
            "timestamp": olderTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "rate_limits": [
                    "limit_id": "codex",
                    "primary": [
                        "used_percent": 13.0,
                        "window_minutes": 300,
                        "resets_at": resetAt
                    ],
                    "secondary": [
                        "used_percent": 4.0,
                        "window_minutes": 10080,
                        "resets_at": resetAt + 5000
                    ]
                ]
            ]
        ]

        let newerNullOnlyLine: [String: Any] = [
            "timestamp": newerTimestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 1200,
                        "cached_input_tokens": 300,
                        "output_tokens": 240,
                        "reasoning_output_tokens": 60,
                        "total_tokens": 1440
                    ]
                ],
                "rate_limits": NSNull()
            ]
        ]

        let olderURL = try writeTempJSONL([olderCodexLine])
        let newerURL = try writeTempJSONL([newerNullOnlyLine])
        defer {
            try? FileManager.default.removeItem(at: olderURL)
            try? FileManager.default.removeItem(at: newerURL)
        }

        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        let olderSummary = await service.parseTokenCountTailForTesting(url: olderURL)
        let newerSummary = await service.parseTokenCountTailForTesting(url: newerURL)

        XCTAssertNotNil(olderSummary)
        XCTAssertEqual(olderSummary?.fiveHour.remainingPercent, 87)
        XCTAssertFalse(olderSummary?.missingRateLimits ?? true)

        XCTAssertNotNil(newerSummary)
        XCTAssertTrue(newerSummary?.missingRateLimits ?? false, "Null-only recent files should be treated as unavailable, not as a cue to reuse older file limits")
        XCTAssertNil(newerSummary?.fiveHour.remainingPercent)
        XCTAssertNil(newerSummary?.weekly.remainingPercent)
        XCTAssertEqual(newerSummary?.eventTimestamp, ISO8601DateFormatter().date(from: newerTimestamp))
    }

    // MARK: - Integration Tests

    func testComputesNonCachedInputTokens() throws {
        // Verify we can compute input (non-cached) = input - cached
        let url = fixtureURL("codex_053_rate_limit")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  type == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let lastUsage = info["last_token_usage"] as? [String: Any] else { continue }

            if let input = lastUsage["input_tokens"] as? Int,
               let cached = lastUsage["cached_input_tokens"] as? Int {
                let nonCached = max(0, input - cached)
                XCTAssertGreaterThanOrEqual(nonCached, 0)
                XCTAssertLessThanOrEqual(nonCached, input)
                // For the first event: 12091 - 10880 = 1211
                if input == 12091 {
                    XCTAssertEqual(nonCached, 1211)
                }
                return // Test passed
            }
        }

        XCTFail("Should find token count with input and cached tokens")
    }

    func testBackwardCompatibilityAcrossAllVersions() throws {
        // Ensure all fixture formats can be parsed without crashing
        let fixtures = ["codex_050_legacy", "codex_051_usage", "codex_052_raw", "codex_053_rate_limit"]

        for fixtureName in fixtures {
            let url = fixtureURL(fixtureName)
            let reader = JSONLReader(url: url)

            XCTAssertNoThrow(try reader.readLines(), "Should parse \(fixtureName) without errors")

            let lines = try reader.readLines()
            XCTAssertGreaterThan(lines.count, 0, "\(fixtureName) should have events")

            // Verify each line is valid JSON
            for (index, line) in lines.enumerated() {
                guard let data = line.data(using: .utf8) else {
                    XCTFail("\(fixtureName) line \(index) is not UTF-8")
                    continue
                }
                XCTAssertNoThrow(
                    try JSONSerialization.jsonObject(with: data),
                    "\(fixtureName) line \(index) should be valid JSON"
                )
            }
        }
    }

    @MainActor
    func testCodexUsageModelStartupInitializationIsSafe() {
        let model = CodexUsageModel()
        model.setAppActive(false)
        model.setMenuVisible(false)
        model.setStripVisible(false)
        XCTAssertNotNil(model)
        XCTAssertNotNil(CodexUsageModel.shared)
    }

    @MainActor
    func testClaudeUsageModelStartupInitializationIsSafe() {
        let model = ClaudeUsageModel()
        model.setAppActive(false)
        model.setMenuVisible(false)
        model.setStripVisible(false)
        XCTAssertNotNil(model)
        XCTAssertNotNil(ClaudeUsageModel.shared)
    }

    @MainActor
    func testClaudeUsageModelWakeRefreshTreatsCockpitAsVisible() {
        XCTAssertTrue(
            ClaudeUsageModel.shouldRefreshOnWakeForTesting(
                isRunningTests: false,
                isEnabled: true,
                stripVisible: false,
                menuVisible: false,
                cockpitVisible: true,
                cockpitPinned: false,
                appIsActive: true,
                claudeUsageEnabled: true,
                onACPower: true
            )
        )
        XCTAssertFalse(
            ClaudeUsageModel.shouldRefreshOnWakeForTesting(
                isRunningTests: false,
                isEnabled: true,
                stripVisible: false,
                menuVisible: false,
                cockpitVisible: true,
                cockpitPinned: false,
                appIsActive: false,
                claudeUsageEnabled: true,
                onACPower: true
            )
        )
        XCTAssertTrue(
            ClaudeUsageModel.shouldRefreshOnWakeForTesting(
                isRunningTests: false,
                isEnabled: true,
                stripVisible: false,
                menuVisible: false,
                cockpitVisible: false,
                cockpitPinned: true,
                appIsActive: false,
                claudeUsageEnabled: true,
                onACPower: true
            )
        )
    }

    @MainActor
    func testClaudeUsageModelUsesSnapshotFetchedAtForLastUpdate() {
        let model = ClaudeUsageModel()
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        model.applyLimitSnapshotForTesting(
            ClaudeLimitSnapshot(
                fetchedAt: fetchedAt,
                source: .cachedOAuth,
                health: .stale,
                fiveHourUsedRatio: 0.25,
                fiveHourResetText: "",
                weeklyUsedRatio: 0.5,
                weeklyResetText: "",
                weekOpusUsedRatio: nil,
                weekOpusResetText: nil,
                rawPayloadHash: nil
            )
        )

        XCTAssertEqual(model.lastUpdate, fetchedAt)
        XCTAssertTrue(model.dataIsStale)
    }

    @MainActor
    func testClaudeUsageModelProjectsFromRecentCachedOAuthAndWebSnapshots() {
        let defaults = makeAlertDefaults()
        ClaudeUsageModel.projectionDiagnosticsDefaultsForTesting = defaults
        defer {
            ClaudeUsageModel.projectionDiagnosticsDefaultsForTesting = nil
        }

        for source in [ClaudeUsageSource.cachedOAuth, .cachedWeb] {
            let model = ClaudeUsageModel()
            let secondFetchedAt = Date().addingTimeInterval(-1)
            let firstFetchedAt = secondFetchedAt.addingTimeInterval(-2 * 60)
            let resetText = formatResetISO8601(firstFetchedAt.addingTimeInterval(4.5 * 60 * 60))

            model.applyLimitSnapshotForTesting(
                ClaudeLimitSnapshot(
                    fetchedAt: firstFetchedAt,
                    source: source,
                    health: .live,
                    fiveHourUsedRatio: 0.176,
                    fiveHourResetText: resetText,
                    weeklyUsedRatio: 0.5,
                    weeklyResetText: resetText,
                    weekOpusUsedRatio: nil,
                    weekOpusResetText: nil,
                    rawPayloadHash: nil
                )
            )
            XCTAssertNil(model.fiveHourProjectedRunoutAt, "\(source) first sample should seed history only")

            model.applyLimitSnapshotForTesting(
                ClaudeLimitSnapshot(
                    fetchedAt: secondFetchedAt,
                    source: source,
                    health: .live,
                    fiveHourUsedRatio: 0.184,
                    fiveHourResetText: resetText,
                    weeklyUsedRatio: 0.5,
                    weeklyResetText: resetText,
                    weekOpusUsedRatio: nil,
                    weekOpusResetText: nil,
                    rawPayloadHash: nil
                )
            )

            XCTAssertEqual(model.sessionRemainingPercent, 82)
            XCTAssertEqual(model.fiveHourProjectionObservedAt, secondFetchedAt)
            XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsClaudeProjection), "Active ▸3h 24m")
            XCTAssertEqual(
                defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsClaudeProjectionObservedAt),
                secondFetchedAt.timeIntervalSince1970,
                accuracy: 0.001
            )
            XCTAssertEqual(
                model.fiveHourProjectedRunoutAt?.timeIntervalSince1970 ?? 0,
                secondFetchedAt.addingTimeInterval(3 * 60 * 60 + 24 * 60).timeIntervalSince1970,
                accuracy: 0.001,
                "\(source) should use exact cached ratio changes even when rounded percent is unchanged"
            )
            XCTAssertEqual(
                defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsClaudeProjectionRunoutAt),
                secondFetchedAt.addingTimeInterval(3 * 60 * 60 + 24 * 60).timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    @MainActor
    func testCodexUsageModelRecordsProjectionDiagnosticsToInjectedDefaults() {
        let defaults = makeAlertDefaults()
        CodexUsageModel.projectionDiagnosticsDefaultsForTesting = defaults
        defer {
            CodexUsageModel.projectionDiagnosticsDefaultsForTesting = nil
        }

        let model = CodexUsageModel()
        let secondObservedAt = Date().addingTimeInterval(-1)
        let firstObservedAt = secondObservedAt.addingTimeInterval(-2 * 60)
        let resetText = formatResetISO8601(firstObservedAt.addingTimeInterval(4.5 * 60 * 60))

        model.applySnapshotForTesting(CodexUsageSnapshot(
            fiveHourRemainingPercent: 90,
            fiveHourResetText: resetText,
            hasFiveHourRateLimit: true,
            fiveHourLimitsSource: .oauth,
            weekRemainingPercent: 90,
            weekResetText: resetText,
            hasWeekRateLimit: true,
            weekLimitsSource: .oauth,
            limitsSource: .oauth,
            eventTimestamp: firstObservedAt
        ))
        XCTAssertNil(model.fiveHourProjectedRunoutAt)

        model.applySnapshotForTesting(CodexUsageSnapshot(
            fiveHourRemainingPercent: 89,
            fiveHourResetText: resetText,
            hasFiveHourRateLimit: true,
            fiveHourLimitsSource: .oauth,
            weekRemainingPercent: 90,
            weekResetText: resetText,
            hasWeekRateLimit: true,
            weekLimitsSource: .oauth,
            limitsSource: .oauth,
            eventTimestamp: secondObservedAt
        ))

        let expectedRunoutAt = secondObservedAt.addingTimeInterval(89 * 2 * 60)
        XCTAssertEqual(model.fiveHourProjectionObservedAt, secondObservedAt)
        XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsCodexProjection)?.hasPrefix("Active ▸"), true)
        XCTAssertEqual(
            defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsCodexProjectionObservedAt),
            secondObservedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsCodexProjectionRunoutAt),
            expectedRunoutAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testCodexRunwayCalculatorRanksByPauseImpact() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 30,
            resetAt: now.addingTimeInterval(3 * 60 * 60),
            currentRunoutAt: now.addingTimeInterval(90 * 60),
            observedAt: now
        )
        let small = RunwaySessionBurn(
            identity: RunwaySessionIdentity(id: "small", displayName: "academy", isGoal: true, logPaths: ["/tmp/a.jsonl"]),
            percentPerSecond: 1.0 / 3600.0,
            confidence: .direct,
            sampleStart: now.addingTimeInterval(-120),
            sampleEnd: now
        )
        let large = RunwaySessionBurn(
            identity: RunwaySessionIdentity(id: "large", displayName: "auth-flow", isGoal: true, logPaths: ["/tmp/b.jsonl"]),
            percentPerSecond: 3.0 / 3600.0,
            confidence: .direct,
            sampleStart: now.addingTimeInterval(-120),
            sampleEnd: now
        )

        let snapshot = CodexRunwayCalculator.snapshot(baseline: baseline, burns: [small, large], maxRows: 2)

        XCTAssertEqual(snapshot?.rows.map(\.id), ["large", "small"])
        XCTAssertGreaterThan(snapshot?.rows.first?.gainedSeconds ?? 0, snapshot?.rows.last?.gainedSeconds ?? 0)
        XCTAssertEqual(snapshot?.rows.first?.displayRate ?? 0, 9, accuracy: 0.001)
        XCTAssertEqual(snapshot?.rows.last?.displayRate ?? 0, 3, accuracy: 0.001)
    }

    func testCodexRunwayCalculatorCapsDeadlineAfterReset() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 10,
            resetAt: now.addingTimeInterval(2 * 60 * 60),
            currentRunoutAt: now.addingTimeInterval(30 * 60),
            observedAt: now
        )
        let burn = RunwaySessionBurn(
            identity: RunwaySessionIdentity(id: "main", displayName: "auth-flow", isGoal: false, logPaths: ["/tmp/a.jsonl"]),
            percentPerSecond: 10.0 / (30 * 60),
            confidence: .mixed,
            sampleStart: now.addingTimeInterval(-120),
            sampleEnd: now
        )

        let row = CodexRunwayCalculator.snapshot(baseline: baseline, burns: [burn])?.rows.first

        XCTAssertEqual(row?.deadline, .afterReset)
        XCTAssertEqual(row?.gainedSeconds ?? 0, 90 * 60, accuracy: 0.001)
        XCTAssertEqual(row?.displayRate ?? 0, 60, accuracy: 0.001)
    }

    func testCodexRunwayCalculatorShowsBurnersWhenBaselineAlreadyAfterReset() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 80,
            resetAt: now.addingTimeInterval(60 * 60),
            currentRunoutAt: now.addingTimeInterval(4 * 60 * 60),
            observedAt: now
        )
        let small = RunwaySessionBurn(
            identity: RunwaySessionIdentity(id: "small", displayName: "academy", isGoal: true, logPaths: ["/tmp/a.jsonl"]),
            percentPerSecond: 1.0 / 3600.0,
            confidence: .mixed,
            sampleStart: now.addingTimeInterval(-120),
            sampleEnd: now
        )
        let large = RunwaySessionBurn(
            identity: RunwaySessionIdentity(id: "large", displayName: "auth-flow", isGoal: true, logPaths: ["/tmp/b.jsonl"]),
            percentPerSecond: 3.0 / 3600.0,
            confidence: .mixed,
            sampleStart: now.addingTimeInterval(-120),
            sampleEnd: now
        )

        let snapshot = CodexRunwayCalculator.snapshot(baseline: baseline, burns: [small, large], maxRows: 2)

        XCTAssertEqual(snapshot?.rows.map(\.id), ["large", "small"])
        XCTAssertEqual(snapshot?.rows.map(\.deadline), [.afterReset, .afterReset])
        XCTAssertEqual(snapshot?.rows.map(\.gainedSeconds), [0, 0])
    }

    func testCodexRunwayCalculatorSummarizesHiddenBurstsAsCombinedImpact() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 10,
            resetAt: now.addingTimeInterval(60 * 60),
            currentRunoutAt: now.addingTimeInterval(30 * 60),
            observedAt: now
        )
        let burns = ["one", "two", "three"].map { id in
            RunwaySessionBurn(
                identity: RunwaySessionIdentity(id: id, displayName: id, isGoal: false, logPaths: ["/tmp/\(id).jsonl"]),
                percentPerSecond: 0.001,
                confidence: .direct,
                sampleStart: now.addingTimeInterval(-120),
                sampleEnd: now
            )
        }

        let snapshot = CodexRunwayCalculator.snapshot(baseline: baseline, burns: burns, maxRows: 1)

        XCTAssertEqual(snapshot?.rows.count, 1)
        XCTAssertEqual(snapshot?.burstSummary?.count, 2)
        XCTAssertEqual(snapshot?.burstSummary?.gainedSeconds ?? 0, 1012.5, accuracy: 0.1)
        XCTAssertEqual(snapshot?.burstSummary?.displayRate ?? 0, 21.6, accuracy: 0.001)
    }

    func testCodexRunwayCalculatorKeepsSubMinuteBurnRowsAsNoChange() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 30,
            resetAt: now.addingTimeInterval(3 * 60 * 60),
            currentRunoutAt: now.addingTimeInterval(90 * 60),
            observedAt: now
        )
        let tiny = RunwaySessionBurn(
            identity: RunwaySessionIdentity(id: "tiny", displayName: "tiny", isGoal: false, logPaths: ["/tmp/tiny.jsonl"]),
            percentPerSecond: 0.000001,
            confidence: .direct,
            sampleStart: now.addingTimeInterval(-120),
            sampleEnd: now
        )

        let snapshot = CodexRunwayCalculator.snapshot(baseline: baseline, burns: [tiny], maxRows: 3)

        XCTAssertEqual(snapshot?.rows.map(\.id), ["tiny"])
        XCTAssertEqual(snapshot?.rows.first?.deadline, .noChange)
        XCTAssertEqual(snapshot?.rows.first?.gainedSeconds ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(snapshot?.rows.first?.displayRate ?? 0, 0)
        XCTAssertEqual(snapshot?.rows.first?.confidence, .direct)
        XCTAssertNil(snapshot?.burstSummary)
    }

    func testCodexRunwayCalculatorSummarizesHiddenSubMinuteBurnRows() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 30,
            resetAt: now.addingTimeInterval(3 * 60 * 60),
            currentRunoutAt: now.addingTimeInterval(90 * 60),
            observedAt: now
        )
        let burns = (1...6).map { index in
            RunwaySessionBurn(
                identity: RunwaySessionIdentity(
                    id: "session-\(index)",
                    displayName: "session \(index)",
                    isGoal: false,
                    logPaths: ["/tmp/session-\(index).jsonl"]
                ),
                percentPerSecond: 0.000001 * Double(index),
                confidence: .direct,
                sampleStart: now.addingTimeInterval(-120),
                sampleEnd: now
            )
        }

        let snapshot = CodexRunwayCalculator.snapshot(baseline: baseline, burns: burns, maxRows: 4)

        XCTAssertEqual(snapshot?.rows.map(\.id), ["session-6", "session-5", "session-4", "session-3"])
        XCTAssertEqual(snapshot?.rows.map(\.deadline), [.noChange, .noChange, .noChange, .noChange])
        XCTAssertEqual(snapshot?.burstSummary?.count, 2)
        XCTAssertEqual(snapshot?.burstSummary?.deadline, .noChange)
        XCTAssertEqual(snapshot?.burstSummary?.gainedSeconds ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(snapshot?.burstSummary?.displayRate ?? 0, 0)
    }

    func testCodexRunwayCalculatorPromotesSingleOverflowSessionToRow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 10,
            resetAt: now.addingTimeInterval(60 * 60),
            currentRunoutAt: now.addingTimeInterval(30 * 60),
            observedAt: now
        )
        let burns = ["one", "two"].map { id in
            RunwaySessionBurn(
                identity: RunwaySessionIdentity(id: id, displayName: id, isGoal: false, logPaths: ["/tmp/\(id).jsonl"]),
                percentPerSecond: 0.001,
                confidence: .direct,
                sampleStart: now.addingTimeInterval(-120),
                sampleEnd: now
            )
        }

        let snapshot = CodexRunwayCalculator.snapshot(baseline: baseline, burns: burns, maxRows: 1)

        XCTAssertEqual(snapshot?.rows.count, 2)
        XCTAssertEqual(Set(snapshot?.rows.map(\.displayName) ?? []), ["one", "two"])
        XCTAssertNil(snapshot?.burstSummary)
    }

    func testCodexRunwayCalculatorAfterResetPromotesSingleOverflow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 80,
            resetAt: now.addingTimeInterval(60 * 60),
            currentRunoutAt: now.addingTimeInterval(4 * 60 * 60),
            observedAt: now
        )
        let burns = ["one", "two", "three"].map { id in
            RunwaySessionBurn(
                identity: RunwaySessionIdentity(id: id, displayName: id, isGoal: false, logPaths: ["/tmp/\(id).jsonl"]),
                percentPerSecond: 1.0 / 3600.0,
                confidence: .mixed,
                sampleStart: now.addingTimeInterval(-120),
                sampleEnd: now
            )
        }

        let snapshot = CodexRunwayCalculator.snapshot(baseline: baseline, burns: burns, maxRows: 2)

        XCTAssertEqual(snapshot?.rows.count, 3)
        XCTAssertEqual(snapshot?.rows.map(\.deadline), [.afterReset, .afterReset, .afterReset])
        XCTAssertNil(snapshot?.burstSummary)
    }

    func testRunwayPendingRowsPromoteSingleOverflowIdentity() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 30,
            resetAt: now.addingTimeInterval(3 * 60 * 60),
            currentRunoutAt: now.addingTimeInterval(90 * 60),
            observedAt: now
        )
        let existingRows = ["one", "two"].map { id in
            RunwayPauseImpactRow(
                id: id,
                displayName: id,
                isGoal: false,
                deadline: .noChange,
                gainedSeconds: 0,
                displayRate: 5,
                confidence: .direct
            )
        }
        let existing = CodexRunwaySnapshot(baseline: baseline, rows: existingRows, burstSummary: nil)
        let pending = RunwaySessionIdentity(id: "extra", displayName: "extra", isGoal: false, logPaths: ["/tmp/extra.jsonl"])

        let snapshot = RunwaySnapshotAssembly.withPendingRows(
            baseline: baseline,
            snapshot: existing,
            activeIdentities: [pending],
            maxRows: 2
        )

        XCTAssertEqual(snapshot?.rows.map(\.id), ["one", "two", "extra"])
        XCTAssertNil(snapshot?.burstSummary)
    }

    func testRunwayPendingRowsKeepSummaryForTwoOverflowIdentities() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 30,
            resetAt: now.addingTimeInterval(3 * 60 * 60),
            currentRunoutAt: now.addingTimeInterval(90 * 60),
            observedAt: now
        )
        let existingRows = ["one", "two"].map { id in
            RunwayPauseImpactRow(
                id: id,
                displayName: id,
                isGoal: false,
                deadline: .noChange,
                gainedSeconds: 0,
                displayRate: 5,
                confidence: .direct
            )
        }
        let existing = CodexRunwaySnapshot(baseline: baseline, rows: existingRows, burstSummary: nil)
        let pendings = ["extra-1", "extra-2"].map {
            RunwaySessionIdentity(id: $0, displayName: $0, isGoal: false, logPaths: ["/tmp/\($0).jsonl"])
        }

        let snapshot = RunwaySnapshotAssembly.withPendingRows(
            baseline: baseline,
            snapshot: existing,
            activeIdentities: pendings,
            maxRows: 2
        )

        XCTAssertEqual(snapshot?.rows.map(\.id), ["one", "two"])
        XCTAssertEqual(snapshot?.burstSummary?.count, 2)
    }

    func testRunwayPendingOverflowMergesWithBurnSummaryCount() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 30,
            resetAt: now.addingTimeInterval(3 * 60 * 60),
            currentRunoutAt: now.addingTimeInterval(90 * 60),
            observedAt: now
        )
        let existingRows = ["one", "two"].map { id in
            RunwayPauseImpactRow(
                id: id,
                displayName: id,
                isGoal: false,
                deadline: .noChange,
                gainedSeconds: 0,
                displayRate: 5,
                confidence: .direct
            )
        }
        let burnSummary = RunwayShortBurstSummary(
            count: 2,
            deadline: .noChange,
            gainedSeconds: 0,
            displayRate: 7
        )
        let existing = CodexRunwaySnapshot(baseline: baseline, rows: existingRows, burstSummary: burnSummary)
        let pendings = ["extra-1", "extra-2", "extra-3"].map {
            RunwaySessionIdentity(id: $0, displayName: $0, isGoal: false, logPaths: ["/tmp/\($0).jsonl"])
        }

        let snapshot = RunwaySnapshotAssembly.withPendingRows(
            baseline: baseline,
            snapshot: existing,
            activeIdentities: pendings,
            maxRows: 2
        )

        XCTAssertEqual(snapshot?.rows.map(\.id), ["one", "two"])
        XCTAssertEqual(snapshot?.burstSummary?.count, 5)
        XCTAssertEqual(snapshot?.burstSummary?.displayRate ?? 0, 7, accuracy: 0.001)
    }

    func testCodexRunwayLoaderUniqueIdentitiesMergePartialHudRowIntoCorrectedParent() {
        let partialHUD = RunwaySessionIdentity(
            id: "child-session",
            displayName: "Review subagent",
            isGoal: false,
            logPaths: ["/tmp/nested-child.jsonl"]
        )
        let correctedParent = RunwaySessionIdentity(
            id: "worktree-session",
            displayName: "Investigate issue 47",
            isGoal: true,
            logPaths: ["/tmp/parent.jsonl", "/tmp/child.jsonl", "/tmp/nested-child.jsonl"]
        )

        let identities = CodexRunwaySnapshotLoader.uniqueIdentitiesForTesting([partialHUD, correctedParent])

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.id, "worktree-session")
        XCTAssertEqual(identities.first?.displayName, "Investigate issue 47")
        XCTAssertEqual(identities.first?.isGoal, true)
        XCTAssertEqual(
            identities.first?.logPaths,
            ["/tmp/child.jsonl", "/tmp/nested-child.jsonl", "/tmp/parent.jsonl"]
        )
    }

    func testCodexRunwayParserExtractsRecentRateLimitSamples() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(120)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","payload":{"rate_limits":{"limit_id":"codex","captured_at":"\(iso(first))","primary":{"remaining_percent":80.0,"resets_at":"\(iso(reset))"}}}}
        {"timestamp":"\(iso(second))","payload":{"rate_limits":{"limit_id":"codex","captured_at":"\(iso(second))","primary":{"remaining_percent":78.5,"resets_at":"\(iso(reset))"}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let burn = CodexRunwayRateLimitParser.burn(identity: identity, now: second.addingTimeInterval(1))

        XCTAssertEqual(burn?.percentPerSecond ?? 0, 1.5 / 120.0, accuracy: 0.000001)
        XCTAssertEqual(burn?.confidence, .direct)
    }

    func testCodexRunwayTokenActivityParserExtractsFlatPercentTokenMovement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100000},"last_token_usage":{"total_tokens":100000}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":55.0,"window_minutes":300,"resets_at":"\(iso(reset))"}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000},"last_token_usage":{"total_tokens":150000}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":55.0,"window_minutes":300,"resets_at":"\(iso(reset))"}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let activity = CodexRunwayTokenActivityParser.activity(identity: identity, now: second.addingTimeInterval(1))

        XCTAssertEqual(activity?.tokensPerSecond ?? 0, 150000.0 / 30.0, accuracy: 0.001)
    }

    func testCodexRunwayTokenActivityParserIgnoresStaleTokenMovement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-token-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100000}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":55.0,"window_minutes":300,"resets_at":"\(iso(reset))"}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":55.0,"window_minutes":300,"resets_at":"\(iso(reset))"}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let staleNow = second.addingTimeInterval(CodexRunwayTokenActivityParser.maximumSampleAge + 1)
        let activity = CodexRunwayTokenActivityParser.activity(identity: identity, now: staleNow)

        XCTAssertNil(activity)
    }

    func testCodexRunwayRecentSessionScannerDiscoversRecentLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-scan-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/06", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"session-123","cwd":"/Users/alexm/Repository/Codex-History","originator":"Codex Desktop"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"audit exported pricing and program facts"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.id, "session-123")
        XCTAssertEqual(
            identities.first?.logPaths.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            log.standardizedFileURL.path
        )
        XCTAssertEqual(identities.first?.displayName.hasPrefix("audit exported pricing"), true)
    }

    func testCodexRunwayRecentSessionScannerPrefersCliRenameOverFirstPrompt() throws {
        let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-rename-\(UUID().uuidString)")
        let root = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/06", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let index = codexHome.appendingPathComponent("session_index.jsonl")
        try """
        {"id":"renamed-session","thread_name":"Track active session burn rates"}
        """.write(to: index, atomically: true, encoding: .utf8)

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"renamed-session","cwd":"/Users/alexm/Repository/Codex-History","originator":"codex_cli_rs"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"i have an idea - can we track and show burning rate"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.first?.displayName.hasPrefix("Track active session burn"), true)
    }

    func testCodexRunwayRecentSessionScannerGroupsSubagentsByParentThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-subagents-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/17", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = dir.appendingPathComponent("rollout-first.jsonl")
        let second = dir.appendingPathComponent("rollout-second.jsonl")
        let firstText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"child-a","cwd":"/Users/alexm/Repository/tennis-academy-map-ops","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","agent_role":"qa"}}}}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"QA and collect academy data"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        let secondText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"child-b","cwd":"/Users/alexm/Repository/tennis-academy-map-ops","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","agent_role":"qa"}}}}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Tennis Academy Map ops continuation"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":150000}}}}
        """
        try firstText.write(to: first, atomically: true, encoding: .utf8)
        try secondText.write(to: second, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: second.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.id, "parent-session")
        XCTAssertEqual(identities.first?.displayName, "QA and collect academy data")
        XCTAssertEqual(
            identities.first?.logPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(),
            ["rollout-first.jsonl", "rollout-second.jsonl"]
        )
    }

    func testCodexRunwayRecentSessionScannerGroupsGuardianSubagentByTopLevelParentThread() throws {
        // Guardian approval reviewers use source {"subagent":{"other":"guardian"}}
        // and carry the parent link at payload top level (no thread_spawn dict).
        // Reading only thread_spawn made a RUNNING guardian show up in Runway as
        // an independent active session alongside its parent.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-guardian-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/07/19", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = dir.appendingPathComponent("rollout-parent.jsonl")
        let guardian = dir.appendingPathComponent("rollout-guardian.jsonl")
        let parentText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","cwd":"/Users/alexm/Documents/Codex/2026-07-19/kaize-slug","originator":"codex_work_desktop","source":"vscode"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Check Codex SSD write issue"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        // payload.session_id points at the PARENT on new-format subagent rollouts;
        // payload.id is the guardian's own thread id.
        let guardianText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"session_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","id":"019f7ce7-8979-7203-8867-34084576cf0c","parent_thread_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","cwd":"/Users/alexm/Documents/Codex/2026-07-19/kaize-slug","originator":"codex_work_desktop","source":{"subagent":{"other":"guardian"}}}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Assess the planned action"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9000}}}}
        """
        try parentText.write(to: parent, atomically: true, encoding: .utf8)
        try guardianText.write(to: guardian, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parent.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: guardian.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.id, "019f7ce5-7a52-7e32-8fc5-99c3193aba48")
        XCTAssertEqual(identities.first?.displayName, "Check Codex SSD write issue")
        XCTAssertEqual(
            identities.first?.logPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(),
            ["rollout-guardian.jsonl", "rollout-parent.jsonl"]
        )
    }

    func testCodexRunwayRecentSessionScannerGroupsStringFormSubagentByTopLevelParentThread() throws {
        // The string form {"subagent":"review"} also carries the parent link at
        // payload top level on newer builds. SessionIndexer reads it for every
        // subagent source shape; the live scanner must agree.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-review-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/07/19", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = dir.appendingPathComponent("rollout-parent.jsonl")
        let review = dir.appendingPathComponent("rollout-review.jsonl")
        let parentText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"parent-thread","cwd":"/Users/alexm/Repository/Codex-History","source":"cli"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review the pending diff"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        let reviewText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"review-thread","parent_thread_id":"parent-thread","cwd":"/Users/alexm/Repository/Codex-History","source":{"subagent":"review"}}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Reviewing"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9000}}}}
        """
        try parentText.write(to: parent, atomically: true, encoding: .utf8)
        try reviewText.write(to: review, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parent.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: review.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.id, "parent-thread")
    }

    func testCodexRunwayRecentSessionScannerKeepsRootSessionWithTopLevelParentThreadIndependent() throws {
        // Guardrail: the top-level parent_thread_id read is gated on a subagent
        // source, matching SessionIndexer. A non-subagent session that carries
        // the field (e.g. a fork/resume lineage pointer) stays its own row.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-rootparent-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/07/19", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = dir.appendingPathComponent("rollout-parent.jsonl")
        let forked = dir.appendingPathComponent("rollout-forked.jsonl")
        let parentText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"origin-thread","cwd":"/Users/alexm/Repository/Codex-History","source":"cli"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Origin session"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        let forkedText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"forked-thread","parent_thread_id":"origin-thread","cwd":"/Users/alexm/Repository/Codex-History","source":"cli"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Forked session"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9000}}}}
        """
        try parentText.write(to: parent, atomically: true, encoding: .utf8)
        try forkedText.write(to: forked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parent.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: forked.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(Set(identities.map(\.id)), ["origin-thread", "forked-thread"])
    }

    func testCodexRunwayRecentSessionScannerKeepsWorktreeParentWhenLogEmbedsSourceMeta() throws {
        let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-worktree-\(UUID().uuidString)")
        let root = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/20", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let worktreeID = "019ee839-07ff-7370-8a66-2fedf3ee3956"
        let sourceID = "019ee5e0-2518-7bb2-8deb-8ed972bd529c"
        let childID = "019ee83a-2613-7103-a33e-84d796ad976e"
        let nestedChildID = "019ee83b-bc7c-74c3-b5e1-12776943ecfa"
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        try """
        {"id":"\(worktreeID)","thread_name":"Investigate issue 47"}
        {"id":"\(sourceID)","thread_name":"Investigate issue 47"}
        """.write(to: index, atomically: true, encoding: .utf8)

        let parent = dir.appendingPathComponent("rollout-2026-06-20T20-28-32-\(worktreeID).jsonl")
        let child = dir.appendingPathComponent("rollout-2026-06-20T20-29-45-\(childID).jsonl")
        let nestedChild = dir.appendingPathComponent("rollout-2026-06-20T20-30-16-\(nestedChildID).jsonl")
        let parentText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"\(worktreeID)","cwd":"/Users/alexm/.codex/worktrees/0c6b/Codex-History","originator":"Codex Desktop"}}
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"\(sourceID)","cwd":"/Users/alexm/Repository/Codex-History","originator":"Codex Desktop"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"investigate issue 47"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":350000}}}}
        """
        let childText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"\(childID)","cwd":"/Users/alexm/.codex/worktrees/0c6b/Codex-History","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(worktreeID)","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Averroes"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"inspect issue 47 local code path"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":150000}}}}
        """
        let nestedChildText = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"\(nestedChildID)","cwd":"/Users/alexm/.codex/worktrees/0c6b/Codex-History","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(childID)","agent_role":"reviewer"}}},"thread_source":"subagent","agent_nickname":"Socrates"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"review issue 47 nested agent findings"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":90000}}}}
        """
        try parentText.write(to: parent, atomically: true, encoding: .utf8)
        try childText.write(to: child, atomically: true, encoding: .utf8)
        try nestedChildText.write(to: nestedChild, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parent.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1)], ofItemAtPath: child.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2)], ofItemAtPath: nestedChild.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1)
        XCTAssertFalse(identities.contains { $0.id == sourceID })
        XCTAssertEqual(identities.first?.id, worktreeID)
        XCTAssertEqual(identities.first?.displayName, "Investigate issue 47")
        XCTAssertEqual(
            identities.first?.logPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(),
            [
                "rollout-2026-06-20T20-28-32-\(worktreeID).jsonl",
                "rollout-2026-06-20T20-29-45-\(childID).jsonl",
                "rollout-2026-06-20T20-30-16-\(nestedChildID).jsonl"
            ]
        )
    }

    func testCodexRunwayRecentSessionScannerUsesInactiveParentMetadataBeyondOutputCap() throws {
        let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-parent-metadata-\(UUID().uuidString)")
        let root = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/20", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let worktreeID = "worktree-session"
        let childID = "child-session"
        let nestedChildID = "nested-child-session"
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        try """
        {"id":"\(worktreeID)","thread_name":"Investigate issue 47"}
        """.write(to: index, atomically: true, encoding: .utf8)

        let nestedChild = dir.appendingPathComponent("rollout-nested.jsonl")
        try """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"\(nestedChildID)","cwd":"/Users/alexm/.codex/worktrees/0c6b/Codex-History","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(childID)","agent_role":"reviewer"}}}}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"nested review"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":90000}}}}
        """.write(to: nestedChild, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: nestedChild.path)

        for index in 0..<13 {
            let noise = dir.appendingPathComponent("rollout-noise-\(index).jsonl")
            try """
            {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"noise-\(index)","cwd":"/Users/alexm/Repository/Codex-History"}}
            {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(1000 + index)}}}}
            """.write(to: noise, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(TimeInterval(-index - 1))], ofItemAtPath: noise.path)
        }

        let child = dir.appendingPathComponent("rollout-child.jsonl")
        try """
        {"timestamp":"\(iso(now.addingTimeInterval(-10 * 60)))","type":"session_meta","payload":{"id":"\(childID)","cwd":"/Users/alexm/.codex/worktrees/0c6b/Codex-History","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(worktreeID)","agent_role":"explorer"}}}}}
        {"timestamp":"\(iso(now.addingTimeInterval(-10 * 60)))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"inactive child"}]}}
        """.write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20 * 60)], ofItemAtPath: child.path)

        let parent = dir.appendingPathComponent("rollout-parent.jsonl")
        try """
        {"timestamp":"\(iso(now.addingTimeInterval(-10 * 60)))","type":"session_meta","payload":{"id":"\(worktreeID)","cwd":"/Users/alexm/.codex/worktrees/0c6b/Codex-History"}}
        {"timestamp":"\(iso(now.addingTimeInterval(-10 * 60)))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"investigate issue 47"}]}}
        """.write(to: parent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-21 * 60)], ofItemAtPath: parent.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)
        let worktree = identities.first { $0.id == worktreeID }

        XCTAssertNotNil(worktree)
        XCTAssertNil(identities.first { $0.id == childID })
        XCTAssertNil(identities.first { $0.id == nestedChildID })
        XCTAssertEqual(worktree?.displayName, "Investigate issue 47")
        XCTAssertEqual(
            worktree?.logPaths.map { URL(fileURLWithPath: $0).lastPathComponent },
            ["rollout-nested.jsonl"]
        )
    }

    func testCodexRunwayRecentSessionScannerKeepsCompletedRecentLogsDuringGrace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-complete-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"session-complete","cwd":"/Users/alexm/Repository/Codex-History","originator":"Codex Desktop"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"finished runway repair"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"task_complete"}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.first?.id, "session-complete")
        XCTAssertEqual(identities.first?.displayName, "finished runway repair")
        XCTAssertEqual(identities.first?.isGoal, false)
    }

    func testCodexRunwayRecentSessionScannerDiscoversRecentWorkBeforeTokenSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-pre-token-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"session-active","cwd":"/Users/alexm/Repository/Codex-History","originator":"Codex Desktop"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"investigate runway delay"}]}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.first?.id, "session-active")
        XCTAssertEqual(identities.first?.displayName, "investigate runway delay")
    }

    func testCodexRunwayRecentSessionScannerKeepsRecentCompletedGoalDuringGrace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-goal-complete-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"goal-session","cwd":"/Users/alexm/Repository/Codex-History","goal":{"objective":"repair runway"}}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"repair runway until clean"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"task_complete"}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.first?.id, "goal-session")
        XCTAssertEqual(identities.first?.isGoal, true)
    }

    func testCodexRunwayRecentSessionScannerDropsCompletedGoalAfterGrace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-goal-stale-\(UUID().uuidString)")
        let now = Date()
        let sampleAt = now.addingTimeInterval(-(CodexRunwayRecentSessionScanner.maximumGoalCompletionGrace + 5))
        let dir = root.appendingPathComponent("2026/06/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(sampleAt))","type":"session_meta","payload":{"id":"goal-session","cwd":"/Users/alexm/Repository/Codex-History","goal":{"objective":"repair runway"}}}
        {"timestamp":"\(iso(sampleAt))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        {"timestamp":"\(iso(sampleAt))","type":"event_msg","payload":{"type":"task_complete"}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities, [])
    }

    func testCodexRunwayRecentSessionScannerKeepsLogsActiveAfterPriorTurnCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-reopened-\(UUID().uuidString)")
        let now = Date()
        let prior = now.addingTimeInterval(-120)
        let dir = root.appendingPathComponent("2026/06/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(prior))","type":"session_meta","payload":{"id":"session-reopened","cwd":"/Users/alexm/Repository/Codex-History","originator":"Codex Desktop"}}
        {"timestamp":"\(iso(prior))","type":"event_msg","payload":{"type":"task_complete"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"continue runway repair"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":350000}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identities = CodexRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.first?.id, "session-reopened")
    }

    func testCodexRunwayRecentSessionScannerSkipsSetupContextForNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-setup-name-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"session-setup","cwd":"/Users/alexm/Repository/Codex-History","originator":"Codex Desktop"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /Users/alexm/Repository/Codex-History\\n\\n<INSTRUCTIONS>setup</INSTRUCTIONS>"},{"type":"input_text","text":"<environment_context>setup</environment_context>"}]}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix Runway session naming"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identity = CodexRunwayRecentSessionScanner.identities(root: root, now: now).first

        XCTAssertEqual(identity?.displayName, "fix Runway session naming")
    }

    func testCodexRunwayRecentSessionScannerPrefersSubagentNickname() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-nickname-\(UUID().uuidString)")
        let now = Date()
        let dir = root.appendingPathComponent("2026/06/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = dir.appendingPathComponent("rollout-test.jsonl")
        let text = """
        {"timestamp":"\(iso(now))","type":"session_meta","payload":{"id":"session-nick","cwd":"/Users/alexm/Repository/tennis-academy-map-ops","originator":"Codex Desktop","agent_nickname":"Feynman"}}
        {"timestamp":"\(iso(now))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /Users/alexm/Repository/tennis-academy-map-ops"}]}}
        {"timestamp":"\(iso(now))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: log.path)

        let identity = CodexRunwayRecentSessionScanner.identities(root: root, now: now).first

        XCTAssertEqual(identity?.displayName.hasPrefix("Feynman / tennis-academy"), true)
    }

    func testCodexRunwayLoaderFallsBackToTokenActivityWhenPercentIsFlat() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-loader-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(3 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100000}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":55.0,"window_minutes":300,"resets_at":"\(iso(reset))"}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":55.0,"window_minutes":300,"resets_at":"\(iso(reset))"}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 45,
            resetAt: reset,
            currentRunoutAt: second.addingTimeInterval(45 * 60),
            observedAt: second
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline,
            identities: [identity],
            now: second.addingTimeInterval(1),
            maxRows: 3,
            recentSessionsRoot: dir.appendingPathComponent("empty-sessions", isDirectory: true)
        )

        let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)

        XCTAssertEqual(snapshot?.rows.first?.id, "session")
        XCTAssertEqual(snapshot?.rows.first?.deadline, .afterReset)
        XCTAssertEqual(snapshot?.rows.first?.confidence, .mixed)
    }

    func testCodexRunwayLoaderDoesNotInventTokenBurnWithoutProjectedRunout() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-loader-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(3 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100000}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 45,
            resetAt: reset,
            currentRunoutAt: reset,
            observedAt: second,
            hasProjectedRunout: false
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline,
            identities: [identity],
            now: second.addingTimeInterval(1),
            maxRows: 3,
            recentSessionsRoot: dir.appendingPathComponent("empty-sessions", isDirectory: true)
        )

        let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)

        XCTAssertEqual(snapshot?.rows.map(\.id), ["session"])
        XCTAssertEqual(snapshot?.rows.first?.confidence, .waiting)
        XCTAssertEqual(snapshot?.rows.first?.displayRate ?? -1, 0, accuracy: 0.001)
        XCTAssertNil(snapshot?.burstSummary)
    }

    func testCodexRunwayLoaderShowsPendingActiveRowsBeforeBurnRatesArrive() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-loader-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(3 * 60 * 60)
        let identities = (1...6).map { index in
            RunwaySessionIdentity(
                id: "session-\(index)",
                displayName: "session \(index)",
                isGoal: false,
                logPaths: ["/tmp/no-samples-\(index).jsonl"]
            )
        }
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 45,
            resetAt: reset,
            currentRunoutAt: now.addingTimeInterval(45 * 60),
            observedAt: now,
            hasProjectedRunout: false
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline,
            identities: identities,
            now: now,
            maxRows: 4,
            recentSessionsRoot: dir.appendingPathComponent("empty-sessions", isDirectory: true)
        )

        let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)

        XCTAssertEqual(snapshot?.rows.map(\.id), ["session-1", "session-2", "session-3", "session-4"])
        XCTAssertEqual(snapshot?.rows.map(\.confidence), [.waiting, .waiting, .waiting, .waiting])
        XCTAssertEqual(snapshot?.burstSummary?.count, 2)
        XCTAssertEqual(snapshot?.burstSummary?.displayRate ?? -1, 0, accuracy: 0.001)
    }

    func testCodexRunwayLoaderPrefersDirectPercentBurnOverTokenAllocation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-loader-direct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(120)
        let reset = first.addingTimeInterval(3 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100000}},"rate_limits":{"limit_id":"codex","captured_at":"\(iso(first))","primary":{"remaining_percent":80.0,"resets_at":"\(iso(reset))"}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":600000}},"rate_limits":{"limit_id":"codex","captured_at":"\(iso(second))","primary":{"remaining_percent":79.0,"resets_at":"\(iso(reset))"}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let baseline = RunwayProviderBaseline(
            source: .codex,
            remainingPercent: 30,
            resetAt: reset,
            currentRunoutAt: second.addingTimeInterval(30 * 60),
            observedAt: second
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline,
            identities: [identity],
            now: second.addingTimeInterval(1),
            maxRows: 3,
            recentSessionsRoot: dir.appendingPathComponent("empty-sessions", isDirectory: true)
        )

        let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)

        XCTAssertEqual(snapshot?.rows.first?.confidence, .direct)
        XCTAssertEqual(snapshot?.rows.first?.displayRate ?? 0, 90, accuracy: 0.001)
    }

    func testCodexRunwayLoaderHoldsAggregateBurnAcrossOutputGap() async throws {
        // A gap in token output longer than maximumSampleAge (75s) makes a cycle's
        // aggregate read zero; the burn-rate chip must hold the last rate across
        // that gap (until the hold window elapses) instead of flickering out.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-burnhold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("empty-sessions", isDirectory: true)

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(3 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100000}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        func request(now: Date) -> CodexRunwaySnapshotRequest {
            CodexRunwaySnapshotRequest(
                baseline: RunwayProviderBaseline(
                    source: .codex, remainingPercent: 45, resetAt: reset,
                    currentRunoutAt: reset, observedAt: second, hasProjectedRunout: false
                ),
                identities: [identity],
                now: now,
                maxRows: 3,
                recentSessionsRoot: root
            )
        }
        CodexRunwaySnapshotLoader.burnHold.resetForTesting()

        // Cycle 1: newest sample fresh (<75s) → real rate measured (150k / 30s).
        let live = await CodexRunwaySnapshotLoader.snapshot(for: request(now: second.addingTimeInterval(1)))
        XCTAssertEqual(live?.aggregateTokensPerHour ?? 0, 5000 * 3600, accuracy: 1)

        // Cycle 2: newest sample now 90s old → this cycle measures zero, but the
        // hold keeps the last rate so the chip stays put.
        let held = await CodexRunwaySnapshotLoader.snapshot(for: request(now: second.addingTimeInterval(90)))
        XCTAssertEqual(held?.aggregateTokensPerHour ?? 0, 5000 * 3600, accuracy: 1)

        // Cycle 3: past the hold window (120s) → the rate clears.
        let cleared = await CodexRunwaySnapshotLoader.snapshot(for: request(now: second.addingTimeInterval(200)))
        XCTAssertNil(cleared?.aggregateTokensPerHour)
    }

    func testCodexRunwayTokenModeShowsPerSessionTokenRates() async throws {
        // Weekly window (rateUnit == .tokensPerHour): rows report raw per-session
        // token throughput (tk/h), ranked by rate, and never the weekly-scaled m/h.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-tokenmode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("empty-sessions", isDirectory: true)

        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(7 * 24 * 60 * 60)

        let logA = dir.appendingPathComponent("a.jsonl")
        let logB = dir.appendingPathComponent("b.jsonl")
        // A: 300000 tokens / 30s = 10000 tk/s. B: 60000 / 30s = 2000 tk/s.
        try """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100000}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":400000}}}}
        """.write(to: logA, atomically: true, encoding: .utf8)
        try """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10000}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":70000}}}}
        """.write(to: logB, atomically: true, encoding: .utf8)

        let idA = RunwaySessionIdentity(id: "a", displayName: "Session A", isGoal: false, logPaths: [logA.path])
        let idB = RunwaySessionIdentity(id: "b", displayName: "Session B", isGoal: false, logPaths: [logB.path])
        let baseline = RunwayProviderBaseline(
            source: .codex, remainingPercent: 73, resetAt: reset,
            currentRunoutAt: reset, observedAt: second, hasProjectedRunout: false,
            windowMinutes: 10080, rateUnit: .tokensPerHour
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline, identities: [idA, idB],
            now: second.addingTimeInterval(1), maxRows: 5, recentSessionsRoot: root
        )
        CodexRunwaySnapshotLoader.burnHold.resetForTesting()
        let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)

        // Faster session ranks first; rows carry tk/h (tokensPerSecond * 3600) in
        // the shared rate field, interpreted per the baseline's token unit.
        XCTAssertEqual(snapshot?.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(snapshot?.rows.first?.displayRate ?? 0, 10000 * 3600, accuracy: 1)
        XCTAssertEqual(snapshot?.rows.last?.displayRate ?? 0, 2000 * 3600, accuracy: 1)
        XCTAssertEqual(snapshot?.rows.first?.deadline, .unavailable)
    }

    func testCodexRunwayTokenRateNetsOutCachedContext() async throws {
        // total_tokens is cumulative and re-counts the cached context each turn, so
        // the runway must delta (total - cached_input_tokens); otherwise a re-sent
        // context reads as burn (the ~56M tk/h inflation).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-cached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("empty-sessions", isDirectory: true)

        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(7 * 24 * 60 * 60)
        let log = dir.appendingPathComponent("session.jsonl")
        // Netted: 100000 → 150000 (delta 50000 / 30s = 1666.7 tk/s → 6M tk/h).
        // Raw would be 700000 / 30s = 23333 tk/s → 84M tk/h (the inflated figure).
        try """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":500000,"cached_input_tokens":400000}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1200000,"cached_input_tokens":1050000}}}}
        """.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "s", displayName: "S", isGoal: false, logPaths: [log.path])
        let baseline = RunwayProviderBaseline(
            source: .codex, remainingPercent: 73, resetAt: reset,
            currentRunoutAt: reset, observedAt: second, hasProjectedRunout: false,
            windowMinutes: 10080, rateUnit: .tokensPerHour
        )
        let request = CodexRunwaySnapshotRequest(
            baseline: baseline, identities: [identity],
            now: second.addingTimeInterval(1), maxRows: 5, recentSessionsRoot: root
        )
        CodexRunwaySnapshotLoader.burnHold.resetForTesting()
        let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)

        XCTAssertEqual(snapshot?.rows.first?.displayRate ?? 0, 1666.6667 * 3600, accuracy: 100)
        XCTAssertLessThan(snapshot?.rows.first?.displayRate ?? .greatestFiniteMagnitude, 10_000_000,
                          "Cached context must be netted out (raw would be ~84M tk/h)")
    }

    func testCodexRunwayAggregateChipClearsWhenSessionsEnd() async throws {
        // The hold bridges output gaps while a session is active, but once the HUD
        // has no active sessions the "burning" chip clears immediately instead of
        // lingering for the full hold window (no phantom burn with nothing running).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-chipclear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("empty-sessions", isDirectory: true)

        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(7 * 24 * 60 * 60)
        let log = dir.appendingPathComponent("session.jsonl")
        try """
        {"timestamp":"\(iso(first))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":100000}}}}
        {"timestamp":"\(iso(second))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":250000}}}}
        """.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "s", displayName: "S", isGoal: false, logPaths: [log.path])
        func request(identities: [RunwaySessionIdentity], now: Date) -> CodexRunwaySnapshotRequest {
            CodexRunwaySnapshotRequest(
                baseline: RunwayProviderBaseline(
                    source: .codex, remainingPercent: 73, resetAt: reset,
                    currentRunoutAt: reset, observedAt: second, hasProjectedRunout: false,
                    windowMinutes: 10080
                ),
                identities: identities,
                now: now,
                maxRows: 5,
                recentSessionsRoot: root
            )
        }
        CodexRunwaySnapshotLoader.burnHold.resetForTesting()

        // Active session → chip shows.
        let active = await CodexRunwaySnapshotLoader.snapshot(for: request(identities: [identity], now: second.addingTimeInterval(1)))
        XCTAssertEqual(active?.aggregateTokensPerHour ?? 0, 5000 * 3600, accuracy: 1)

        // Sessions ended (no HUD identities) while still inside the 120s hold window
        // → chip clears immediately rather than lingering.
        let ended = await CodexRunwaySnapshotLoader.snapshot(for: request(identities: [], now: second.addingTimeInterval(40)))
        XCTAssertNil(ended?.aggregateTokensPerHour)
    }

    func testRunwayPresentationDefaultsToFiveHour() {
        XCTAssertEqual(RunwayPresentation.current(raw: ""), .fiveHour)
        XCTAssertEqual(RunwayPresentation.current(raw: "garbage"), .fiveHour)
        XCTAssertEqual(RunwayPresentation.current(raw: "weekly"), .weekly)
        XCTAssertEqual(RunwayPresentation.allCases.count, 4)
    }

    // MARK: - Quota Meter chrome

    /// An install that predates the key reads as `.onDemand` — upgrading users
    /// land on the no-hover-resize behavior rather than inheriting the defect.
    func testQuotaMeterChromeDefaultsToOnDemand() {
        XCTAssertEqual(QuotaMeterChrome.current(raw: ""), .onDemand)
        XCTAssertEqual(QuotaMeterChrome.current(raw: "garbage"), .onDemand)
        XCTAssertEqual(QuotaMeterChrome.current(raw: "always"), .always)
        XCTAssertEqual(QuotaMeterChrome.current(raw: "on_hover"), .onHover)
        XCTAssertEqual(QuotaMeterChrome.current(raw: "on_demand"), .onDemand)
        XCTAssertEqual(QuotaMeterChrome.allCases.count, 3)
    }

    /// The core promise: only `.onHover` lets a dwelling pointer put chrome on
    /// screen. If this ever passes for `.always`/`.onDemand` on the dwell alone,
    /// the window resizes under the mouse again.
    func testQuotaMeterChromeOnlyHoverRevealsOnDwell() {
        XCTAssertFalse(QuotaMeterChrome.onDemand.showsChrome(pointerDwelled: true, demandRevealed: false))
        XCTAssertTrue(QuotaMeterChrome.onHover.showsChrome(pointerDwelled: true, demandRevealed: false))

        // .always ignores both triggers entirely.
        XCTAssertTrue(QuotaMeterChrome.always.showsChrome(pointerDwelled: false, demandRevealed: false))

        // A right-click reveals on-demand chrome, and does nothing under hover.
        XCTAssertTrue(QuotaMeterChrome.onDemand.showsChrome(pointerDwelled: false, demandRevealed: true))
        XCTAssertFalse(QuotaMeterChrome.onHover.showsChrome(pointerDwelled: false, demandRevealed: true))
    }

    func testQuotaMeterChromeHintRecursOnDemand() {
        // Shown whenever the pointer dwells with the toolbar closed — and it says
        // nothing about prior use, so it recurs on every hover (right-click is the
        // only route back to the toolbar, so the reminder must stay findable).
        XCTAssertTrue(QuotaMeterChrome.onDemand.showsRightClickHint(pointerDwelled: true, demandRevealed: false))

        // Never competes with the chrome it is advertising, and needs the dwell.
        XCTAssertFalse(QuotaMeterChrome.onDemand.showsRightClickHint(pointerDwelled: true, demandRevealed: true))
        XCTAssertFalse(QuotaMeterChrome.onDemand.showsRightClickHint(pointerDwelled: false, demandRevealed: false))

        // Modes with visible controls have nothing to teach.
        XCTAssertFalse(QuotaMeterChrome.always.showsRightClickHint(pointerDwelled: true, demandRevealed: false))
        XCTAssertFalse(QuotaMeterChrome.onHover.showsRightClickHint(pointerDwelled: true, demandRevealed: false))
    }

    /// `.always` shows chrome unconditionally, so it needs no dwell bookkeeping;
    /// `.onHover` (reveal the toolbar) and `.onDemand` (re-show the recurring hint)
    /// both watch the pointer.
    func testQuotaMeterChromeArmsDwellTimer() {
        XCTAssertFalse(QuotaMeterChrome.always.armsDwellTimer())
        XCTAssertTrue(QuotaMeterChrome.onHover.armsDwellTimer())
        XCTAssertTrue(QuotaMeterChrome.onDemand.armsDwellTimer())
    }

    func testWeeklySnapshotAttributesPaceByTokenShare() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(5 * 24 * 3600)
        let runout = RunwayBaselineMath.averageBurnRunout(remainingPercent: 80, resetAt: reset,
                        windowLength: TimeInterval(10080 * 60), now: now)!
        let baseline = RunwayProviderBaseline(source: .codex, remainingPercent: 80, resetAt: reset,
                        currentRunoutAt: runout, observedAt: now, hasProjectedRunout: true,
                        windowMinutes: 10080, rateUnit: .weeklyPercentPerHour)
        let a = RunwaySessionActivity(identity: .init(id: "a", displayName: "A", isGoal: false, logPaths: ["/a"]),
                        tokensPerSecond: 300, sampleStart: now, sampleEnd: now)
        let b = RunwaySessionActivity(identity: .init(id: "b", displayName: "B", isGoal: false, logPaths: ["/b"]),
                        tokensPerSecond: 100, sampleStart: now, sampleEnd: now)
        let snap = CodexRunwayCalculator.weeklySnapshot(baseline: baseline, activities: [a, b], maxRows: 5)
        XCTAssertEqual(snap?.rows.map(\.id), ["a", "b"])
        let total = (snap?.rows.first?.displayRate ?? 0) + (snap?.rows.last?.displayRate ?? 0)
        XCTAssertGreaterThan(total, 0)
        // a burns 3× b → 75% of the provider weekly pace.
        XCTAssertEqual((snap?.rows.first?.displayRate ?? 0) / total, 0.75, accuracy: 0.01)
    }

    func testWeeklySnapshotNilWhenNoActivity() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(5 * 24 * 3600)
        let runout = RunwayBaselineMath.averageBurnRunout(remainingPercent: 80, resetAt: reset,
                        windowLength: TimeInterval(10080 * 60), now: now)!
        let baseline = RunwayProviderBaseline(source: .codex, remainingPercent: 80, resetAt: reset,
                        currentRunoutAt: runout, observedAt: now, hasProjectedRunout: true,
                        windowMinutes: 10080, rateUnit: .weeklyPercentPerHour)
        // No positive token activity → nil, so the loader falls back to token mode.
        XCTAssertNil(CodexRunwayCalculator.weeklySnapshot(baseline: baseline, activities: [], maxRows: 5))
    }

    func testPriceTableBundledAndPrefixMatch() {
        let t = RunwayPriceTable.makeForTesting()
        XCTAssertFalse(t.isEmpty)
        // Tier keys cover every current generation via longest-prefix (verified
        // 2026-07-14 against the official pricing pages).
        XCTAssertEqual(t.price(forModel: "claude-sonnet-5")?.outputPerMTok, 15.0)
        XCTAssertEqual(t.price(forModel: "claude-sonnet-4-5-20250929")?.outputPerMTok, 15.0)
        XCTAssertEqual(t.price(forModel: "claude-opus-4-8")?.outputPerMTok, 25.0)   // Opus dropped to $5/$25
        XCTAssertEqual(t.price(forModel: "claude-opus-4-8")?.inputPerMTok, 5.0)
        XCTAssertEqual(t.price(forModel: "claude-haiku-4-5-20251001")?.outputPerMTok, 5.0)
        XCTAssertEqual(t.price(forModel: "claude-fable-5")?.outputPerMTok, 50.0)     // Fable 5 frontier $10/$50
        // Codex tiers price distinctly via longest-prefix.
        XCTAssertEqual(t.price(forModel: "gpt-5.6-sol")?.outputPerMTok, 30.0)
        XCTAssertEqual(t.price(forModel: "gpt-5.6-terra")?.outputPerMTok, 15.0)
        XCTAssertEqual(t.price(forModel: "gpt-5.6-luna")?.outputPerMTok, 6.0)
        XCTAssertEqual(t.price(forModel: "gpt-5.4-mini")?.inputPerMTok, 0.75)        // longer prefix beats gpt-5.4
        XCTAssertEqual(t.price(forModel: "gpt-5-codex")?.inputPerMTok, 1.25)         // falls back to gpt-5
        XCTAssertNil(t.price(forModel: "totally-unknown-model"))
        XCTAssertNil(t.price(forModel: nil))
    }

    func testPriceTableRejectsMalformedAndUnrecognizedVersion() {
        let t = RunwayPriceTable.makeForTesting()
        let before = t.revision
        XCTAssertFalse(t.loadForTesting(json: Data("not json".utf8)))
        let futureVersion = #"{"version":999,"models":{"x":{"inputPerMTok":1,"cachedInputPerMTok":0,"outputPerMTok":1}}}"#
        XCTAssertFalse(t.loadForTesting(json: Data(futureVersion.utf8)))
        XCTAssertEqual(t.revision, before, "rejected manifests must not change the table")
        // Undated manifests sort oldest and are refused, so a live manifest must
        // carry an `updated` at least as new as the bundled table's.
        let undated = #"{"version":1,"models":{"zzz-model":{"inputPerMTok":9,"cachedInputPerMTok":1,"outputPerMTok":9}}}"#
        XCTAssertFalse(t.loadForTesting(json: Data(undated.utf8)))
        let ok = #"{"version":1,"updated":"2099-01-01","models":{"zzz-model":{"inputPerMTok":9,"cachedInputPerMTok":1,"outputPerMTok":9}}}"#
        XCTAssertTrue(t.loadForTesting(json: Data(ok.utf8)))
        XCTAssertEqual(t.price(forModel: "zzz-model")?.inputPerMTok, 9)
        XCTAssertGreaterThan(t.revision, before)
    }

    func testDollarSnapshotPricesPerTypeIncludingCache() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(3600)
        let baseline = RunwayProviderBaseline(source: .codex, remainingPercent: 50, resetAt: reset,
            currentRunoutAt: reset, observedAt: now, windowMinutes: 300, rateUnit: .dollarsPerHour)
        let table = RunwayPriceTable.makeForTesting()   // claude-sonnet-4: 3 / 0.3 / 15
        // Cache-heavy: netted tk/h would ignore the 1000/s cache reads, but $ prices them.
        let a = RunwaySessionActivity(
            identity: .init(id: "a", displayName: "A", isGoal: false, logPaths: ["/a"]),
            tokensPerSecond: 20, sampleStart: now, sampleEnd: now,
            inputPerSecond: 10, cachedInputPerSecond: 1000, outputPerSecond: 10,
            cacheCreationPerSecond: 0, modelSlug: "claude-sonnet-4-5")
        let snap = CodexRunwayCalculator.dollarSnapshot(baseline: baseline, activities: [a], priceTable: table, maxRows: 5)
        let inputCost: Double = 10.0 * 3.0
        let cachedCost: Double = 1000.0 * 0.3
        let outputCost: Double = 10.0 * 15.0
        let expected: Double = (inputCost + cachedCost + outputCost) / 1_000_000.0 * 3600.0
        XCTAssertEqual(snap?.snapshot.rows.first?.displayRate ?? 0, expected, accuracy: 1e-6)
        // Cache dominates the cost, so $/h is NOT proportional to the netted tk/h.
        XCTAssertGreaterThan(snap?.snapshot.rows.first?.displayRate ?? 0, 0)
        XCTAssertEqual(snap?.unpriceableIDs, [], "a fully priced set drops nothing")
    }

    func testDollarSnapshotNilWhenNothingPriceable() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(3600)
        let baseline = RunwayProviderBaseline(source: .codex, remainingPercent: 50, resetAt: reset,
            currentRunoutAt: reset, observedAt: now, windowMinutes: 300, rateUnit: .dollarsPerHour)
        let table = RunwayPriceTable.makeForTesting()
        let a = RunwaySessionActivity(
            identity: .init(id: "a", displayName: "A", isGoal: false, logPaths: ["/a"]),
            tokensPerSecond: 20, sampleStart: now, sampleEnd: now,
            inputPerSecond: 10, cachedInputPerSecond: 0, outputPerSecond: 10,
            cacheCreationPerSecond: 0, modelSlug: "no-such-model")
        // Nothing priceable at all → nil so the loader falls back to token snapshot-wide.
        XCTAssertNil(CodexRunwayCalculator.dollarSnapshot(baseline: baseline, activities: [a], priceTable: table, maxRows: 5))
    }

    /// Route B: one unpriceable session must NOT drag the whole provider to tk/h.
    /// Previously any unpriced model returned nil → snapshot-wide token fallback, so
    /// a session flipping between active and idle flapped the unit every refresh.
    func testDollarSnapshotDropsUnpriceableAndKeepsPricedRows() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(3600)
        let baseline = RunwayProviderBaseline(source: .codex, remainingPercent: 50, resetAt: reset,
            currentRunoutAt: reset, observedAt: now, windowMinutes: 300, rateUnit: .dollarsPerHour)
        let table = RunwayPriceTable.makeForTesting()
        let priced = RunwaySessionActivity(
            identity: .init(id: "priced", displayName: "Priced", isGoal: false, logPaths: ["/p"]),
            tokensPerSecond: 20, sampleStart: now, sampleEnd: now,
            inputPerSecond: 10, cachedInputPerSecond: 0, outputPerSecond: 10,
            cacheCreationPerSecond: 0, modelSlug: "claude-sonnet-5")
        let unknownModel = RunwaySessionActivity(
            identity: .init(id: "unknown", displayName: "Unknown", isGoal: false, logPaths: ["/u"]),
            tokensPerSecond: 20, sampleStart: now, sampleEnd: now,
            inputPerSecond: 10, cachedInputPerSecond: 0, outputPerSecond: 10,
            cacheCreationPerSecond: 0, modelSlug: "no-such-model")
        // Legacy Codex log format: throughput but no per-type breakdown → unpriceable.
        let noPerType = RunwaySessionActivity(
            identity: .init(id: "legacy", displayName: "Legacy", isGoal: false, logPaths: ["/l"]),
            tokensPerSecond: 500, sampleStart: now, sampleEnd: now,
            inputPerSecond: 0, cachedInputPerSecond: 0, outputPerSecond: 0,
            cacheCreationPerSecond: 0, modelSlug: "claude-sonnet-5")

        let snap = CodexRunwayCalculator.dollarSnapshot(
            baseline: baseline, activities: [priced, unknownModel, noPerType], priceTable: table, maxRows: 5)
        XCTAssertNotNil(snap, "a priceable peer must keep the snapshot in $")
        XCTAssertEqual(snap?.snapshot.rows.map(\.id), ["priced"], "only the priceable session gets a $ row")

        // The dropped set comes back with the snapshot (single source of truth) so
        // the loader can keep them out of pending rows — otherwise they'd render
        // "$0/h" while actively burning.
        XCTAssertEqual(snap?.unpriceableIDs, ["unknown", "legacy"])

        // Pin the ACTUAL bug, not just the calculator: feeding every active identity
        // to withPendingRows (what the loader does) must not resurrect a dropped
        // session as a zero-dollar row. Previously each unpriceable session came back
        // with displayRate 0 → "$0/h" beside a real $ row.
        let allIdentities = [priced, unknownModel, noPerType].map(\.identity)
        let leaked = RunwaySnapshotAssembly.withPendingRows(
            baseline: baseline, snapshot: snap?.snapshot,
            activeIdentities: allIdentities, maxRows: 5)
        XCTAssertEqual(Set(leaked?.rows.map(\.id) ?? []), ["priced", "unknown", "legacy"],
                       "unfiltered identities leak dropped sessions back in as $0 rows")

        // With the loader's filter applied, only the priceable session survives.
        let filtered = allIdentities.filter { !(snap?.unpriceableIDs.contains($0.id) ?? false) }
        let clean = RunwaySnapshotAssembly.withPendingRows(
            baseline: baseline, snapshot: snap?.snapshot,
            activeIdentities: filtered, maxRows: 5)
        XCTAssertEqual(clean?.rows.map(\.id), ["priced"])
        XCTAssertTrue(clean?.rows.allSatisfy { $0.displayRate > 0 } ?? false,
                      "no $0/h row may survive in the $ view")
    }

    /// Regression: after a mid-session `/model` switch, tokens must be priced at the
    /// CURRENT model. Resolving from the file's FIRST turn_context returned the model
    /// the session started with, so a switch to a cheap tier stayed billed at the
    /// expensive one for the rest of a long turn (gpt-5.6-sol $5/$30 vs luna $1/$6).
    func testCodexRunwayModelUsesLatestTurnContextAfterModelSwitch() throws {
        CodexRunwayTokenActivityParser.resetModelCacheForTesting()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        let ctxOld = "{\"timestamp\":\"\(iso(first))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}"
        let ctxNew = "{\"timestamp\":\"\(iso(first))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-luna\"}}"
        let tok1 = "{\"timestamp\":\"\(iso(first))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":800,\"output_tokens\":100,\"total_tokens\":1100}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        let tok2 = "{\"timestamp\":\"\(iso(second))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":2000,\"cached_input_tokens\":1600,\"output_tokens\":200,\"total_tokens\":2200}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        // sol first, then the user switches to luna; a long turn follows, so BOTH
        // turn_context lines sit outside the token tail.
        let text = ctxOld + "\n" + ctxNew + "\n" + tok1 + "\n" + tok2
        try text.write(to: log, atomically: true, encoding: .utf8)

        let tailBytes = (tok1 + "\n" + tok2).utf8.count
        let samples = CodexRunwayTokenActivityParser.recentSamples(
            fromLogPath: log.path, maxBytes: tailBytes, now: second.addingTimeInterval(1))

        XCTAssertEqual(samples.count, 2)
        XCTAssertTrue(samples.allSatisfy { $0.modelSlug == "gpt-5.6-luna" },
                      "must price at the switched-to model, not the session's first")
    }

    /// Regression for the *stale cache* path: the earlier switch test cleared the
    /// cache first, so it never exercised the case that actually breaks — a model
    /// already cached from a previous cycle. Consulting that cache without
    /// re-checking newly-appended bytes keeps pricing at the OLD model for the rest
    /// of a long turn, because the switch's `turn_context` is outside the token tail
    /// and nothing else would ever notice it.
    func testCodexRunwayModelSwitchDetectedWithWarmCache() throws {
        CodexRunwayTokenActivityParser.resetModelCacheForTesting()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let reset = t0.addingTimeInterval(5 * 60 * 60)
        func tok(_ at: Date, _ input: Int, _ cached: Int, _ output: Int, _ total: Int) -> String {
            "{\"timestamp\":\"\(iso(at))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output),\"total_tokens\":\(total)}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        }
        let ctxSol = "{\"timestamp\":\"\(iso(t0))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}"
        let tok1 = tok(t0, 1000, 800, 100, 1100)
        let tok2 = tok(t0.addingTimeInterval(30), 2000, 1600, 200, 2200)

        // Cycle 1: the tail sees sol → cache warms to sol.
        try (ctxSol + "\n" + tok1 + "\n" + tok2).write(to: log, atomically: true, encoding: .utf8)
        let first = CodexRunwayTokenActivityParser.recentSamples(
            fromLogPath: log.path, now: t0.addingTimeInterval(31))
        XCTAssertTrue(first.allSatisfy { $0.modelSlug == "gpt-5.6-sol" }, "cache should warm to sol")

        // The user switches to luna, then a long turn appends past the tail window.
        let ctxLuna = "{\"timestamp\":\"\(iso(t0.addingTimeInterval(40)))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-luna\"}}"
        let tok3 = tok(t0.addingTimeInterval(60), 3000, 2400, 300, 3300)
        let tok4 = tok(t0.addingTimeInterval(90), 4000, 3200, 400, 4400)
        let appended = "\n" + ctxLuna + "\n" + tok3 + "\n" + tok4
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        // Cycle 2: tail covers only tok3/tok4 — no turn_context — and the cache is
        // warm with the STALE sol. It must still resolve to luna.
        let tailBytes = (tok3 + "\n" + tok4).utf8.count
        let second = CodexRunwayTokenActivityParser.recentSamples(
            fromLogPath: log.path, maxBytes: tailBytes, now: t0.addingTimeInterval(91))
        XCTAssertEqual(second.count, 2)
        XCTAssertTrue(second.allSatisfy { $0.modelSlug == "gpt-5.6-luna" },
                      "a warm cache must not mask a /model switch in newly-appended bytes")
    }

    /// A log with no token lines must not trigger a head read at all — there are no
    /// samples to stamp, and paying a 1MB read per 5s refresh for nothing is waste.
    func testCodexRunwayNoTokenLinesResolvesWithoutHeadRead() throws {
        CodexRunwayTokenActivityParser.resetModelCacheForTesting()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-notok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        // turn_context only — a started session that hasn't emitted token_count yet.
        let text = "{\"timestamp\":\"\(iso(first))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}"
        try text.write(to: log, atomically: true, encoding: .utf8)

        let samples = CodexRunwayTokenActivityParser.recentSamples(
            fromLogPath: log.path, now: first.addingTimeInterval(1))
        XCTAssertTrue(samples.isEmpty, "no token_count lines → no samples")
    }

    /// Regression: a session's subagent transcripts fold into the parent identity as
    /// extra log paths and routinely run a cheaper model. Summing every path's tokens
    /// and pricing the total at one model (the parent's — it always sorts first)
    /// misprices every subagent slice. Measured 1.13x overstatement on a real
    /// opus-parent/sonnet-subagent session; up to 10x for a fable orchestrator
    /// driving haiku subagents.
    func testDollarSnapshotPricesEachModelComponentAtItsOwnRate() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(3600)
        let baseline = RunwayProviderBaseline(source: .claude, remainingPercent: 50, resetAt: reset,
            currentRunoutAt: reset, observedAt: now, windowMinutes: 300, rateUnit: .dollarsPerHour)
        let table = RunwayPriceTable.makeForTesting()

        // Opus parent + sonnet subagent, each burning 100 output tok/s.
        let opus = RunwayModelComponent(modelSlug: "claude-opus-4-8", inputPerSecond: 0,
                                        cachedInputPerSecond: 0, outputPerSecond: 100, cacheCreationPerSecond: 0)
        let sonnet = RunwayModelComponent(modelSlug: "claude-sonnet-5", inputPerSecond: 0,
                                          cachedInputPerSecond: 0, outputPerSecond: 100, cacheCreationPerSecond: 0)
        let activity = RunwaySessionActivity(
            identity: .init(id: "s", displayName: "S", isGoal: false, logPaths: ["/p", "/p/subagents/a"]),
            tokensPerSecond: 200, sampleStart: now, sampleEnd: now,
            components: [opus, sonnet])
        // Totals derive from components — they cannot drift from what $ prices.
        XCTAssertEqual(activity.outputPerSecond, 200)

        // Correct: 100*25 (opus out) + 100*15 (sonnet out), per second → /1e6 * 3600.
        let expected: Double = (100.0 * 25.0 + 100.0 * 15.0) / 1_000_000.0 * 3600.0
        let snap = CodexRunwayCalculator.dollarSnapshot(
            baseline: baseline, activities: [activity], priceTable: table, maxRows: 5)
        XCTAssertEqual(snap?.snapshot.rows.first?.displayRate ?? 0, expected, accuracy: 1e-9)

        // The old behaviour priced all 200 tok/s at the parent's model. Pin that the
        // blended figure is NOT what we produce.
        let blended: Double = (200.0 * 25.0) / 1_000_000.0 * 3600.0
        XCTAssertNotEqual(snap?.snapshot.rows.first?.displayRate ?? 0, blended, accuracy: 1e-9)
        XCTAssertLessThan(snap?.snapshot.rows.first?.displayRate ?? 0, blended,
                          "blending subagent tokens into the parent's model overstates cost")
    }

    /// Pins the WIRING, not just the calculator: two real transcripts on different
    /// models, folded into one identity the way a parent + its subagents are, driven
    /// through `activity(identity:)`. Without this, deleting the `components:` line
    /// from the aggregate silently reverts to blending every subagent's tokens into
    /// whichever path sorts first — and every other test still passes.
    func testCodexRunwayMultiPathIdentityKeepsPerPathModels() throws {
        CodexRunwayTokenActivityParser.resetModelCacheForTesting()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-multipath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let reset = t0.addingTimeInterval(5 * 60 * 60)
        func tok(_ at: Date, _ input: Int, _ cached: Int, _ output: Int, _ total: Int) -> String {
            "{\"timestamp\":\"\(iso(at))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output),\"total_tokens\":\(total)}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        }
        func write(_ name: String, model: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            let ctx = "{\"timestamp\":\"\(iso(t0))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
            // 0 → 300 output over 30s on each path = 10 output tok/s each.
            let text = ctx + "\n" + tok(t0, 0, 0, 0, 0) + "\n" + tok(t0.addingTimeInterval(30), 0, 0, 300, 300)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        // Expensive "parent" sorts first (a.jsonl) — exactly the bias that misprices.
        let parent = try write("a-parent.jsonl", model: "gpt-5.6-sol")
        let child = try write("b-child.jsonl", model: "gpt-5.6-luna")

        let identity = RunwaySessionIdentity(id: "s", displayName: "S", isGoal: false,
                                             logPaths: [parent, child])
        let activity = CodexRunwayTokenActivityParser.activity(
            identity: identity, now: t0.addingTimeInterval(31))

        let models = Set((activity?.components ?? []).map { $0.modelSlug })
        XCTAssertEqual(models, ["gpt-5.6-sol", "gpt-5.6-luna"],
                       "each path must keep its own model, not collapse to the first")
        XCTAssertEqual(activity?.outputPerSecond ?? 0, 20, accuracy: 0.001, "totals still sum both paths")

        // sol out $30/MTok, luna out $6/MTok → 10*30 + 10*6, NOT 20*30.
        let table = RunwayPriceTable.makeForTesting()
        let expected: Double = (10.0 * 30.0 + 10.0 * 6.0) / 1_000_000.0 * 3600.0
        let blended: Double = (20.0 * 30.0) / 1_000_000.0 * 3600.0
        let rate = CodexRunwayCalculator.dollarsPerHour(for: activity!, priceTable: table)
        XCTAssertEqual(rate ?? 0, expected, accuracy: 1e-9)
        XCTAssertLessThan(rate ?? 0, blended, "blending the child into the parent's model overstates cost")
    }

    /// A zero-rate slice can't make a session unpriceable, but a *contributing* slice
    /// we can't price must drop the whole session rather than silently understate it.
    func testDollarSnapshotComponentPriceabilityRules() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(3600)
        let baseline = RunwayProviderBaseline(source: .claude, remainingPercent: 50, resetAt: reset,
            currentRunoutAt: reset, observedAt: now, windowMinutes: 300, rateUnit: .dollarsPerHour)
        let table = RunwayPriceTable.makeForTesting()
        let known = RunwayModelComponent(modelSlug: "claude-sonnet-5", inputPerSecond: 0,
                                         cachedInputPerSecond: 0, outputPerSecond: 100, cacheCreationPerSecond: 0)
        let idleUnknown = RunwayModelComponent(modelSlug: "who-knows", inputPerSecond: 0,
                                               cachedInputPerSecond: 0, outputPerSecond: 0, cacheCreationPerSecond: 0)
        let busyUnknown = RunwayModelComponent(modelSlug: "who-knows", inputPerSecond: 0,
                                               cachedInputPerSecond: 0, outputPerSecond: 100, cacheCreationPerSecond: 0)
        func activity(_ components: [RunwayModelComponent]) -> RunwaySessionActivity {
            RunwaySessionActivity(
                identity: .init(id: "s", displayName: "S", isGoal: false, logPaths: ["/p"]),
                tokensPerSecond: 100, sampleStart: now, sampleEnd: now,
                components: components)
        }
        // A zero-rate unknown slice costs nothing → still priceable.
        XCTAssertNotNil(CodexRunwayCalculator.dollarsPerHour(
            for: activity([known, idleUnknown]), priceTable: table))
        // A burning unknown slice → drop the session (never understate).
        XCTAssertNil(CodexRunwayCalculator.dollarsPerHour(
            for: activity([known, busyUnknown]), priceTable: table))
    }

    /// A stale cached manifest must never shadow a corrected bundled table.
    func testPriceTableIgnoresOlderCachedManifest() {
        let t = RunwayPriceTable.makeForTesting()   // bundled, updated 2026-07-14
        let opusBefore = t.price(forModel: "claude-opus-4-8")?.outputPerMTok
        let stale = #"{"version":1,"updated":"2020-01-01","models":{"claude-opus":{"inputPerMTok":99,"cachedInputPerMTok":9,"outputPerMTok":999}}}"#
        XCTAssertFalse(t.loadForTesting(json: Data(stale.utf8)),
                       "a manifest older than the bundled table must be rejected")
        XCTAssertEqual(t.price(forModel: "claude-opus-4-8")?.outputPerMTok, opusBefore)
        let newer = #"{"version":1,"updated":"2099-01-01","models":{"claude-opus":{"inputPerMTok":7,"cachedInputPerMTok":1,"outputPerMTok":33}}}"#
        XCTAssertTrue(t.loadForTesting(json: Data(newer.utf8)))
        XCTAssertEqual(t.price(forModel: "claude-opus-4-8")?.outputPerMTok, 33)
    }

    /// Legacy keys must still price (and must not shadow current-generation slugs).
    func testPriceTableLegacyKeysPriceWithoutShadowingCurrent() {
        let t = RunwayPriceTable.makeForTesting()
        XCTAssertEqual(t.price(forModel: "claude-3-5-sonnet-20241022")?.outputPerMTok, 15.0)
        XCTAssertEqual(t.price(forModel: "claude-3-5-haiku-20241022")?.outputPerMTok, 4.0)
        XCTAssertEqual(t.price(forModel: "claude-3-opus-20240229")?.outputPerMTok, 75.0)
        XCTAssertEqual(t.price(forModel: "claude-opus-4-1-20250805")?.outputPerMTok, 75.0)
        // The deprecated claude-opus-4-1 key must NOT capture current Opus.
        XCTAssertEqual(t.price(forModel: "claude-opus-4-8")?.outputPerMTok, 25.0)
    }

    /// Regression: Codex logs the model only on `turn_context` (once per turn) while
    /// token counts stream on separate `token_count` lines. When one turn dumps more
    /// than the read window, the tail holds token lines but no `turn_context`, so every
    /// sample used to get `modelSlug == nil` → `price(nil)` == nil → `dollarSnapshot`
    /// nils out and the WHOLE Codex provider fell back to tk/h. The model must now be
    /// recovered by widening the scan beyond the token tail so pricing survives.
    func testCodexRunwayModelResolvedBeyondTailWhenTailLacksTurnContext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-headmodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        let pad = String(repeating: "x", count: 4000)   // push turn_context out of the token tail
        let ctx = "{\"timestamp\":\"\(iso(first))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\",\"cwd\":\"\(pad)\"}}"
        let tok1 = "{\"timestamp\":\"\(iso(first))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":800,\"output_tokens\":100,\"total_tokens\":1100}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        let tok2 = "{\"timestamp\":\"\(iso(second))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":2000,\"cached_input_tokens\":1600,\"output_tokens\":200,\"total_tokens\":2200}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        let text = ctx + "\n" + tok1 + "\n" + tok2   // no trailing newline
        try text.write(to: log, atomically: true, encoding: .utf8)

        // maxBytes = exactly the two token lines → the tail excludes the padded turn_context.
        let tailBytes = (tok1 + "\n" + tok2).utf8.count
        let samples = CodexRunwayTokenActivityParser.recentSamples(fromLogPath: log.path, maxBytes: tailBytes, now: second.addingTimeInterval(1))

        XCTAssertEqual(samples.count, 2, "both token lines should parse")
        XCTAssertTrue(samples.allSatisfy { $0.modelSlug == "gpt-5.6-sol" },
                      "model must be resolved from the file head when the tail lacks a turn_context")
    }

    /// Regression for the observed $/tk flap: Codex's `session_meta` first line is
    /// tens of KB (tool schemas), so the first `turn_context` (the only model
    /// carrier) sits well past 64 KB. When a large session is parsed cold and the
    /// token tail also lacks a `turn_context`, a 64 KB head read missed the model →
    /// nil → the whole Codex provider flapped to tk/h whenever that session was
    /// active. The head read must clear a large `session_meta`.
    func testCodexRunwayModelResolvedPastLargeSessionMeta() throws {
        CodexRunwayTokenActivityParser.resetModelCacheForTesting()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-bigmeta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        // ~70KB session_meta — larger than the old 64KB head window.
        let bigMeta = "{\"timestamp\":\"\(iso(first))\",\"type\":\"session_meta\",\"payload\":{\"model_provider\":\"openai\",\"pad\":\"\(String(repeating: "x", count: 70000))\"}}"
        let ctx = "{\"timestamp\":\"\(iso(first))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}"
        let tok1 = "{\"timestamp\":\"\(iso(first))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":800,\"output_tokens\":100,\"total_tokens\":1100}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        let tok2 = "{\"timestamp\":\"\(iso(second))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":2000,\"cached_input_tokens\":1600,\"output_tokens\":200,\"total_tokens\":2200}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        let text = bigMeta + "\n" + ctx + "\n" + tok1 + "\n" + tok2
        try text.write(to: log, atomically: true, encoding: .utf8)

        // Small tail → excludes session_meta AND the turn_context; only token lines.
        let tailBytes = (tok1 + "\n" + tok2).utf8.count
        let samples = CodexRunwayTokenActivityParser.recentSamples(fromLogPath: log.path, maxBytes: tailBytes, now: second.addingTimeInterval(1))

        XCTAssertEqual(samples.count, 2)
        XCTAssertTrue(samples.allSatisfy { $0.modelSlug == "gpt-5.6-sol" },
                      "head read must clear a >64KB session_meta to find the first turn_context model")
    }

    /// Regression: token lines that precede the tail's first `turn_context` are stamped
    /// via backfill from the first in-tail model (a session is effectively single-model).
    func testCodexRunwayModelBackfilledForLinesBeforeTailTurnContext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-backfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(30)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        let tok1 = "{\"timestamp\":\"\(iso(first))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":800,\"output_tokens\":100,\"total_tokens\":1100}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        let ctx = "{\"timestamp\":\"\(iso(first))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}"
        let tok2 = "{\"timestamp\":\"\(iso(second))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":2000,\"cached_input_tokens\":1600,\"output_tokens\":200,\"total_tokens\":2200}},\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":\"\(iso(reset))\"}}}}"
        let text = tok1 + "\n" + ctx + "\n" + tok2   // token line BEFORE the turn_context
        try text.write(to: log, atomically: true, encoding: .utf8)

        let samples = CodexRunwayTokenActivityParser.recentSamples(fromLogPath: log.path, now: second.addingTimeInterval(1))

        XCTAssertEqual(samples.count, 2)
        XCTAssertTrue(samples.allSatisfy { $0.modelSlug == "gpt-5.6-sol" },
                      "the leading token line must be backfilled with the session model")
    }

    func testCodexRunwayParserIgnoresStaleRateLimitSamples() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(120)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","payload":{"rate_limits":{"limit_id":"codex","captured_at":"\(iso(first))","primary":{"remaining_percent":80.0,"resets_at":"\(iso(reset))"}}}}
        {"timestamp":"\(iso(second))","payload":{"rate_limits":{"limit_id":"codex","captured_at":"\(iso(second))","primary":{"remaining_percent":78.5,"resets_at":"\(iso(reset))"}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let staleNow = second.addingTimeInterval(CodexRunwayRateLimitParser.maximumSampleAge + 1)
        let burn = CodexRunwayRateLimitParser.burn(identity: identity, now: staleNow)

        XCTAssertNil(burn)
    }

    func testCodexRunwayParserIgnoresOverwideRateLimitSamplePair() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-runway-wide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let first = Date(timeIntervalSince1970: 2_000_000)
        let second = first.addingTimeInterval(CodexRunwayRateLimitParser.maximumPairInterval + 1)
        let reset = first.addingTimeInterval(5 * 60 * 60)
        let text = """
        {"timestamp":"\(iso(first))","payload":{"rate_limits":{"limit_id":"codex","captured_at":"\(iso(first))","primary":{"remaining_percent":80.0,"resets_at":"\(iso(reset))"}}}}
        {"timestamp":"\(iso(second))","payload":{"rate_limits":{"limit_id":"codex","captured_at":"\(iso(second))","primary":{"remaining_percent":78.5,"resets_at":"\(iso(reset))"}}}}
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let burn = CodexRunwayRateLimitParser.burn(identity: identity, now: second.addingTimeInterval(1))

        XCTAssertNil(burn)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

#if DEBUG
    func testCodexStatusRegexFactoryFallbackAndValidPattern() {
        let invalid = CodexStatusService.buildRegexForTesting(
            pattern: "(",
            label: "invalid-regex-test"
        )
        XCTAssertNotNil(invalid, "Invalid pattern should fall back to a usable never-match regex")

        let normalText = "Current usage: 73% remaining"
        let normalRange = NSRange(normalText.startIndex..<normalText.endIndex, in: normalText)
        XCTAssertNil(
            invalid?.firstMatch(in: normalText, options: [], range: normalRange),
            "Fallback regex should not match normal text"
        )

        let valid = CodexStatusService.buildRegexForTesting(
            pattern: "(\\d{1,3})\\s*%",
            options: [.caseInsensitive],
            label: "valid-regex-test"
        )
        XCTAssertNotNil(valid, "Valid pattern should produce a regex")

        let percentLine = "Primary window: 19% remaining"
        let percentRange = NSRange(percentLine.startIndex..<percentLine.endIndex, in: percentLine)
        let match = valid?.firstMatch(in: percentLine, options: [], range: percentRange)
        XCTAssertNotNil(match, "Valid regex should match a percent status line")
    }

    @MainActor
    func testMakeSplitFinderViewFromCoderForTestingWithRealCoderDoesNotCrash() throws {
        let archiveData = try NSKeyedArchiver.archivedData(
            withRootObject: ["probe": "split-coder"],
            requiringSecureCoding: false
        )
        let coder = try NSKeyedUnarchiver(forReadingFrom: archiveData)
        defer { coder.finishDecoding() }

        _ = makeSplitFinderViewFromCoderForTesting(coder)
    }
#endif
}
