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

    func testUsageLimitProjectionTrackerStopsFormattingRetainedProjectionWhenBurnIsStale() {
        var tracker = UsageLimitProjectionTracker()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(6 * 60)
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

        let retained = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .fresh,
            observedAt: staleTime
        ), now: staleTime)

        XCTAssertEqual(retained?.observedAt, secondTime)
        XCTAssertNil(formatUsageProjectionLabel(runoutAt: retained?.runoutAt, observedAt: retained?.observedAt, now: staleTime))
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
        XCTAssertEqual(snapshot?.rows.first?.quotaMinutesPerHour ?? 0, 9, accuracy: 0.001)
        XCTAssertEqual(snapshot?.rows.last?.quotaMinutesPerHour ?? 0, 3, accuracy: 0.001)
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
        XCTAssertEqual(row?.quotaMinutesPerHour ?? 0, 60, accuracy: 0.001)
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
        XCTAssertEqual(snapshot?.burstSummary?.quotaMinutesPerHour ?? 0, 21.6, accuracy: 0.001)
    }

    func testCodexRunwayCalculatorHidesSubMinuteImpactRows() {
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

        XCTAssertEqual(snapshot?.rows, [])
        XCTAssertNil(snapshot?.burstSummary)
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

    func testCodexRunwayRecentSessionScannerIgnoresCompletedRecentLogs() throws {
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

        XCTAssertEqual(identities, [])
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
            maxRows: 3
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
            maxRows: 3
        )

        let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)

        XCTAssertEqual(snapshot?.rows, [])
        XCTAssertNil(snapshot?.burstSummary)
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
            maxRows: 3
        )

        let snapshot = await CodexRunwaySnapshotLoader.snapshot(for: request)

        XCTAssertEqual(snapshot?.rows.first?.confidence, .direct)
        XCTAssertEqual(snapshot?.rows.first?.quotaMinutesPerHour ?? 0, 90, accuracy: 0.001)
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
