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
