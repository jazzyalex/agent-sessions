import XCTest
@testable import AgentSessions

final class ClaudeUsageNormalizerTests: XCTestCase {

    // MARK: - Valid payloads

    func testNormalize_validPayload_producesCorrectRatios() {
        let raw = makeResponse(fiveHourUtil: 42.0, sevenDayUtil: 22.0)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "abc")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.42, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 0.22, accuracy: 0.001)
        XCTAssertEqual(snap.source, .oauthEndpoint)
        XCTAssertEqual(snap.health, .live)
        XCTAssertEqual(snap.rawPayloadHash, "abc")
    }

    func testNormalize_zeroUsed() {
        let raw = makeResponse(fiveHourUtil: 0.0, sevenDayUtil: 0.0)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.0, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 0.0, accuracy: 0.001)
        XCTAssertEqual(snap.fiveHourRemainingPercent, 100)
        XCTAssertEqual(snap.weeklyRemainingPercent, 100)
    }

    func testNormalize_fullyUsed() {
        let raw = makeResponse(fiveHourUtil: 100.0, sevenDayUtil: 100.0)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 1.0, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 1.0, accuracy: 0.001)
        XCTAssertEqual(snap.fiveHourRemainingPercent, 0)
        XCTAssertEqual(snap.weeklyRemainingPercent, 0)
    }

    // MARK: - Ratio clamping

    func testNormalize_utilizationAbove100_clampedToOne() {
        let raw = makeResponse(fiveHourUtil: 120.0, sevenDayUtil: 50.0)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertEqual(snap.fiveHourUsedRatio!, 1.0, accuracy: 0.001)
    }

    func testNormalize_utilizationNegative_clampedToZero() {
        let raw = makeResponse(fiveHourUtil: -10.0, sevenDayUtil: 50.0)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.0, accuracy: 0.001)
    }

    // MARK: - Missing sections

    func testNormalize_missingFiveHour_returnsNilFiveHourRatio() {
        let raw = ClaudeOAuthRawUsageResponse(
            fiveHour: nil,
            sevenDay: ClaudeOAuthRawUsageResponse.RawWindow(utilization: 50, resetsAt: nil),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            limits: nil
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertNil(snap.fiveHourUsedRatio)
        XCTAssertNotNil(snap.weeklyUsedRatio)
    }

    func testNormalize_missingSevenDay_returnsNilWeeklyRatio() {
        let raw = ClaudeOAuthRawUsageResponse(
            fiveHour: ClaudeOAuthRawUsageResponse.RawWindow(utilization: 50, resetsAt: nil),
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            limits: nil
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertNotNil(snap.fiveHourUsedRatio)
        XCTAssertNil(snap.weeklyUsedRatio)
    }

    func testNormalize_bothWindowsMissing_returnsNil() {
        let raw = ClaudeOAuthRawUsageResponse(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil, limits: nil)
        XCTAssertNil(ClaudeUsageNormalizer.normalize(raw, bodyHash: ""))
    }

    func testNormalize_missingUtilization_treatedAsNil() {
        let raw = ClaudeOAuthRawUsageResponse(
            fiveHour: ClaudeOAuthRawUsageResponse.RawWindow(utilization: nil, resetsAt: nil),
            sevenDay: ClaudeOAuthRawUsageResponse.RawWindow(utilization: 50, resetsAt: nil),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            limits: nil
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertNil(snap.fiveHourUsedRatio)
        XCTAssertNotNil(snap.weeklyUsedRatio)
    }

    // MARK: - Reset text passthrough

    func testNormalize_resetsAtPassedThrough() {
        let raw = makeResponse(
            fiveHourUtil: 50, fiveHourResets: "2026-03-14T09:00:00Z",
            sevenDayUtil: 50, sevenDayResets: "2026-03-19T20:00:00Z"
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourResetText, "2026-03-14T09:00:00Z")
        XCTAssertEqual(snap.weeklyResetText, "2026-03-19T20:00:00Z")
    }

    func testNormalize_emptyResetsProduceEmptyString() {
        let raw = makeResponse(fiveHourUtil: 50, sevenDayUtil: 50)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourResetText, "")
        XCTAssertEqual(snap.weeklyResetText, "")
    }

    // MARK: - Helper remainingPercent

    func testRemainingPercent_roundTrip() {
        let raw = makeResponse(fiveHourUtil: 63, sevenDayUtil: 27)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourRemainingPercent, 37)   // 100 - 63
        XCTAssertEqual(snap.weeklyRemainingPercent, 73)     // 100 - 27
    }

    // MARK: - OAuth client cache

    func testOAuthClientCacheFreshnessUsesThreeMinuteTTL() {
        XCTAssertEqual(ClaudeOAuthUsageClient.cacheMaxAgeForTesting, 3 * 60)
        XCTAssertTrue(ClaudeOAuthUsageClient.isCacheFreshForTesting(age: 60))
        XCTAssertTrue(ClaudeOAuthUsageClient.isCacheFreshForTesting(age: 3 * 60 - 1))
        XCTAssertFalse(ClaudeOAuthUsageClient.isCacheFreshForTesting(age: 3 * 60 + 1))
    }

    func testOAuthSourceManagerMarksCacheHitsAsCachedOAuth() {
        let raw = makeResponse(fiveHourUtil: 42, sevenDayUtil: 22)
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let live = ClaudeUsageSourceManager.normalizedOAuthSnapshotForTesting(
            raw,
            bodyHash: "live",
            fromCache: false,
            fetchedAt: fetchedAt
        )
        let cached = ClaudeUsageSourceManager.normalizedOAuthSnapshotForTesting(
            raw,
            bodyHash: "cached",
            fromCache: true,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(live?.source, .oauthEndpoint)
        XCTAssertEqual(cached?.source, .cachedOAuth)
        XCTAssertEqual(cached?.fetchedAt, fetchedAt)
    }

    // MARK: - Model-scoped weekly window (`limits[]`)

    /// The shape a current account actually returns, reduced to the keys that matter plus
    /// a sample of the codenamed experiment keys that ship alongside them. Decoding this
    /// is the real test: `percent` arrives as a JSON integer, `scope` is null on unscoped
    /// windows, and both legacy named keys are null.
    private static let liveShapeJSON = """
    {
      "five_hour": {"utilization": 44.0, "resets_at": "2026-01-02T19:59:59+00:00", "locked_reason": null},
      "seven_day": {"utilization": 46.0, "resets_at": "2026-01-04T11:59:59+00:00", "locked_reason": null},
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "nimbus_quill": {"utilization": 0.0, "resets_at": null},
      "juniper_tide": null,
      "extra_usage": {"is_enabled": false, "user_disabled": true},
      "limits": [
        {"kind": "session", "group": "session", "percent": 44, "severity": "normal",
         "resets_at": "2026-01-02T19:59:59+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 46, "severity": "normal",
         "resets_at": "2026-01-04T11:59:59+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 30, "severity": "normal",
         "resets_at": "2026-01-04T11:59:59+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
         "is_active": false}
      ],
      "member_dashboard_available": false
    }
    """

    private func decode(_ json: String) throws -> ClaudeOAuthRawUsageResponse {
        try JSONDecoder().decode(ClaudeOAuthRawUsageResponse.self, from: Data(json.utf8))
    }

    func testNormalize_liveShape_extractsScopedWeeklyWindowAndItsLabel() throws {
        let snap = ClaudeUsageNormalizer.normalize(try decode(Self.liveShapeJSON), bodyHash: "h")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.44, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 0.46, accuracy: 0.001)
        XCTAssertEqual(snap.weekOpusUsedRatio!, 0.30, accuracy: 0.001,
                       "the scoped window must come from limits[] when the legacy key is null")
        XCTAssertEqual(snap.weekScopedLabel, "Fable")
        XCTAssertEqual(snap.weekOpusRemainingPercent, 70)
        XCTAssertEqual(snap.weekOpusResetText, "2026-01-04T11:59:59+00:00")
    }

    /// Unknown `kind` values and unknown top-level keys must not fail the whole fetch —
    /// the payload is full of experiment keys that come and go.
    func testNormalize_unknownKindsAndKeysDoNotBreakDecoding() throws {
        let json = """
        {
          "five_hour": {"utilization": 10.0},
          "seven_day": {"utilization": 20.0},
          "brand_new_key": {"whatever": [1, 2, 3]},
          "limits": [
            {"kind": "something_new", "group": "weekly", "percent": 99,
             "scope": {"surface": {"name": "unknown"}}, "is_active": true},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 30,
             "scope": {"model": {"display_name": "Fable"}}, "is_active": false}
          ]
        }
        """
        let snap = ClaudeUsageNormalizer.normalize(try decode(json), bodyHash: "")!
        XCTAssertEqual(snap.weekOpusUsedRatio!, 0.30, accuracy: 0.001,
                       "an unrecognized kind must be ignored, not chosen")
        XCTAssertEqual(snap.weekScopedLabel, "Fable")
    }

    func testScopedWeekly_serverIsActiveFlagWinsOverHigherPercent() {
        let limits = [
            makeLimit(kind: "weekly_scoped", percent: 90, model: "Loud", isActive: false),
            makeLimit(kind: "weekly_scoped", percent: 30, model: "Binding", isActive: true)
        ]
        let scoped = ClaudeUsageNormalizer.scopedWeekly(from: limits)
        XCTAssertEqual(scoped?.label, "Binding",
                       "the server's is_active flag is authoritative over local comparison")
        XCTAssertEqual(scoped?.usedRatio ?? 0, 0.30, accuracy: 0.001)
    }

    func testScopedWeekly_withNoActiveFlagPicksTheMostConsumedWindow() {
        let limits = [
            makeLimit(kind: "weekly_scoped", percent: 12, model: "Quiet", isActive: false),
            makeLimit(kind: "weekly_scoped", percent: 77, model: "Hungry", isActive: false)
        ]
        XCTAssertEqual(ClaudeUsageNormalizer.scopedWeekly(from: limits)?.label, "Hungry")
    }

    func testScopedWeekly_ignoresNonScopedKindsAndEntriesWithNoPercent() {
        let limits = [
            makeLimit(kind: "weekly_all", percent: 95, model: nil, isActive: true),
            makeLimit(kind: "session", percent: 99, model: nil, isActive: false),
            makeLimit(kind: "weekly_scoped", percent: nil, model: "NoNumber", isActive: true)
        ]
        XCTAssertNil(ClaudeUsageNormalizer.scopedWeekly(from: limits),
                     "a scoped entry with no percent is not a window and must not read as 0%")
    }

    func testScopedWeekly_keepsTheWindowWhenTheModelNameIsAbsent() {
        let limits = [makeLimit(kind: "weekly_scoped", percent: 40, model: nil, isActive: true)]
        let scoped = ClaudeUsageNormalizer.scopedWeekly(from: limits)
        XCTAssertEqual(scoped?.usedRatio ?? 0, 0.40, accuracy: 0.001,
                       "a nameless scoped window is still a real limit")
        XCTAssertNil(scoped?.label)
    }

    func testNormalize_fallsBackToSevenDayOpusWhenLimitsAreAbsent() {
        let raw = makeResponse(sevenDayOpusUtil: 61.0, limits: nil)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertEqual(snap.weekOpusUsedRatio!, 0.61, accuracy: 0.001,
                       "older payloads still report the scoped window in the legacy key")
        XCTAssertNil(snap.weekScopedLabel, "the legacy key names no model")
    }

    func testNormalize_limitsWithoutAScopedWindowStillUsesTheLegacyKey() {
        let raw = makeResponse(sevenDayOpusUtil: 61.0,
                               limits: [makeLimit(kind: "weekly_all", percent: 46, model: nil, isActive: true)])
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertEqual(snap.weekOpusUsedRatio!, 0.61, accuracy: 0.001)
    }

    func testNormalize_noScopedWindowAnywhereLeavesItNil() {
        let snap = ClaudeUsageNormalizer.normalize(makeResponse(), bodyHash: "")!
        XCTAssertNil(snap.weekOpusUsedRatio)
        XCTAssertNil(snap.weekScopedLabel)
    }

    // MARK: - Helpers

    private func makeLimit(kind: String,
                           percent: Double?,
                           model: String?,
                           isActive: Bool) -> ClaudeOAuthRawUsageResponse.RawLimit {
        ClaudeOAuthRawUsageResponse.RawLimit(
            kind: kind,
            group: kind == "session" ? "session" : "weekly",
            percent: percent,
            severity: "normal",
            resetsAt: nil,
            isActive: isActive,
            scope: model.map {
                .init(model: .init(id: nil, displayName: $0))
            }
        )
    }

    private func makeResponse(
        fiveHourUtil: Double = 50, fiveHourResets: String? = nil,
        sevenDayUtil: Double = 50, sevenDayResets: String? = nil,
        sevenDayOpusUtil: Double? = nil,
        limits: [ClaudeOAuthRawUsageResponse.RawLimit]? = nil
    ) -> ClaudeOAuthRawUsageResponse {
        ClaudeOAuthRawUsageResponse(
            fiveHour: ClaudeOAuthRawUsageResponse.RawWindow(utilization: fiveHourUtil, resetsAt: fiveHourResets),
            sevenDay: ClaudeOAuthRawUsageResponse.RawWindow(utilization: sevenDayUtil, resetsAt: sevenDayResets),
            sevenDayOpus: sevenDayOpusUtil.map { ClaudeOAuthRawUsageResponse.RawWindow(utilization: $0, resetsAt: nil) },
            sevenDaySonnet: nil,
            limits: limits
        )
    }
}
