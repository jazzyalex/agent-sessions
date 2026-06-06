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
