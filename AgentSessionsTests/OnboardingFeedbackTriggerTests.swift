import XCTest
@testable import AgentSessions

final class OnboardingFeedbackTriggerTests: XCTestCase {
    private func makeDefaults(_ suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeCoordinator(
        defaults: UserDefaults,
        version: String = "4.3",
        now: @escaping () -> Date
    ) -> OnboardingCoordinator {
        OnboardingCoordinator(
            defaults: defaults,
            currentMajorMinorProvider: { version },
            isFreshInstallProvider: { false },
            whatsNewAvailableProvider: { _ in false },
            now: now
        )
    }

    func testNotDueBeforeTriggerThresholds() async {
        let defaults = makeDefaults("Feedback.notDue")
        let now = Date(timeIntervalSince1970: 2_000_000)
        defaults.onboardingFirstLaunchDate = now.addingTimeInterval(-5 * 86_400) // 5 days
        defaults.onboardingSessionsOpenedCount = 5

        let due = await MainActor.run { () -> Bool in
            makeCoordinator(defaults: defaults, now: { now }).isFeedbackAskDue()
        }
        XCTAssertFalse(due)
    }

    func testDueAtTenSessions() async {
        let defaults = makeDefaults("Feedback.tenSessions")
        let now = Date(timeIntervalSince1970: 2_000_000)
        defaults.onboardingFirstLaunchDate = now.addingTimeInterval(-1 * 86_400)
        defaults.onboardingSessionsOpenedCount = 10

        let due = await MainActor.run { () -> Bool in
            makeCoordinator(defaults: defaults, now: { now }).isFeedbackAskDue()
        }
        XCTAssertTrue(due)
    }

    func testDueAtFourteenDays() async {
        let defaults = makeDefaults("Feedback.fourteenDays")
        let now = Date(timeIntervalSince1970: 2_000_000)
        defaults.onboardingFirstLaunchDate = now.addingTimeInterval(-15 * 86_400)
        defaults.onboardingSessionsOpenedCount = 0

        let due = await MainActor.run { () -> Bool in
            makeCoordinator(defaults: defaults, now: { now }).isFeedbackAskDue()
        }
        XCTAssertTrue(due)
    }

    func testNeverDueOnFirstRunLaunch() async {
        let defaults = makeDefaults("Feedback.firstRun")
        let now = Date(timeIntervalSince1970: 2_000_000)
        defaults.onboardingSessionsOpenedCount = 25 // trigger easily met

        let due = await MainActor.run { () -> Bool in
            let coordinator = OnboardingCoordinator(
                defaults: defaults,
                currentMajorMinorProvider: { "4.3" },
                isFreshInstallProvider: { true },
                whatsNewAvailableProvider: { _ in false },
                now: { now }
            )
            // Fresh-install launch presents setup and marks the flag.
            coordinator.checkAndPresentIfNeeded()
            return coordinator.isFeedbackAskDue()
        }
        XCTAssertFalse(due, "Feedback must never appear during the first-run launch")
    }

    func testCompletedNeverDue() async {
        let defaults = makeDefaults("Feedback.completed")
        let now = Date(timeIntervalSince1970: 2_000_000)
        defaults.onboardingFirstLaunchDate = now.addingTimeInterval(-30 * 86_400)
        defaults.onboardingSessionsOpenedCount = 50
        defaults.onboardingFeedbackAskState = .completed

        let due = await MainActor.run { () -> Bool in
            makeCoordinator(defaults: defaults, now: { now }).isFeedbackAskDue()
        }
        XCTAssertFalse(due)
    }

    func testDeclinedOnceReAsksOnlyAfterBump() async {
        let defaults = makeDefaults("Feedback.reask")
        let now = Date(timeIntervalSince1970: 2_000_000)
        defaults.onboardingFirstLaunchDate = now.addingTimeInterval(-30 * 86_400)
        defaults.onboardingSessionsOpenedCount = 50

        // First "Not now" on 4.3.
        await MainActor.run {
            let coordinator = makeCoordinator(defaults: defaults, version: "4.3", now: { now })
            coordinator.recordFeedbackDeclined()
        }
        XCTAssertEqual(defaults.onboardingFeedbackAskState, .declinedOnce)
        XCTAssertEqual(defaults.onboardingFeedbackDeclinedAtMajorMinor, "4.3")

        // Same version: not due again.
        let dueSameVersion = await MainActor.run { () -> Bool in
            makeCoordinator(defaults: defaults, version: "4.3", now: { now }).isFeedbackAskDue()
        }
        XCTAssertFalse(dueSameVersion)

        // After a bump: due once more.
        let dueAfterBump = await MainActor.run { () -> Bool in
            makeCoordinator(defaults: defaults, version: "4.4", now: { now }).isFeedbackAskDue()
        }
        XCTAssertTrue(dueAfterBump)

        // Second "Not now": dismissed forever.
        await MainActor.run {
            makeCoordinator(defaults: defaults, version: "4.4", now: { now }).recordFeedbackDeclined()
        }
        XCTAssertEqual(defaults.onboardingFeedbackAskState, .dismissedForever)

        let dueAfterSecondDecline = await MainActor.run { () -> Bool in
            makeCoordinator(defaults: defaults, version: "4.5", now: { now }).isFeedbackAskDue()
        }
        XCTAssertFalse(dueAfterSecondDecline)
    }

    func testNoteSessionOpenedIncrementsCounter() async {
        let defaults = makeDefaults("Feedback.counter")
        let now = Date(timeIntervalSince1970: 2_000_000)

        await MainActor.run {
            let coordinator = makeCoordinator(defaults: defaults, now: { now })
            coordinator.noteSessionOpened()
            coordinator.noteSessionOpened()
            coordinator.noteSessionOpened()
        }
        XCTAssertEqual(defaults.onboardingSessionsOpenedCount, 3)
    }
}

final class WhatsNewCatalogTests: XCTestCase {
    func testAssembleForCurrentReleaseHasHighlights() {
        let items = WhatsNewCatalog.assemble(for: "4.3")
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.contains { $0.kind == .highlight })
        // At most one promo, always.
        XCTAssertLessThanOrEqual(items.filter { $0.kind == .promo }.count, 1)
    }

    func testProviderItemsAppendedAfterAuthoredHighlights() {
        // Cursor was introduced in 3.2 (no authored bundle for 3.2).
        let items = WhatsNewCatalog.assemble(for: "3.2")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .highlight)
        XCTAssertEqual(items.first?.title, "New: Cursor")
    }

    func testEmptyVersionHasNoContent() {
        XCTAssertTrue(WhatsNewCatalog.assemble(for: "99.9").isEmpty)
        XCTAssertFalse(WhatsNewCatalog.hasContent(for: "99.9"))
    }

    func testHasContentForCurrentRelease() {
        XCTAssertTrue(WhatsNewCatalog.hasContent(for: "4.3"))
    }

    func testTeaserPresentForCurrentRelease() {
        XCTAssertNotNil(WhatsNewCatalog.teaser(for: "4.3"))
        XCTAssertNil(WhatsNewCatalog.teaser(for: "99.9"))
    }
}
