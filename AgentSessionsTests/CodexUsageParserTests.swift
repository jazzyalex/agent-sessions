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
        let runoutAt = tracker.update(with: second, now: secondTime)

        XCTAssertEqual(formatUsageProjectionLabel(runoutAt: runoutAt, observedAt: secondTime, now: secondTime), "▸44m")
    }

    func testUsageLimitProjectionTrackerRetainsProjectionAcrossSameRoundedPercentRefresh() {
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
        XCTAssertEqual(formatUsageProjectionLabel(runoutAt: retained, observedAt: thirdTime, now: thirdTime), "▸43m")
    }

    func testUsageLimitProjectionTrackerIgnoresCachedData() {
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

        let runoutAt = tracker.update(with: UsageLimitProjectionSample(
            source: .codex,
            remainingPercent: 88,
            resetText: resetText,
            hasRateLimit: true,
            freshness: .recentCached,
            observedAt: secondTime
        ), now: secondTime)

        XCTAssertNil(runoutAt)
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
        store.recordScheduledReset(scheduled)

        XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsCodexSource), "5h OAuth / Wk JSONL")
        XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsCodexFreshness), "5h fresh / Wk recent cache")
        XCTAssertEqual(defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsCodexObservedAt), now.timeIntervalSince1970)
        XCTAssertEqual(defaults.string(forKey: PreferencesKey.usageLimitDiagnosticsCodexLastAlertSummary), "5h low, 9% left")
        XCTAssertEqual(defaults.double(forKey: PreferencesKey.usageLimitDiagnosticsCodexLastAlertAt), now.addingTimeInterval(10).timeIntervalSince1970)
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
