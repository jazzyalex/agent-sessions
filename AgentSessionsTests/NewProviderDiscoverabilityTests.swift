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

    // MARK: - Detection Logic

    func testNewlyAvailableProviders_returnsProviderNotInKnownSetWithNoExplicitPref() {
        let suite = "test.detect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Known set has codex and claude
        defaults.set(["codex", "claude"], forKey: PreferencesKey.Agents.knownAvailableProviders)
        // No explicit pref for cursor — simulates implicit isAvailable() default

        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: [.codex, .claude, .cursor],
            defaults: defaults
        )

        XCTAssertEqual(candidates, [.cursor])
    }

    func testNewlyAvailableProviders_excludesProviderWithExplicitPref() {
        let suite = "test.detect.explicit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        defaults.set(["codex"], forKey: PreferencesKey.Agents.knownAvailableProviders)
        // User explicitly set cursor to true — they already know about it
        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .cursor))

        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: [.codex, .cursor],
            defaults: defaults
        )

        XCTAssertTrue(candidates.isEmpty, "Provider with explicit pref should not be a candidate")
    }

    func testNewlyAvailableProviders_excludesProviderAlreadyInKnownSet() {
        let suite = "test.detect.known.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        defaults.set(["codex", "cursor"], forKey: PreferencesKey.Agents.knownAvailableProviders)

        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: [.codex, .cursor],
            defaults: defaults
        )

        XCTAssertTrue(candidates.isEmpty, "Provider already in known set should not be a candidate")
    }

    func testNewlyAvailableProviders_returnsEmptyWhenNoNewProviders() {
        let suite = "test.detect.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let allRaw = SessionSource.allCases.map(\.rawValue)
        defaults.set(allRaw, forKey: PreferencesKey.Agents.knownAvailableProviders)

        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: Set(SessionSource.allCases),
            defaults: defaults
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Update Tour Screens

    func testNewProviderScreens_returnsCursorScreenForVersion3_2() {
        let screens = OnboardingContent.newProviderScreens(for: "3.2")
        XCTAssertEqual(screens.count, 1)
        let screen = screens[0]
        XCTAssertEqual(screen.title, "New Agent Support")
        XCTAssertEqual(screen.agentShowcase.count, 1)
        XCTAssertEqual(screen.agentShowcase[0].title, "Cursor")
        XCTAssertEqual(screen.agentShowcase[0].symbolName, "cursorarrow.rays")
    }

    func testNewProviderScreens_returnsEmptyForUnknownVersion() {
        let screens = OnboardingContent.newProviderScreens(for: "99.0")
        XCTAssertTrue(screens.isEmpty)
    }

    func testFallbackUpdateTourForVersion3_2_includesNewProviderScreen() {
        let content = OnboardingContent.fallbackUpdateTour(for: "3.2")
        let hasNewAgentScreen = content.screens.contains { $0.title == "New Agent Support" }
        XCTAssertTrue(hasNewAgentScreen, "Fallback tour for 3.2 should include New Agent Support slide")
    }
}
