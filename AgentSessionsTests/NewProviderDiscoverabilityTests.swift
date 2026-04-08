import XCTest
@testable import AgentSessions

final class NewProviderDiscoverabilityTests: XCTestCase {

    // MARK: - SessionSource Metadata

    func testVersionIntroducedIsDefinedForAllSources() {
        for source in SessionSource.allCases {
            XCTAssertFalse(source.versionIntroduced.isEmpty, "\(source) missing versionIntroduced")
        }
    }

    func testFeatureDescriptionIsDefinedForAllSources() {
        for source in SessionSource.allCases {
            XCTAssertFalse(source.featureDescription.isEmpty, "\(source) missing featureDescription")
        }
    }

    func testCursorVersionIntroduced() {
        XCTAssertEqual(SessionSource.cursor.versionIntroduced, "3.2")
    }

    func testOriginalProvidersHaveEarlyVersions() {
        XCTAssertEqual(SessionSource.codex.versionIntroduced, "1.0")
        XCTAssertEqual(SessionSource.claude.versionIntroduced, "1.0")
    }

    // MARK: - AgentEnablement Helpers

    func testEnablementKeyReturnsCorrectKeyForEachSource() {
        XCTAssertEqual(AgentEnablement.enablementKey(for: .codex), "AgentEnabledCodex")
        XCTAssertEqual(AgentEnablement.enablementKey(for: .cursor), "AgentEnabledCursor")
    }

    func testMigrateKnownAvailableProviders_populatesFromExplicitPreferences() {
        let suite = "test.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Simulate an existing user who explicitly enabled codex and claude
        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .codex))
        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .claude))

        AgentEnablement.migrateKnownAvailableProvidersIfNeeded(defaults: defaults)

        let known = defaults.stringArray(forKey: PreferencesKey.Agents.knownAvailableProviders) ?? []
        XCTAssertTrue(known.contains("codex"))
        XCTAssertTrue(known.contains("claude"))
        XCTAssertFalse(known.contains("cursor"), "Cursor has no explicit pref — should not be in known set")
    }

    func testMigrateKnownAvailableProviders_isNoOpOnSubsequentRuns() {
        let suite = "test.migrate.noop.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .codex))
        AgentEnablement.migrateKnownAvailableProvidersIfNeeded(defaults: defaults)

        // Now add an explicit pref for cursor AFTER migration
        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .cursor))
        AgentEnablement.migrateKnownAvailableProvidersIfNeeded(defaults: defaults)

        let known = defaults.stringArray(forKey: PreferencesKey.Agents.knownAvailableProviders) ?? []
        XCTAssertFalse(known.contains("cursor"), "Second migration should be a no-op")
    }
}
