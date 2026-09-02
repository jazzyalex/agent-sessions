import AppKit
import XCTest
@testable import AgentSessions

final class LocalizationFoundationTests: XCTestCase {
    func testOnboardingDynamicLabelsRetainLocalizedResources() {
        let next: LocalizedStringResource = OnboardingSheetView.primaryActionTitle(isLast: false)
        let done: LocalizedStringResource = OnboardingSheetView.primaryActionTitle(isLast: true)
        let sessions: LocalizedStringResource = FirstRunSetupView.sessionsSectionTitle
        let quota: LocalizedStringResource = FirstRunSetupView.quotaMeterSectionTitle

        XCTAssertEqual(String(localized: next), "Next")
        XCTAssertEqual(String(localized: done), "Done")
        XCTAssertEqual(String(localized: sessions), "Your sessions")
        XCTAssertEqual(String(localized: quota), "Quota Meter")
    }

    func testSessionCountUsesOnePluralizedLocalizationUnit() {
        let locale = Locale(identifier: "en")
        XCTAssertEqual(
            String(localized: OnboardingLocalizedCopy.sessionsFound(0, locale: locale)),
            "0 sessions found"
        )
        XCTAssertEqual(
            String(localized: OnboardingLocalizedCopy.sessionsFound(1, locale: locale)),
            "1 session found"
        )
        XCTAssertEqual(
            String(localized: OnboardingLocalizedCopy.sessionsFound(2, locale: locale)),
            "2 sessions found"
        )
    }

    func testMainWindowSceneIdentityPreservesPreLocalizationRoutingIdentifier() {
        XCTAssertEqual(AppWindowRouter.mainWindowSceneIdentifier, "Agent Sessions")
        XCTAssertEqual(AppWindowRouter.mainWindowIdentifier, "AgentSessionsMainWindow")
        XCTAssertNotEqual(
            AppWindowRouter.mainWindowSceneIdentifier,
            AppWindowRouter.mainWindowIdentifier
        )
    }

    func testPowerTipsUseStableIdentitySeparateFromLocalizedCopy() {
        let tour = OnboardingContent.powerTipsTour(for: "5.1")
        let expectedScreenIDs = [
            "power-tips",
            "cockpit-workflow",
            "live-session-context",
            "search-faster",
            "resume-work",
            "images",
            "transcript-tools",
            "reading-controls",
            "saved-sessions",
            "reduce-noise",
            "usage-limits",
            "agent-sources",
            "side-chats",
            "archived-sessions",
            "workflow-subagents",
            "quick-navigation"
        ]

        XCTAssertEqual(tour.screens.map(\.id), expectedScreenIDs)
        XCTAssertEqual(Set(tour.screens.map(\.id)).count, tour.screens.count)
        XCTAssertTrue(tour.screens.allSatisfy { screen in
            screen.id != String(localized: screen.title)
        })
        XCTAssertTrue(tour.screens.allSatisfy { screen in
            let tipIDs = screen.bullets.map(\.id)
            return Set(tipIDs).count == tipIDs.count
                && screen.bullets.allSatisfy { tip in
                    tip.id != String(localized: tip.title)
                }
        })

        let punctuationTip = OnboardingContent.Screen.Tip(
            id: "punctuation-test",
            title: "Keyboard: navigation",
            description: "Keep punctuation: it belongs to the localized copy."
        )
        XCTAssertEqual(String(localized: punctuationTip.title), "Keyboard: navigation")
        XCTAssertEqual(
            String(localized: punctuationTip.description),
            "Keep punctuation: it belongs to the localized copy."
        )
    }

    func testSharedFeatureRowKeepsLegacyCopyVerbatim() {
        let palette = OnboardingPalette(colorScheme: .light)
        let staticRow = FeatureRow(
            palette: palette,
            icon: "info.circle",
            iconColor: .blue,
            title: "Static title",
            description: "Static description"
        )
        if case .localized = staticRow.title {
            // Expected: string literals use the localized initializer.
        } else {
            XCTFail("localized FeatureRow initializer should retain a localization resource")
        }

        let legacyTitle = "Runtime title \(UUID().uuidString)"
        let legacyRow = FeatureRow(
            palette: palette,
            icon: "info.circle",
            iconColor: .blue,
            verbatimTitle: legacyTitle,
            verbatimDescription: "Runtime description"
        )
        guard case .verbatim(let retainedTitle) = legacyRow.title else {
            return XCTFail("legacy What's New copy must not be manufactured into a localization key")
        }
        XCTAssertEqual(retainedTitle, legacyTitle)
    }

    @MainActor
    func testMainWindowRoutingUsesStableIdentifierNotTitle() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "会话"
        window.contentView = WindowIdentifierView(
            identifier: AppWindowRouter.mainWindowIdentifier
        )

        XCTAssertEqual(window.identifier?.rawValue, AppWindowRouter.mainWindowIdentifier)
        XCTAssertTrue(AppWindowRouter.isAgentSessionsWindow(window))

        window.title = "Agent Sessions"
        window.identifier = NSUserInterfaceItemIdentifier("A different window")
        XCTAssertFalse(AppWindowRouter.isAgentSessionsWindow(window))
    }

    func testUsageNotificationBodyRemainsOneLocalizedUnit() {
        let event = UsageLimitAlertEvent(
            provider: .codex,
            kind: .approaching,
            window: .fiveHour,
            remainingPercent: 8,
            resetDate: nil,
            identifier: "localization-test",
            projectedSecondsUntilEmpty: 6 * 60
        )

        XCTAssertEqual(event.title, "Codex 5h usage is low")
        XCTAssertEqual(event.body, "8% remaining, burning to empty in about 6 min.")

        let weeklyEvent = UsageLimitAlertEvent(
            provider: .claude,
            kind: .approaching,
            window: .weekly,
            remainingPercent: 8,
            resetDate: nil,
            identifier: "localization-weekly-test"
        )
        XCTAssertEqual(weeklyEvent.title, "Claude weekly usage is low")
        XCTAssertEqual(weeklyEvent.body, "8% remaining, for the weekly limit.")
    }

    func testUsageNotificationDurationsUseLocaleAwareUnits() {
        let english = Locale(identifier: "en_US")
        let simplifiedChinese = Locale(identifier: "zh-Hans")

        XCTAssertEqual(UsageLimitAlertEvent.formatDuration(6 * 60, locale: english), "6 min")
        XCTAssertEqual(UsageLimitAlertEvent.formatDuration(27 * 60 * 60, locale: english), "1 day, 3 hr")
        XCTAssertEqual(UsageLimitAlertEvent.formatDuration(6 * 60, locale: simplifiedChinese), "6分钟")
        XCTAssertEqual(UsageLimitAlertEvent.formatDuration(27 * 60 * 60, locale: simplifiedChinese), "1天3小时")
    }
}
