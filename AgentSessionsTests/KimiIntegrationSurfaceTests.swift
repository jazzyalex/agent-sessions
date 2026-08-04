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

    // MARK: - Working directory

    /// `Session.cwd` keeps a hand-maintained list of providers whose working
    /// directory is authoritative lightweight metadata. Kimi reads `workDir`
    /// from its `state.json` sidecar, so it belongs there — but it was missing,
    /// which meant a *parsed* Kimi session (events non-empty, so the
    /// `events.isEmpty` fallback never fires) fell through to Codex's
    /// `<cwd>` transcript scraping and returned nil. Resume then built its
    /// command with no `cd` prefix and Kimi refused: "Session was created under
    /// a different directory."
    func testParsedKimiSessionKeepsItsSidecarWorkingDirectory() {
        let parsed = session(source: .kimi, events: [event(kind: .user), event(kind: .assistant)])

        XCTAssertEqual(parsed.lightweightCwd, "/tmp/project")
        XCTAssertEqual(parsed.cwd, "/tmp/project")
    }

    /// Pi stores its cwd in the same lightweight slot and was missing from the
    /// same list.
    func testParsedPiSessionKeepsItsHeaderWorkingDirectory() {
        let parsed = session(source: .pi, events: [event(kind: .user), event(kind: .assistant)])

        XCTAssertEqual(parsed.cwd, "/tmp/project")
    }

    /// The drift guard. Codex is the only provider that scrapes its cwd out of
    /// transcript events; every other one persists it as lightweight metadata
    /// and must keep it after a full parse. Kimi, Pi, and Cursor were each
    /// missing from the hand-written list at different times, and the symptom
    /// was always silent: a resume command with no `cd`, and a NULL cwd in the
    /// search index. A new provider that forgets this fails here.
    func testEveryNonCodexSourceKeepsItsLightweightCwdAfterParsing() {
        let parsedEvents = [event(kind: .user), event(kind: .assistant)]

        for source in SessionSource.allCases where source != .codex {
            XCTAssertEqual(session(source: source, events: parsedEvents).cwd,
                           "/tmp/project",
                           "\(source.rawValue) lost its working directory after a full parse")
        }
    }

    /// The other half of that guard, and the invariant the whole split rests on:
    /// Codex is the one provider whose lightweight cwd is NOT authoritative,
    /// because it scrapes the live value out of transcript events. Without this,
    /// "simplifying" the switch to always return true would keep every other
    /// test green while silently letting a stale stored cwd beat the transcript.
    func testCodexPrefersTheTranscriptCwdOverStaleLightweightMetadata() {
        let scraped = SessionEvent(id: "e-env", timestamp: nil, kind: .meta, role: nil,
                                   text: "<cwd>/real/project</cwd>",
                                   toolName: nil, toolInput: nil, toolOutput: nil,
                                   messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
        let parsed = Session(id: "codex-1",
                             source: .codex,
                             startTime: nil,
                             endTime: nil,
                             model: nil,
                             filePath: "/tmp/codex/rollout.jsonl",
                             eventCount: 1,
                             events: [scraped],
                             cwd: "/stale/project",
                             repoName: nil,
                             lightweightTitle: nil)

        XCTAssertEqual(parsed.lightweightCwd, "/stale/project")
        XCTAssertEqual(parsed.cwd, "/real/project")
    }

    /// The unparsed case already worked via the `events.isEmpty` fallback;
    /// it must keep working.
    func testUnparsedKimiSessionStillResolvesWorkingDirectory() {
        XCTAssertEqual(session(source: .kimi, events: []).cwd, "/tmp/project")
    }

    // MARK: - nil vs zero commands

    /// The consequence of `lightweightCommands` being nil rather than 0 when a
    /// truncated preview found none. `passesHasCommandsFilter` collapses the two
    /// with `?? 0`, so only `shouldDeepScan` can tell them apart — and this is
    /// the shape that reaches it: `KimiSessionIndexer` merges the *preview's*
    /// command count with the *full parse's* events, so a session can carry a
    /// stale count alongside real tool-call events.
    ///
    /// A stored 0 short-circuits before the event fallback and skips deep scan
    /// despite the session plainly having commands. nil lets the fallback run.
    func testNilCommandCountDefersToEventsWhileZeroSuppressesDeepScan() {
        let withToolCalls = [event(kind: .user), event(kind: .tool_call)]

        XCTAssertTrue(SearchCoordinator.shouldDeepScan(
            session: session(source: .kimi, events: withToolCalls, lightweightCommands: nil)),
            "nil means unknown, so the event count must decide")

        XCTAssertFalse(SearchCoordinator.shouldDeepScan(
            session: session(source: .kimi, events: withToolCalls, lightweightCommands: 0)),
            "a stored 0 is a positive claim and short-circuits the event count")
    }

    /// And the ordinary cases still behave.
    func testDeepScanUsesTheStoredCountWhenItIsPositive() {
        XCTAssertTrue(SearchCoordinator.shouldDeepScan(
            session: session(source: .kimi, events: [], lightweightCommands: 4)))
        XCTAssertFalse(SearchCoordinator.shouldDeepScan(
            session: session(source: .kimi, events: [], lightweightCommands: nil)),
            "no count and no events means nothing to scan for")
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
