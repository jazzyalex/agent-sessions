import XCTest
import Combine
@testable import AgentSessions

/// W6 Task 2: `CodexActiveSessionsModel` migrated `ObservableObject`/`@Published`
/// to `@Observable` + three explicit Combine bridge subjects
/// (`membershipTicks`/`badgeTicks`/`presenceUpdates`). The view-wiring surface
/// (property-wrapper swaps, `.onReceive` sites) isn't unit-testable, but the
/// one piece of real logic this migration touches — `apply(_:)` deciding
/// when to reassign each Observation-tracked property AND fire the matching
/// subject — is: these tests pin that behavior directly via the `#if DEBUG`
/// `debugApply(_:)` hook (mirrors `debugRunManagedCommand`'s existing pattern),
/// bypassing the real `PresenceEngine` entirely so no poll loop needs to run.
@MainActor
final class CodexActiveSessionsModelObservationTests: XCTestCase {

    private func makePresence(id: String) -> CodexActivePresence {
        var presence = CodexActivePresence()
        presence.sessionId = id
        presence.source = .codex
        presence.lastSeenAt = Date()
        return presence
    }

    private func makeSnapshot(presences: [CodexActivePresence] = [],
                               membershipVersion: UInt64,
                               badgeVersion: UInt64) -> PresenceSnapshot {
        var snapshot = PresenceSnapshot.empty
        snapshot.presences = presences
        snapshot.membershipVersion = membershipVersion
        snapshot.badgeVersion = badgeVersion
        return snapshot
    }

    // MARK: - Membership change fires presenceUpdates + membershipTicks together

    func testApply_membershipChange_updatesPropertiesAndFiresBothSubjectsWithMatchingValues() {
        let model = CodexActiveSessionsModel()
        var receivedPresenceUpdates: [[CodexActivePresence]] = []
        var receivedMembershipTicks: [UInt64] = []
        var receivedBadgeTicks: [UInt64] = []
        var cancellables: Set<AnyCancellable> = []
        model.presenceUpdates.sink { receivedPresenceUpdates.append($0) }.store(in: &cancellables)
        model.membershipTicks.sink { receivedMembershipTicks.append($0) }.store(in: &cancellables)
        model.badgeTicks.sink { receivedBadgeTicks.append($0) }.store(in: &cancellables)

        let presence = makePresence(id: "abc")
        let emission = PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [presence], membershipVersion: 1, badgeVersion: 0),
            isMembershipChange: true
        )
        model.debugApply(emission)

        XCTAssertEqual(model.activeMembershipVersion, 1)
        XCTAssertEqual(model.presences.map(\.sessionId), [presence.sessionId])
        XCTAssertEqual(model.subagentBadgeVersion, 0, "badge version must not move when the emission's badgeVersion is unchanged from the prior snapshot (0 -> 0)")

        XCTAssertEqual(receivedMembershipTicks, [1], "membershipTicks fires exactly once, with the new version")
        XCTAssertEqual(receivedPresenceUpdates.count, 1, "presenceUpdates fires exactly once")
        XCTAssertEqual(receivedPresenceUpdates.first?.map(\.sessionId), [presence.sessionId])
        XCTAssertTrue(receivedBadgeTicks.isEmpty, "badgeTicks must not fire when badgeVersion did not change")
    }

    // MARK: - Badge-only change fires badgeTicks alone, leaves presences/membership untouched

    func testApply_badgeOnlyChange_firesOnlyBadgeTicks_leavesPresencesAndMembershipUntouched() {
        let model = CodexActiveSessionsModel()
        // Seed a first, real membership change so there is a non-empty prior
        // state to prove badge-only emissions don't disturb it.
        let seedPresence = makePresence(id: "seed")
        model.debugApply(PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [seedPresence], membershipVersion: 1, badgeVersion: 0),
            isMembershipChange: true
        ))
        XCTAssertEqual(model.activeMembershipVersion, 1)

        var receivedPresenceUpdates: [[CodexActivePresence]] = []
        var receivedMembershipTicks: [UInt64] = []
        var receivedBadgeTicks: [UInt64] = []
        var cancellables: Set<AnyCancellable> = []
        model.presenceUpdates.sink { receivedPresenceUpdates.append($0) }.store(in: &cancellables)
        model.membershipTicks.sink { receivedMembershipTicks.append($0) }.store(in: &cancellables)
        model.badgeTicks.sink { receivedBadgeTicks.append($0) }.store(in: &cancellables)

        // A badge-only emission: membershipVersion unchanged (still 1),
        // badgeVersion bumps 0 -> 1. `presences` in the snapshot is left as
        // whatever the engine last computed (mirrors the real engine, which
        // only reassigns `nextSnapshot.presences` inside the
        // `didPublishPresences` branch — a pure-badge publish never touches it).
        let badgeEmission = PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [seedPresence], membershipVersion: 1, badgeVersion: 1),
            isMembershipChange: true // badge changes are tagged isMembershipChange in the real engine too (see PresenceEngine.swift didPublishBadge); irrelevant to apply()'s branching, which keys off the two version numbers, not this flag
        )
        model.debugApply(badgeEmission)

        XCTAssertEqual(model.subagentBadgeVersion, 1)
        XCTAssertEqual(model.activeMembershipVersion, 1, "membership version must not move on a badge-only change")

        XCTAssertEqual(receivedBadgeTicks, [1], "badgeTicks fires exactly once with the new badge version")
        XCTAssertTrue(receivedMembershipTicks.isEmpty, "membershipTicks must not fire when membershipVersion did not change")
        XCTAssertTrue(receivedPresenceUpdates.isEmpty, "presenceUpdates must not fire when membershipVersion did not change (mirrors the pre-Observable @Published assignment, which was likewise gated on the same membershipVersion check)")
    }

    // MARK: - No-op emission (both versions unchanged) fires nothing

    func testApply_noVersionChange_firesNoSubjectsAndLeavesPropertiesUnchanged() {
        let model = CodexActiveSessionsModel()
        let presence = makePresence(id: "steady")
        model.debugApply(PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [presence], membershipVersion: 1, badgeVersion: 1),
            isMembershipChange: true
        ))

        var firedAnything = false
        var cancellables: Set<AnyCancellable> = []
        model.presenceUpdates.sink { _ in firedAnything = true }.store(in: &cancellables)
        model.membershipTicks.sink { _ in firedAnything = true }.store(in: &cancellables)
        model.badgeTicks.sink { _ in firedAnything = true }.store(in: &cancellables)

        // Identical versions to the already-applied snapshot: the engine
        // would not have emitted this at all in practice (its own
        // steady-state dedup), but `apply(_:)` itself must independently be
        // a no-op here too, defense-in-depth-style.
        model.debugApply(PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [presence], membershipVersion: 1, badgeVersion: 1),
            isMembershipChange: false
        ))

        XCTAssertFalse(firedAnything, "no subject should fire when neither version number changed")
        XCTAssertEqual(model.activeMembershipVersion, 1)
        XCTAssertEqual(model.subagentBadgeVersion, 1)
    }

    // MARK: - lastRefreshAt still updates on every apply (unrelated to Observation, parity check)

    func testApply_alwaysUpdatesLastRefreshAt_evenWhenNoSubjectFires() {
        let model = CodexActiveSessionsModel()
        model.debugApply(PresenceEngine.Emission(
            snapshot: makeSnapshot(membershipVersion: 0, badgeVersion: 0),
            isMembershipChange: false
        ))
        XCTAssertNotNil(model.lastRefreshAt)
    }
}
