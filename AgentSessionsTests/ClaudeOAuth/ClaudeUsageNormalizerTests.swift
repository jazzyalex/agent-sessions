import XCTest
@testable import AgentSessions

final class ClaudeUsageNormalizerTests: XCTestCase {

    // MARK: - Valid payloads

    func testNormalize_validPayload_producesCorrectRatios() {
        let raw = makeResponse(session5hPctLeft: 60, weekAllPctLeft: 25)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "abc")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.4, accuracy: 0.001) // 100 - 60 = 40% used
        XCTAssertEqual(snap.weeklyUsedRatio!, 0.75, accuracy: 0.001)  // 100 - 25 = 75% used
        XCTAssertEqual(snap.source, .oauthEndpoint)
        XCTAssertEqual(snap.health, .live)
        XCTAssertEqual(snap.rawPayloadHash, "abc")
    }

    func testNormalize_zeroUsed() {
        let raw = makeResponse(session5hPctLeft: 100, weekAllPctLeft: 100)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.0, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 0.0, accuracy: 0.001)
        XCTAssertEqual(snap.fiveHourRemainingPercent, 100)
        XCTAssertEqual(snap.weeklyRemainingPercent, 100)
    }

    func testNormalize_fullyUsed() {
        let raw = makeResponse(session5hPctLeft: 0, weekAllPctLeft: 0)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 1.0, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 1.0, accuracy: 0.001)
        XCTAssertEqual(snap.fiveHourRemainingPercent, 0)
        XCTAssertEqual(snap.weeklyRemainingPercent, 0)
    }

    // MARK: - Ratio clamping

    func testNormalize_pctLeftAbove100_clampedToZeroRatio() {
        let raw = makeResponse(session5hPctLeft: 120, weekAllPctLeft: 0)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!
        // 100 - 120 = -20 → clamp to 0
        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.0, accuracy: 0.001)
    }

    func testNormalize_pctLeftNegative_clampedToOneRatio() {
        let raw = makeResponse(session5hPctLeft: -10, weekAllPctLeft: 0)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!
        // 100 - (-10) = 110 → used = 110/100 = 1.1 → clamp to 1.0
        XCTAssertEqual(snap.fiveHourUsedRatio!, 1.0, accuracy: 0.001)
    }

    // MARK: - Missing sections

    func testNormalize_missingSession5h_returnsNilFiveHourRatio() {
        let raw = ClaudeOAuthRawUsageResponse(
            session5h: nil,
            weekAllModels: ClaudeOAuthRawUsageResponse.RawWindow(pctLeft: 50, resets: nil),
            weekOpus: nil
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertNil(snap.fiveHourUsedRatio)
        XCTAssertNotNil(snap.weeklyUsedRatio)
    }

    func testNormalize_missingWeekAllModels_returnsNilWeeklyRatio() {
        let raw = ClaudeOAuthRawUsageResponse(
            session5h: ClaudeOAuthRawUsageResponse.RawWindow(pctLeft: 50, resets: nil),
            weekAllModels: nil,
            weekOpus: nil
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertNotNil(snap.fiveHourUsedRatio)
        XCTAssertNil(snap.weeklyUsedRatio)
    }

    func testNormalize_bothWindowsMissing_returnsNil() {
        let raw = ClaudeOAuthRawUsageResponse(session5h: nil, weekAllModels: nil, weekOpus: nil)
        XCTAssertNil(ClaudeUsageNormalizer.normalize(raw, bodyHash: ""))
    }

    func testNormalize_missingPctLeft_treatedAsNil() {
        let raw = ClaudeOAuthRawUsageResponse(
            session5h: ClaudeOAuthRawUsageResponse.RawWindow(pctLeft: nil, resets: nil),
            weekAllModels: ClaudeOAuthRawUsageResponse.RawWindow(pctLeft: 50, resets: nil),
            weekOpus: nil
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertNil(snap.fiveHourUsedRatio)
        XCTAssertNotNil(snap.weeklyUsedRatio)
    }

    // MARK: - Reset text passthrough

    func testNormalize_resetsPassedThrough() {
        let raw = makeResponse(
            session5hPctLeft: 50, session5hResets: "Oct 9 at 2pm",
            weekAllPctLeft: 50, weekAllResets: "Oct 14 at 2pm"
        )
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourResetText, "Oct 9 at 2pm")
        XCTAssertEqual(snap.weeklyResetText, "Oct 14 at 2pm")
    }

    func testNormalize_emptyResetsProduceEmptyString() {
        let raw = makeResponse(session5hPctLeft: 50, weekAllPctLeft: 50)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourResetText, "")
        XCTAssertEqual(snap.weeklyResetText, "")
    }

    // MARK: - Helper remainingPercent

    func testRemainingPercent_roundTrip() {
        let raw = makeResponse(session5hPctLeft: 37, weekAllPctLeft: 73)
        let snap = ClaudeUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourRemainingPercent, 37)
        XCTAssertEqual(snap.weeklyRemainingPercent, 73)
    }

    // MARK: - Helpers

    private func makeResponse(
        session5hPctLeft: Int = 50, session5hResets: String? = nil,
        weekAllPctLeft: Int = 50, weekAllResets: String? = nil,
        weekOpusPctLeft: Int? = nil
    ) -> ClaudeOAuthRawUsageResponse {
        ClaudeOAuthRawUsageResponse(
            session5h: ClaudeOAuthRawUsageResponse.RawWindow(pctLeft: session5hPctLeft, resets: session5hResets),
            weekAllModels: ClaudeOAuthRawUsageResponse.RawWindow(pctLeft: weekAllPctLeft, resets: weekAllResets),
            weekOpus: weekOpusPctLeft.map { ClaudeOAuthRawUsageResponse.RawWindow(pctLeft: $0, resets: nil) }
        )
    }
}
