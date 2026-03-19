import XCTest
@testable import AgentSessions

final class ClaudeWebUsageNormalizerTests: XCTestCase {

    // MARK: - Valid payloads

    func testNormalize_validPayload_producesCorrectRatios() {
        let raw = makeResponse(fiveHourUtil: 42.0, sevenDayUtil: 22.0)
        let snap = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: "abc")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.42, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 0.22, accuracy: 0.001)
        XCTAssertEqual(snap.source, .webEndpoint)
        XCTAssertEqual(snap.health, .live)
        XCTAssertEqual(snap.rawPayloadHash, "abc")
    }

    func testNormalize_zeroUsed() {
        let raw = makeResponse(fiveHourUtil: 0.0, sevenDayUtil: 0.0)
        let snap = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.0, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 0.0, accuracy: 0.001)
        XCTAssertEqual(snap.fiveHourRemainingPercent, 100)
        XCTAssertEqual(snap.weeklyRemainingPercent, 100)
    }

    func testNormalize_fullyUsed() {
        let raw = makeResponse(fiveHourUtil: 100.0, sevenDayUtil: 100.0)
        let snap = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: "")!

        XCTAssertEqual(snap.fiveHourUsedRatio!, 1.0, accuracy: 0.001)
        XCTAssertEqual(snap.weeklyUsedRatio!, 1.0, accuracy: 0.001)
    }

    // MARK: - Ratio clamping

    func testNormalize_utilizationAbove100_clampedToOne() {
        let raw = makeResponse(fiveHourUtil: 150.0, sevenDayUtil: 50.0)
        let snap = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertEqual(snap.fiveHourUsedRatio!, 1.0, accuracy: 0.001)
    }

    func testNormalize_utilizationNegative_clampedToZero() {
        let raw = makeResponse(fiveHourUtil: -5.0, sevenDayUtil: 50.0)
        let snap = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertEqual(snap.fiveHourUsedRatio!, 0.0, accuracy: 0.001)
    }

    // MARK: - Missing sections

    func testNormalize_bothWindowsMissing_returnsNil() {
        let raw = ClaudeWebRawUsageResponse(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil)
        XCTAssertNil(ClaudeWebUsageNormalizer.normalize(raw, bodyHash: ""))
    }

    func testNormalize_missingFiveHour_returnsNilFiveHourRatio() {
        let raw = ClaudeWebRawUsageResponse(
            fiveHour: nil,
            sevenDay: ClaudeWebRawUsageResponse.RawWindow(utilization: 50, resetsAt: nil),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
        let snap = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertNil(snap.fiveHourUsedRatio)
        XCTAssertNotNil(snap.weeklyUsedRatio)
    }

    // MARK: - Source

    func testNormalize_sourceIsWebEndpoint() {
        let raw = makeResponse(fiveHourUtil: 50, sevenDayUtil: 50)
        let snap = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertEqual(snap.source, .webEndpoint)
    }

    // MARK: - Reset text passthrough

    func testNormalize_resetsAtPassedThrough() {
        let raw = makeResponse(
            fiveHourUtil: 50, fiveHourResets: "2026-03-14T09:00:00Z",
            sevenDayUtil: 50, sevenDayResets: "2026-03-19T20:00:00Z"
        )
        let snap = ClaudeWebUsageNormalizer.normalize(raw, bodyHash: "")!
        XCTAssertEqual(snap.fiveHourResetText, "2026-03-14T09:00:00Z")
        XCTAssertEqual(snap.weeklyResetText, "2026-03-19T20:00:00Z")
    }

    // MARK: - Helpers

    private func makeResponse(
        fiveHourUtil: Double = 50, fiveHourResets: String? = nil,
        sevenDayUtil: Double = 50, sevenDayResets: String? = nil
    ) -> ClaudeWebRawUsageResponse {
        ClaudeWebRawUsageResponse(
            fiveHour: ClaudeWebRawUsageResponse.RawWindow(utilization: fiveHourUtil, resetsAt: fiveHourResets),
            sevenDay: ClaudeWebRawUsageResponse.RawWindow(utilization: sevenDayUtil, resetsAt: sevenDayResets),
            sevenDayOpus: nil,
            sevenDaySonnet: nil
        )
    }
}
