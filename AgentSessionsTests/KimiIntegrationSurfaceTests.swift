import XCTest
@testable import AgentSessions

/// Regressions for the Kimi Code integration surfaces that the original tier-2
/// merge left unwired: the "has commands" quick filter, and the copy-resume
/// command's use of the configured binary.
final class KimiIntegrationSurfaceTests: XCTestCase {

    // MARK: - "Has commands" quick filter

    private func session(source: SessionSource,
                         events: [SessionEvent],
                         lightweightCommands: Int? = nil) -> Session {
        Session(id: "session_kimi-1",
                source: source,
                startTime: nil,
                endTime: nil,
                model: nil,
                filePath: "/tmp/kimi/session_kimi-1/agents/main/wire.jsonl",
                eventCount: events.count,
                events: events,
                cwd: "/tmp/project",
                repoName: "project",
                lightweightTitle: nil,
                lightweightCommands: lightweightCommands)
    }

    private func event(kind: SessionEventKind) -> SessionEvent {
        SessionEvent(id: "e-\(kind)", timestamp: nil, kind: kind, role: nil, text: nil,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    /// Kimi was absent from the JSONL-provider list, so every Kimi session fell
    /// through to the trailing `return true` and passed the filter regardless of
    /// whether it contained a single tool call.
    func testKimiSessionWithoutToolCallsIsFilteredOut() {
        let parsed = session(source: .kimi, events: [event(kind: .user), event(kind: .assistant)])

        XCTAssertFalse(UnifiedSessionIndexer.passesHasCommandsFilter(parsed))
    }

    func testKimiSessionWithToolCallsPassesFilter() {
        let parsed = session(source: .kimi, events: [event(kind: .user), event(kind: .tool_call)])

        XCTAssertTrue(UnifiedSessionIndexer.passesHasCommandsFilter(parsed))
    }

    /// Unparsed (lightweight) Kimi sessions fall back to the command count, the
    /// same as every other JSONL provider.
    func testUnparsedKimiSessionUsesLightweightCommandCount() {
        XCTAssertTrue(UnifiedSessionIndexer.passesHasCommandsFilter(
            session(source: .kimi, events: [], lightweightCommands: 3)))
        XCTAssertFalse(UnifiedSessionIndexer.passesHasCommandsFilter(
            session(source: .kimi, events: [], lightweightCommands: 0)))
        XCTAssertFalse(UnifiedSessionIndexer.passesHasCommandsFilter(
            session(source: .kimi, events: [], lightweightCommands: nil)))
    }

    /// Kimi must behave like its sibling JSONL providers, not like Claude.
    func testKimiMatchesPiFilterBehaviour() {
        for events in [[event(kind: .user)], [event(kind: .user), event(kind: .tool_call)], []] {
            XCTAssertEqual(UnifiedSessionIndexer.passesHasCommandsFilter(session(source: .kimi, events: events)),
                           UnifiedSessionIndexer.passesHasCommandsFilter(session(source: .pi, events: events)),
                           "Kimi and Pi disagreed for \(events.count) event(s)")
        }
    }

    // MARK: - Copy-resume binary

    @MainActor
    private func makeSettings(function: String = #function) -> KimiSettings {
        let suite = "KimiIntegrationSurfaceTests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return KimiSettings.makeForTesting(defaults: defaults)
    }

    /// With nothing configured or probed, copy-resume falls back to a bare
    /// `kimi` on PATH — the behaviour before the Preferences pane existed.
    @MainActor
    func testCopyCommandPlanFallsBackToBareBinary() throws {
        let plan = try XCTUnwrap(makeSettings().copyCommandPlan(sessionID: "session_abc"))

        XCTAssertEqual(plan.binary, "kimi")
        let command = try KimiResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                     binaryCommand: plan.binary)
        XCTAssertEqual(command, "kimi --session session_abc")
    }

    /// The custom binary set in Preferences must reach the copied command;
    /// before this it was hardcoded to "kimi" and the setting was inert.
    @MainActor
    func testCopyCommandPlanUsesCustomBinary() throws {
        let settings = makeSettings()
        settings.setBinaryPath("/opt/custom/kimi")

        let plan = try XCTUnwrap(settings.copyCommandPlan(sessionID: "session_abc"))

        XCTAssertEqual(plan.binary, "/opt/custom/kimi")
        let command = try KimiResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                     binaryCommand: plan.binary)
        XCTAssertEqual(command, "/opt/custom/kimi --session session_abc")
    }

    @MainActor
    func testCopyCommandPlanFallsBackToContinueWithoutSessionID() throws {
        let plan = try XCTUnwrap(makeSettings().copyCommandPlan(sessionID: "   "))

        let command = try KimiResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                     binaryCommand: plan.binary)
        XCTAssertEqual(command, "kimi --continue")
    }

    // MARK: - Preferences surface

    /// The Kimi pane must be reachable from the sidebar; without it the
    /// KimiSessionsRootOverride preference had no writer anywhere in the app.
    func testKimiPreferencesTabExists() {
        XCTAssertEqual(PreferencesTab.kimi.title, "Kimi Code")
        XCTAssertFalse(PreferencesTab.kimi.iconName.isEmpty)
        XCTAssertTrue(PreferencesTab.allCases.contains(.kimi))
    }
}
