import XCTest
@testable import AgentSessions

/// The Compact/Full Cockpit retirement deletes nine settings keys and two
/// per-mode window-frame autosaves. These check the sweep removes exactly those
/// and nothing else — in particular that it leaves the live Quota Meter window
/// position alone.
final class DeprecatedCockpitDefaultsCleanupTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "DeprecatedCockpitDefaultsCleanupTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testRemovesEveryDeprecatedSettingsKey() {
        for key in DeprecatedCockpitDefaultsCleanup.removedKeys {
            defaults.set("stale", forKey: key)
        }

        DeprecatedCockpitDefaultsCleanup.run(defaults: defaults)

        for key in DeprecatedCockpitDefaultsCleanup.removedKeys {
            XCTAssertNil(defaults.object(forKey: key), "expected \(key) to be removed")
        }
    }

    func testRemovesRetiredPerModeWindowFrames() {
        for key in DeprecatedCockpitDefaultsCleanup.removedWindowFrameKeys {
            defaults.set("100 100 400 300 0 0 2560 1415 ", forKey: key)
        }

        DeprecatedCockpitDefaultsCleanup.run(defaults: defaults)

        for key in DeprecatedCockpitDefaultsCleanup.removedWindowFrameKeys {
            XCTAssertNil(defaults.object(forKey: key), "expected \(key) to be removed")
        }
    }

    /// The one window frame that must survive: it is where the user put the
    /// Quota Meter.
    func testKeepsLiveQuotaMeterWindowFrame() {
        let liveKey = "NSWindow Frame AgentCockpitHUDWindow.limits"
        defaults.set("2030 151 432 72 0 0 2560 1415 ", forKey: liveKey)

        DeprecatedCockpitDefaultsCleanup.run(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: liveKey), "2030 151 432 72 0 0 2560 1415 ")
    }

    func testKeepsRetainedCockpitSettings() {
        let retained = [
            "CockpitCodexActiveSessionsEnabled",
            "CockpitCodexActiveRegistryRootOverride",
            "CockpitHUDOpen",
            "CockpitHUDPinned",
            "CockpitHUDReduceTransparency",
            "CockpitShowProbeSessionsInHUD"
        ]
        for key in retained {
            defaults.set("keep", forKey: key)
        }

        DeprecatedCockpitDefaultsCleanup.run(defaults: defaults)

        for key in retained {
            XCTAssertEqual(defaults.string(forKey: key), "keep", "expected \(key) to survive")
        }
    }

    func testIsIdempotent() {
        defaults.set("stale", forKey: "CockpitHUDDisplayMode")

        DeprecatedCockpitDefaultsCleanup.run(defaults: defaults)
        DeprecatedCockpitDefaultsCleanup.run(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "CockpitHUDDisplayMode"))
    }
}
