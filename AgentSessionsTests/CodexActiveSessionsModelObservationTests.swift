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

    // MARK: - Tracking-width guard (W6 Task 3)

    // Mechanically pins the "3 tracked / everything else @ObservationIgnored"
    // census from the Task 2 report's "Fix: tracking width" section: reading
    // a sync-lookup method (`presence(for:)` / `liveState(for:)`, both backed
    // solely by `latestSnapshot`, an `@ObservationIgnored` property) must NOT
    // register a tracked-property access — a table row that only calls these
    // lookups must not re-render on every poll tick — while reading the
    // `presences` array directly (the views' actual data source, e.g.
    // `CockpitView.makeLiveRowsSnapshot()`) MUST register one, and that
    // registration must actually fire when `apply(_:)` changes membership.
    // `withObservationTracking(_:onChange:)` is the framework-provided way to
    // assert this deterministically and synchronously — it does not need the
    // real actor-fed async stream; `debugApply(_:)` (the same test hook the
    // tests above use) stands in for "an emission arrived," which is the
    // narrowest realistic substitute for driving `apply(_:)` without running
    // the live poll loop. This IS the direct `withObservationTracking` test,
    // not an approximation — the limitation is only that it exercises
    // `apply(_:)` via the debug hook rather than a live `PresenceEngine`
    // stream, which the 4 tests above already establish is behaviorally
    // identical (same private `apply(_:)` call, same call site).

    func testTrackingWidth_syncLookupsDoNotRegisterObservationDependency() {
        let model = CodexActiveSessionsModel()
        let presence = makePresence(id: "lookup-target")
        model.debugApply(PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [presence], membershipVersion: 1, badgeVersion: 0),
            isMembershipChange: true
        ))

        var invalidated = false
        withObservationTracking {
            // Both are `CodexActivePresence`-keyed facade sync-lookup methods
            // views call from body-reachable sites (`liveState(for:)` —
            // CockpitView:167, AgentCockpitHUDView:1996/2008/2222,
            // UnifiedSessionsView:2654; `idleReason(for:)` —
            // AgentCockpitHUDView:2223, per the W6 recon census). Both
            // resolve entirely through `latestSnapshot`, which the Task 2
            // "Fix: tracking width" pass marked `@ObservationIgnored`.
            _ = model.liveState(for: presence)
            _ = model.idleReason(for: presence)
        } onChange: {
            invalidated = true
        }

        // Mutate state the lookups actually read (latestSnapshot, via a real
        // membership-changing apply) and give Observation a chance to fire
        // its callback if (and only if) a dependency was registered above.
        model.debugApply(PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [], membershipVersion: 2, badgeVersion: 0),
            isMembershipChange: true
        ))

        XCTAssertFalse(invalidated, "liveState(for:)/idleReason(for:) read only @ObservationIgnored state (latestSnapshot) and must not register a tracked-property dependency — a view calling only these lookups must not re-render on every poll tick")
    }

    func testTrackingWidth_presencesReadRegistersAndFiresOnMembershipChange() {
        let model = CodexActiveSessionsModel()
        let seed = makePresence(id: "seed")
        model.debugApply(PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [seed], membershipVersion: 1, badgeVersion: 0),
            isMembershipChange: true
        ))

        var invalidated = false
        withObservationTracking {
            // `CockpitView.makeLiveRowsSnapshot()`'s legitimate data source —
            // the property this migration deliberately keeps tracked so
            // views that render the list itself still update.
            _ = model.presences
        } onChange: {
            invalidated = true
        }

        let next = makePresence(id: "joined")
        model.debugApply(PresenceEngine.Emission(
            snapshot: makeSnapshot(presences: [seed, next], membershipVersion: 2, badgeVersion: 0),
            isMembershipChange: true
        ))

        XCTAssertTrue(invalidated, "presences is one of the 3 intentionally Observation-tracked properties — a view reading it directly must be invalidated when apply(_:) changes it")
    }
}
