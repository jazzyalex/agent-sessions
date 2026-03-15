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
            sevenDaySonnet: nil
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
            sevenDaySonnet: nil
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertNotNil(snap.fiveHourUsedRatio)
        XCTAssertNil(snap.weeklyUsedRatio)
    }

    func testNormalize_bothWindowsMissing_returnsNil() {
        let raw = ClaudeOAuthRawUsageResponse(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil)
        XCTAssertNil(ClaudeUsageNormalizer.normalize(raw, bodyHash: ""))
    }

    func testNormalize_missingUtilization_treatedAsNil() {
        let raw = ClaudeOAuthRawUsageResponse(
            fiveHour: ClaudeOAuthRawUsageResponse.RawWindow(utilization: nil, resetsAt: nil),
            sevenDay: ClaudeOAuthRawUsageResponse.RawWindow(utilization: 50, resetsAt: nil),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
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

    // MARK: - Helpers

    private func makeResponse(
        fiveHourUtil: Double = 50, fiveHourResets: String? = nil,
        sevenDayUtil: Double = 50, sevenDayResets: String? = nil,
        sevenDayOpusUtil: Double? = nil
    ) -> ClaudeOAuthRawUsageResponse {
        ClaudeOAuthRawUsageResponse(
            fiveHour: ClaudeOAuthRawUsageResponse.RawWindow(utilization: fiveHourUtil, resetsAt: fiveHourResets),
            sevenDay: ClaudeOAuthRawUsageResponse.RawWindow(utilization: sevenDayUtil, resetsAt: sevenDayResets),
            sevenDayOpus: sevenDayOpusUtil.map { ClaudeOAuthRawUsageResponse.RawWindow(utilization: $0, resetsAt: nil) },
            sevenDaySonnet: nil
        )
    }
}
