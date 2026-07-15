import XCTest
@testable import AgentSessions

/// The Quota Meter card's audience test and ask lifecycle. The card enables CLI
/// usage probes and puts a pinned window on screen, so showing it to the wrong
/// person — or twice after they said no — is not a cosmetic mistake.
final class OnboardingQuotaMeterCardTests: XCTestCase {
    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeCoordinator(defaults: UserDefaults, version: String = "4.3") -> OnboardingCoordinator {
        OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { version },
            isFreshInstallProvider: { false },
            whatsNewAvailableProvider: { _ in false },
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )
    }

    @MainActor
    private func shows(
        _ coordinator: OnboardingCoordinator,
        hasSessions: Bool = true,
        isActive: Bool = false
    ) -> Bool {
        coordinator.shouldShowQuotaMeterCard(
            hasCodexOrClaudeSessions: hasSessions,
            isQuotaMeterActive: isActive
        )
    }

    // MARK: - Audience

    @MainActor
    func testShownToUserWithCodexOrClaudeSessionsWhoIsNotUsingIt() {
        let coordinator = makeCoordinator(defaults: makeDefaults("QM.eligible"))
        XCTAssertTrue(shows(coordinator))
    }

    /// The Quota Meter reports Codex and Claude quota only — to anyone else the
    /// card advertises a feature that would render empty.
    @MainActor
    func testNeverShownWithoutCodexOrClaudeSessions() {
        let coordinator = makeCoordinator(defaults: makeDefaults("QM.noSessions"))
        XCTAssertFalse(shows(coordinator, hasSessions: false))
    }

    @MainActor
    func testNotShownToSomeoneAlreadyUsingIt() {
        let coordinator = makeCoordinator(defaults: makeDefaults("QM.active"))
        XCTAssertFalse(shows(coordinator, isActive: true))
    }

    // MARK: - Slot priority

    /// What's New owns the slot when both are due.
    @MainActor
    func testWhatsNewWinsTheSlot() {
        let coordinator = makeCoordinator(defaults: makeDefaults("QM.whatsNew"))
        coordinator.whatsNewMajorMinor = "4.3"
        XCTAssertFalse(shows(coordinator))
    }

    // MARK: - Lifecycle

    @MainActor
    func testDismissCostsAStrikeAndHidesForTheLaunch() {
        let defaults = makeDefaults("QM.dismissOnce")
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.suppressQuotaMeterCardThisLaunch()

        XCTAssertEqual(defaults.onboardingQuotaMeterAskState, .dismissedOnce)
        XCTAssertEqual(defaults.onboardingQuotaMeterDeclinedAtMajorMinor, "4.3")
        XCTAssertFalse(shows(coordinator))
    }

    /// Dismissed once: silent on the same version, one more try after a bump.
    @MainActor
    func testReAsksOnlyAfterAVersionBump() {
        let defaults = makeDefaults("QM.bump")
        defaults.onboardingQuotaMeterAskState = .dismissedOnce
        defaults.onboardingQuotaMeterDeclinedAtMajorMinor = "4.3"

        XCTAssertFalse(shows(makeCoordinator(defaults: defaults, version: "4.3")))
        XCTAssertTrue(shows(makeCoordinator(defaults: defaults, version: "4.4")))
    }

    @MainActor
    func testSecondDismissSilencesForever() {
        let defaults = makeDefaults("QM.forever")
        defaults.onboardingQuotaMeterAskState = .dismissedOnce
        defaults.onboardingQuotaMeterDeclinedAtMajorMinor = "4.3"

        let coordinator = makeCoordinator(defaults: defaults, version: "4.4")
        coordinator.recordQuotaMeterDeclined()

        XCTAssertEqual(defaults.onboardingQuotaMeterAskState, .dismissedForever)
        XCTAssertFalse(shows(coordinator))
        // Not even a later version brings it back.
        XCTAssertFalse(shows(makeCoordinator(defaults: defaults, version: "5.0")))
    }

    @MainActor
    func testActivatingSilencesForever() {
        let defaults = makeDefaults("QM.activated")
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.recordQuotaMeterActivated()

        XCTAssertEqual(defaults.onboardingQuotaMeterAskState, .activated)
        XCTAssertFalse(shows(coordinator))
        XCTAssertFalse(shows(makeCoordinator(defaults: defaults, version: "5.0")))
    }

    // MARK: - Cockpit-opened tracking

    /// Usage tracking on is not the same as having seen the window; this flag is
    /// what separates the "never opened it" audience from actual users.
    @MainActor
    func testNoteCockpitOpenedIsSticky() {
        let defaults = makeDefaults("QM.opened")
        let coordinator = makeCoordinator(defaults: defaults)

        XCTAssertFalse(coordinator.hasEverOpenedCockpit)
        coordinator.noteCockpitOpened()
        XCTAssertTrue(coordinator.hasEverOpenedCockpit)
        XCTAssertTrue(defaults.onboardingCockpitEverOpened)
    }
}
