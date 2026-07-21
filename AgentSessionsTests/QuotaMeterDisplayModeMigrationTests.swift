import XCTest
@testable import AgentSessions

/// Full and Compact Agent Cockpit are retired; the Quota Meter is the only mode.
///
/// These lock in the migration contract: no persisted state — a stored mode
/// string, the legacy `hudCompact` Bool, a garbage value, or nothing at all —
/// can resolve to a mode that no longer renders. A user who last quit in Full or
/// Compact must land on the Quota Meter.
///
/// If `initialMode` is ever changed to read defaults again, these fail.
final class QuotaMeterDisplayModeMigrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "QuotaMeterDisplayModeMigrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testStoredFullModeResolvesToQuotaMeter() {
        defaults.set("full", forKey: PreferencesKey.Cockpit.hudDisplayMode)
        XCTAssertEqual(AgentCockpitHUDDisplayMode.initialMode(defaults: defaults), .limits)
    }

    func testStoredCompactModeResolvesToQuotaMeter() {
        defaults.set("compact", forKey: PreferencesKey.Cockpit.hudDisplayMode)
        XCTAssertEqual(AgentCockpitHUDDisplayMode.initialMode(defaults: defaults), .limits)
    }

    func testStoredLimitsModeStaysQuotaMeter() {
        defaults.set("limits", forKey: PreferencesKey.Cockpit.hudDisplayMode)
        XCTAssertEqual(AgentCockpitHUDDisplayMode.initialMode(defaults: defaults), .limits)
    }

    /// The pre-mode-enum representation: a Bool that meant "compact chrome".
    func testLegacyCompactTrueResolvesToQuotaMeter() {
        defaults.set(true, forKey: PreferencesKey.Cockpit.hudCompact)
        XCTAssertEqual(AgentCockpitHUDDisplayMode.initialMode(defaults: defaults), .limits)
    }

    /// The legacy false case used to mean Full — the mode most at risk of
    /// resurrecting, since it was the old default.
    func testLegacyCompactFalseResolvesToQuotaMeter() {
        defaults.set(false, forKey: PreferencesKey.Cockpit.hudCompact)
        XCTAssertEqual(AgentCockpitHUDDisplayMode.initialMode(defaults: defaults), .limits)
    }

    /// A value from a future build, or a corrupted one.
    func testUnrecognizedStoredValueResolvesToQuotaMeter() {
        defaults.set("not-a-mode", forKey: PreferencesKey.Cockpit.hudDisplayMode)
        XCTAssertEqual(AgentCockpitHUDDisplayMode.initialMode(defaults: defaults), .limits)
    }

    func testEmptyDefaultsResolveToQuotaMeter() {
        XCTAssertEqual(AgentCockpitHUDDisplayMode.initialMode(defaults: defaults), .limits)
    }

    /// Both keys disagreeing — a half-migrated state from an older build.
    func testConflictingStoredAndLegacyValuesResolveToQuotaMeter() {
        defaults.set("full", forKey: PreferencesKey.Cockpit.hudDisplayMode)
        defaults.set(true, forKey: PreferencesKey.Cockpit.hudCompact)
        XCTAssertEqual(AgentCockpitHUDDisplayMode.initialMode(defaults: defaults), .limits)
    }
}
