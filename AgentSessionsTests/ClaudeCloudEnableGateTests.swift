import XCTest
@testable import AgentSessions


final class ClaudeCloudEnableGateTests: XCTestCase {

    private func defaults(_ name: String = #function) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_offWhenCloudToggleOff() {
        let d = defaults()
        d.set(true, forKey: PreferencesKey.claudeUsageEnabled)
        XCTAssertFalse(ClaudeCloudLiveModel.effectivelyEnabled(defaults: d))
    }

    /// Cloud rows render inside the Claude provider block, which only exists when
    /// usage tracking is on — so without it the feature is inert and must not poll.
    func test_offWhenClaudeUsageTrackingOff() {
        let d = defaults()
        d.set(true, forKey: PreferencesKey.claudeCloudSessionsEnabled)
        XCTAssertFalse(ClaudeCloudLiveModel.effectivelyEnabled(defaults: d),
                       "a stored-true toggle must not keep polling for rows nobody can draw")
    }

    func test_offWhenClaudeAgentDisabled() {
        let d = defaults()
        d.set(true, forKey: PreferencesKey.claudeCloudSessionsEnabled)
        d.set(true, forKey: PreferencesKey.claudeUsageEnabled)
        d.set(false, forKey: PreferencesKey.Agents.claudeEnabled)
        XCTAssertFalse(ClaudeCloudLiveModel.effectivelyEnabled(defaults: d),
                       "claudeAgentEnabled is the other half of the HUD's gate")
    }

    /// `Agents.claudeEnabled` defaults to TRUE, so an unset key means enabled.
    /// Reading it with `bool(forKey:)` alone would return false and wrongly disable.
    func test_unsetAgentKeyCountsAsEnabled() {
        let d = defaults()
        d.set(true, forKey: PreferencesKey.claudeCloudSessionsEnabled)
        d.set(true, forKey: PreferencesKey.claudeUsageEnabled)
        XCTAssertTrue(ClaudeCloudLiveModel.effectivelyEnabled(defaults: d))
    }
}
