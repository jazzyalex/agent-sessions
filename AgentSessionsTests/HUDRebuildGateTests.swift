import XCTest
@testable import AgentSessions

final class HUDRebuildGateTests: XCTestCase {

    private func inputs(membership: UInt64 = 1, badge: UInt64 = 1,
                        sessions: UInt64 = 1, compact: Bool = false,
                        probes: Bool = false, skipPreamble: Bool = true) -> HUDRebuildGate.Inputs {
        HUDRebuildGate.Inputs(membershipVersion: membership, badgeVersion: badge,
                              sessionsGeneration: sessions, isCompact: compact,
                              showProbes: probes, skipAgentsPreamble: skipPreamble)
    }

    func testFirstCallAlwaysRebuilds() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100)))
    }

    func testUnchangedInputsWithinIntervalSkip() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 102)))
        XCTAssertFalse(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 104)))
    }

    func testUnchangedInputsRebuildAfterStaleInterval() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 105.1)),
                      "age-based active/idle reclassification needs a periodic recompute")
    }

    func testAnyInputChangeRebuildsImmediately() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(membership: 2), now: Date(timeIntervalSince1970: 100.5)))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(membership: 2, badge: 2), now: Date(timeIntervalSince1970: 100.6)))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(membership: 2, badge: 2, sessions: 2), now: Date(timeIntervalSince1970: 100.7)))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(membership: 2, badge: 2, sessions: 2, compact: true), now: Date(timeIntervalSince1970: 100.8)))
    }

    func testForceNextRebuildResetsTheGate() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100))
        gate.forceNextRebuild()
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100.5)))
    }

    /// C3: rendered row titles read `SkipAgentsPreamble` directly
    /// (`Session.title`), so flipping the preference must trigger an
    /// immediate rebuild instead of waiting up to `staleReclassifyInterval`
    /// for the next age-based reclassify.
    func testSkipAgentsPreambleChangeRebuildsImmediately() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(skipPreamble: true), now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(gate.shouldRebuild(inputs: inputs(skipPreamble: true), now: Date(timeIntervalSince1970: 100.5)),
                       "sanity: unchanged inputs within the interval should still skip")
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(skipPreamble: false), now: Date(timeIntervalSince1970: 100.6)),
                      "SkipAgentsPreamble flip must rebuild immediately, not wait for the stale-reclassify interval")
    }
}
