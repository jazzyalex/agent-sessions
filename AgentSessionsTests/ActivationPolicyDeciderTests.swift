import AppKit
import XCTest
@testable import AgentSessions

final class ActivationPolicyDeciderTests: XCTestCase {
    func testDockActivationPolicySafety() {
        XCTAssertEqual(
            ActivationPolicyDecider.policy(hideDockIcon: true, menuBarEnabled: true),
            .accessory
        )
        XCTAssertEqual(
            ActivationPolicyDecider.policy(hideDockIcon: true, menuBarEnabled: false),
            .regular
        )
        XCTAssertEqual(
            ActivationPolicyDecider.policy(hideDockIcon: false, menuBarEnabled: true),
            .regular
        )
    }

    func testAppBundleLaunchesAsUIElementCapableApp() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }

    func testDockIconPreferenceToggleEnablesMenuBarBeforeHidingDockIcon() {
        let defaults = UserDefaults(suiteName: "DockIconPreferenceControllerTests")!
        defaults.removePersistentDomain(forName: "DockIconPreferenceControllerTests")

        XCTAssertEqual(DockIconPreferenceController.dockIconMenuTitle(defaults: defaults), "Hide Dock Icon")

        let hidden = DockIconPreferenceController.toggleDockIconHidden(defaults: defaults)

        XCTAssertTrue(hidden)
        XCTAssertTrue(defaults.bool(forKey: PreferencesKey.menuBarEnabled))
        XCTAssertTrue(defaults.bool(forKey: PreferencesKey.Advanced.hideDockIcon))
        XCTAssertEqual(DockIconPreferenceController.dockIconMenuTitle(defaults: defaults), "Show Dock Icon")
    }

    func testDisablingMenuBarClearsHiddenDockPreference() {
        let defaults = UserDefaults(suiteName: "DockIconPreferenceControllerMenuBarTests")!
        defaults.removePersistentDomain(forName: "DockIconPreferenceControllerMenuBarTests")
        DockIconPreferenceController.setDockIconHidden(true, defaults: defaults)

        DockIconPreferenceController.setMenuBarEnabled(false, defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: PreferencesKey.menuBarEnabled))
        XCTAssertFalse(defaults.bool(forKey: PreferencesKey.Advanced.hideDockIcon))
        XCTAssertEqual(DockIconPreferenceController.dockIconMenuTitle(defaults: defaults), "Hide Dock Icon")
    }

    func testReachabilityReconcileRestoresDockPathWithoutReenablingMenuBar() {
        let defaults = UserDefaults(suiteName: "DockIconPreferenceControllerReconcileTests")!
        defaults.removePersistentDomain(forName: "DockIconPreferenceControllerReconcileTests")
        defaults.set(false, forKey: PreferencesKey.menuBarEnabled)
        defaults.set(true, forKey: PreferencesKey.Advanced.hideDockIcon)

        DockIconPreferenceController.reconcileReachability(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: PreferencesKey.menuBarEnabled))
        XCTAssertFalse(defaults.bool(forKey: PreferencesKey.Advanced.hideDockIcon))
    }

    @MainActor
    func testDockMenuAlwaysOffersHideDockIcon() {
        let delegate = AgentSessionsApplicationDelegate()
        let menu = delegate.applicationDockMenu(NSApplication.shared)

        XCTAssertEqual(menu?.items.first?.title, "Hide Dock Icon")
    }

    func testDockRecentAppCleanerRemovesOnlyAgentSessionsEntries() {
        let currentApp: [String: Any] = [
            "tile-data": [
                "bundle-identifier": "com.triada.AgentSessions",
                "file-label": "Agent Sessions"
            ]
        ]
        let currentAppByURL: [String: Any] = [
            "tile-data": [
                "file-label": "Agent Sessions",
                "file-data": [
                    "_CFURLString": "file:///Applications/Agent%20Sessions.app/"
                ]
            ]
        ]
        let otherApp: [String: Any] = [
            "tile-data": [
                "bundle-identifier": "com.apple.Safari",
                "file-label": "Safari"
            ]
        ]

        let cleaned = DockRecentAppCleaner.removingApp(
            from: [otherApp, currentApp, currentAppByURL],
            bundleIdentifier: "com.triada.AgentSessions",
            bundleURL: URL(string: "file:///Applications/Agent%20Sessions.app/")!
        )

        XCTAssertEqual(cleaned.count, 1)
        let tileData = (cleaned[0] as? [String: Any])?["tile-data"] as? [String: Any]
        XCTAssertEqual(tileData?["bundle-identifier"] as? String, "com.apple.Safari")
    }
}
