import XCTest
import SwiftUI
@testable import AgentSessions

/// The Quota Meter's OpenCode sessions group: which rows it shows, how it counts
/// them, and when it hides. The group is a pure filter over the HUD's
/// `rowsForDisplay`, so most rules are pinned on `OpenCodeHUDGroup.make`; the
/// end-to-end cases drive `makeRowsSnapshot` with synthetic OpenCode presences to
/// pin which presences become rows at all.
@MainActor
final class OpenCodeHUDGroupTests: XCTestCase {

    // MARK: - Fixtures

    private func row(_ id: String,
                     source: SessionSource = .opencode,
                     state: HUDLiveState = .idle,
                     idleReason: HUDIdleReason? = nil) -> HUDRow {
        let agentType: HUDAgentType = {
            switch source {
            case .opencode: return .opencode
            case .claude: return .claude
            default: return .codex
            }
        }()
        return HUDRow(
            id: id,
            source: source,
            agentType: agentType,
            projectName: "proj",
            displayName: "Session \(id)",
            liveState: state,
            preview: "Session \(id)",
            elapsed: "",
            lastSeenAt: Date(),
            itermSessionId: nil,
            revealURL: nil,
            tty: nil,
            termProgram: nil,
            idleReason: idleReason
        )
    }

    private func make(_ rows: [HUDRow],
                      detectionEnabled: Bool = true,
                      openCodeEnabled: Bool = true) -> OpenCodeHUDGroupModel? {
        OpenCodeHUDGroup.make(rows: rows, detectionEnabled: detectionEnabled, openCodeEnabled: openCodeEnabled)
    }

    // MARK: - Visibility

    func testHiddenWhenOpenCodeAgentDisabled() {
        XCTAssertNil(make([row("a")], openCodeEnabled: false))
    }

    func testHiddenWhenLiveDetectionDisabled() {
        XCTAssertNil(make([row("a")], detectionEnabled: false))
    }

    func testHiddenWhenNoOpenCodeRows() {
        XCTAssertNil(make([]))
        XCTAssertNil(make([row("c", source: .codex), row("k", source: .claude)]),
                     "Codex and Claude rows must never make the OpenCode group appear")
    }

    // MARK: - Rows and count

    func testIgnoresOtherSourcesAndKeepsIncomingOrder() throws {
        let model = try XCTUnwrap(make([
            row("o1", state: .idle),
            row("c1", source: .codex, state: .active),
            row("o2", state: .active),
            row("k1", source: .claude),
            row("o3", state: .idle)
        ]))
        // No second working-first sort: rowsForDisplay already owns the order.
        XCTAssertEqual(model.rows.map(\.id), ["o1", "o2", "o3"])
        XCTAssertEqual(model.totalCount, 3)
    }

    func testDuplicateIDsCountOnce() throws {
        let model = try XCTUnwrap(make([row("o1"), row("o2"), row("o1", state: .active)]))
        XCTAssertEqual(model.rows.map(\.id), ["o1", "o2"])
        XCTAssertEqual(model.rows.first?.liveState, .idle, "the first occurrence wins")
        XCTAssertEqual(model.totalCount, model.rows.count)
    }

    func testStuckIdleRowIsStillRunning() throws {
        let model = try XCTUnwrap(make([row("o1", idleReason: .errorOrStuck)]))
        XCTAssertEqual(model.totalCount, 1)
    }

    func testCountsAndOverflow() throws {
        for (count, visible, overflow) in [(1, 1, 0), (2, 2, 0), (4, 4, 0), (6, 4, 2)] {
            let rows = (0..<count).map { row("o\($0)") }
            let model = try XCTUnwrap(make(rows), "count \(count)")
            XCTAssertEqual(model.totalCount, count, "count \(count)")
            XCTAssertEqual(model.visibleRows.count, visible, "count \(count)")
            XCTAssertEqual(model.overflowCount, overflow, "count \(count)")
            XCTAssertEqual(model.visibleRows.map(\.id), Array(rows.prefix(visible)).map(\.id))
        }
        XCTAssertEqual(OpenCodeHUDGroup.maxVisibleSessions, 4)
    }

    // MARK: - Copy

    func testStateLabelNeverSaysStuck() {
        XCTAssertEqual(String(localized: OpenCodeHUDGroup.stateLabel(for: row("a", state: .active))), "working")
        XCTAssertEqual(String(localized: OpenCodeHUDGroup.stateLabel(for: row("b", state: .idle))), "idle")
        XCTAssertEqual(String(localized: OpenCodeHUDGroup.stateLabel(for: row("c", state: .idle, idleReason: .errorOrStuck))), "idle")
    }

    func testCountAndOverflowCopyIsPluralAware() {
        XCTAssertEqual(String(localized: OpenCodeHUDGroup.runningText(count: 1)), "1 running")
        XCTAssertEqual(String(localized: OpenCodeHUDGroup.runningText(count: 2)), "2 running")
        XCTAssertEqual(String(localized: OpenCodeHUDGroup.runningText(count: 6)), "6 running")
        XCTAssertEqual(String(localized: OpenCodeHUDGroup.overflowText(count: 1)), "+1 more")
        XCTAssertEqual(String(localized: OpenCodeHUDGroup.overflowText(count: 2)), "+2 more")
    }

    func testChineseCopyResolvesFromCatalog() {
        for count in [1, 2, 6] {
            var running = OpenCodeHUDGroup.runningText(count: count)
            running.locale = Locale(identifier: "zh-Hans")
            let text = String(localized: running)
            XCTAssertTrue(text.contains("\(count)"), "zh-Hans running text keeps the count: \(text)")
            XCTAssertFalse(text.contains("running"), "zh-Hans running text is translated: \(text)")
        }
        var working = OpenCodeHUDGroup.stateLabel(for: row("a", state: .active))
        working.locale = Locale(identifier: "zh-Hans")
        XCTAssertNotEqual(String(localized: working), "working")
        var more = OpenCodeHUDGroup.overflowText(count: 2)
        more.locale = Locale(identifier: "zh-Hans")
        XCTAssertFalse(String(localized: more).contains("more"))
    }

    // MARK: - Mounted panel

    /// Mounts the real panel and returns its fitted height. Usage tracking is
    /// forced off for Codex and Claude, so the only content is the OpenCode group
    /// or the panel's 30 pt empty row.
    private func panelHeight(rows: [HUDRow], detectionEnabled: Bool = true, openCodeEnabled: Bool) -> CGFloat {
        let defaults = UserDefaults.standard
        let keys = [PreferencesKey.codexUsageEnabled, PreferencesKey.claudeUsageEnabled, PreferencesKey.Agents.openCodeEnabled]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: PreferencesKey.codexUsageEnabled)
        defaults.set(false, forKey: PreferencesKey.claudeUsageEnabled)
        defaults.set(openCodeEnabled, forKey: PreferencesKey.Agents.openCodeEnabled)
        let host = NSHostingView(rootView: HUDLimitsRowsPanelTestHost.view(activeRows: rows, detectionEnabled: detectionEnabled)
            .frame(width: 380))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testMountedPanelShowsGroupAloneInOpenCodeOnlyState() {
        let rows = [row("o1", state: .active), row("o2")]
        let withGroup = panelHeight(rows: rows, openCodeEnabled: true)
        let withoutGroup = panelHeight(rows: rows, openCodeEnabled: false)
        XCTAssertEqual(withoutGroup, 30, accuracy: 0.5, "agent disabled: only the empty row remains")
        XCTAssertGreaterThan(withGroup, withoutGroup + 20,
                             "same rows, agent enabled: the group replaces the empty row and is measured")
    }

    func testMountedPanelHidesGroupWhenDetectionOffOrNoOpenCodeRows() {
        XCTAssertEqual(panelHeight(rows: [row("o1")], detectionEnabled: false, openCodeEnabled: true), 30, accuracy: 0.5)
        XCTAssertEqual(panelHeight(rows: [row("c1", source: .codex)], openCodeEnabled: true), 30, accuracy: 0.5)
    }

    func testMountedPanelGrowsWithOverflowLine() {
        let four = panelHeight(rows: (0..<4).map { row("o\($0)") }, openCodeEnabled: true)
        let six = panelHeight(rows: (0..<6).map { row("o\($0)") }, openCodeEnabled: true)
        XCTAssertGreaterThan(six, four, "the +N more line is inside the measured region")
    }

    // MARK: - Session rates

    private func rateRow(_ id: String, session: String, state: HUDLiveState = .active,
                         resolved: Bool = true, parent: String? = nil) -> HUDRow {
        HUDRow(id: id, source: .opencode, agentType: .opencode, projectName: "proj", displayName: id,
               liveState: state, preview: id, elapsed: "", lastSeenAt: Date(), itermSessionId: nil,
               revealURL: nil, tty: nil, termProgram: nil,
               resolvedSessionID: resolved ? session : nil, runtimeSessionID: resolved ? nil : session,
               parentSessionID: parent)
    }

    func testSessionIDPrefersResolvedThenRuntime() {
        XCTAssertEqual(OpenCodeHUDGroup.sessionID(for: rateRow("r", session: "ses_a")), "ses_a")
        XCTAssertEqual(OpenCodeHUDGroup.sessionID(for: rateRow("r", session: "ses_b", resolved: false)), "ses_b")
        XCTAssertNil(OpenCodeHUDGroup.sessionID(for: row("plain")))
    }

    func testRowShowsOwnSessionRate() throws {
        let group = try XCTUnwrap(OpenCodeHUDGroup.make(rows: [rateRow("r", session: "ses_a")], detectionEnabled: true,
                                                        openCodeEnabled: true, rates: ["ses_a": .rate(412_000, .tokensPerHour)]))
        XCTAssertEqual(group.rates["ses_a"], .rate(412_000, .tokensPerHour))
    }

    func testParentAndChildRowsShowTheirOwnRates() throws {
        let rows = [rateRow("parent", session: "ses_p"), rateRow("child", session: "ses_c", parent: "ses_p")]
        let rates: [String: OpenCodeRateValue] = ["ses_p": .rate(100, .tokensPerHour), "ses_c": .rate(50, .tokensPerHour)]
        let group = try XCTUnwrap(OpenCodeHUDGroup.make(rows: rows, detectionEnabled: true, openCodeEnabled: true, rates: rates))
        XCTAssertEqual(rows.compactMap { group.rates[OpenCodeHUDGroup.sessionID(for: $0) ?? ""] },
                       [.rate(100, .tokensPerHour), .rate(50, .tokensPerHour)], "no aggregation, no double count")
    }

    func testAlwaysOffHidesExistingRate() {
        XCTAssertFalse(OpenCodeHUDGroup.showsRates(visibility: .alwaysOff, isStrip: false, stripExpanded: false))
        let snapshot = OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 1, version: 1,
                                            values: ["ses_a": .rate(1, .tokensPerHour)])
        XCTAssertEqual(OpenCodeHUDGroup.displayedRates(snapshot: snapshot, presentation: .token, showsRates: false), [:],
                       "a populated snapshot is not shown once rates are off")
    }

    func testCollapsedStripHidesExistingRate() {
        XCTAssertFalse(OpenCodeHUDGroup.showsRates(visibility: .automatic, isStrip: true, stripExpanded: false))
        XCTAssertTrue(OpenCodeHUDGroup.showsRates(visibility: .automatic, isStrip: true, stripExpanded: true))
        XCTAssertTrue(OpenCodeHUDGroup.showsRates(visibility: .alwaysOn, isStrip: false, stripExpanded: false))
    }

    func testSnapshotForOtherPresentationIgnored() {
        let snapshot = OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 1, version: 1,
                                            values: ["ses_a": .rate(1, .tokensPerHour)])
        XCTAssertEqual(OpenCodeHUDGroup.displayedRates(snapshot: snapshot, presentation: .dollar, showsRates: true), [:])
        XCTAssertEqual(OpenCodeHUDGroup.displayedRates(snapshot: snapshot, presentation: .token, showsRates: true).count, 1)
    }

    func testPositiveRateUsesProjectionColorEvenWhenQuiet() throws {
        let cell = try XCTUnwrap(OpenCodeHUDGroup.rateCell(for: .rate(0.4, .tokensPerHour)))
        XCTAssertEqual(cell.text, "quiet")
        XCTAssertTrue(cell.isPositive, "color follows the number, not the formatted text")
        XCTAssertFalse(try XCTUnwrap(OpenCodeHUDGroup.rateCell(for: .rate(0, .tokensPerHour))).isPositive)
        XCTAssertNil(OpenCodeHUDGroup.rateCell(for: .working), "working and idle keep the state label")
        XCTAssertNil(OpenCodeHUDGroup.rateCell(for: .idle))
    }

    func testIdleRecentRateIsMarkedIdleAndQuiet() throws {
        let rate = try XCTUnwrap(OpenCodeHUDGroup.rateCell(for: .rate(2_000_000, .tokensPerHour)))
        let idle = try XCTUnwrap(OpenCodeHUDGroup.rateCell(for: .idleRecent(.rate(2_000_000, .tokensPerHour))))
        XCTAssertEqual(idle.text, rate.text, "the same number as while working")
        XCTAssertTrue(idle.isIdle)
        XCTAssertFalse(rate.isIdle)
        XCTAssertFalse(idle.isPositive, "an idle rate is drawn secondary, not in the projection color")
        let free = try XCTUnwrap(OpenCodeHUDGroup.rateCell(for: .idleRecent(.free)))
        XCTAssertEqual(free.text, "Free")
        XCTAssertTrue(free.isIdle)
        let unpriced = try XCTUnwrap(OpenCodeHUDGroup.rateCell(
            for: .idleRecent(.unpriced(unknownModels: ["a"], missingComponents: []))))
        XCTAssertEqual(unpriced.help, "No API price for a")
        XCTAssertTrue(unpriced.isIdle)
    }

    func testLoadBarFillsOnlyForAWorkingRate() {
        let working = OpenCodeHUDGroup.loadBar(for: .rate(500_000, .tokensPerHour))
        XCTAssertEqual(working, OpenCodeLoadBar(displayRate: 500_000, confidence: .direct))
        XCTAssertTrue(RunwayLoadBarFill.shouldFill(displayRate: working.displayRate, maxDisplayRate: 1_000_000,
                                                   confidence: working.confidence), "positive control")
        let empty: [OpenCodeRateValue?] = [.idleRecent(.rate(500_000, .tokensPerHour)), .idle, .working, .free,
                                           .unpriced(unknownModels: [], missingComponents: []), .unavailable, nil]
        for value in empty {
            let bar = OpenCodeHUDGroup.loadBar(for: value)
            XCTAssertFalse(RunwayLoadBarFill.shouldFill(displayRate: bar.displayRate, maxDisplayRate: 1_000_000,
                                                        confidence: bar.confidence), "empty track for \(String(describing: value))")
        }
        XCTAssertEqual(OpenCodeHUDGroup.loadBar(for: .idleRecent(.rate(500_000, .tokensPerHour))).confidence, .idle)
    }

    func testLoadBarScalesToFastestWorkingOpenCodeRow() throws {
        let rows = [rateRow("a", session: "ses_a"), rateRow("b", session: "ses_b"), rateRow("c", session: "ses_c", state: .idle)]
        let rates: [String: OpenCodeRateValue] = ["ses_a": .rate(1_000_000, .tokensPerHour),
                                                  "ses_b": .rate(250_000, .tokensPerHour),
                                                  "ses_c": .idleRecent(.rate(5_000_000, .tokensPerHour))]
        let group = try XCTUnwrap(OpenCodeHUDGroup.make(rows: rows, detectionEnabled: true, openCodeEnabled: true,
                                                        rates: rates, rateUnit: .tokensPerHour))
        XCTAssertEqual(group.maxBarRate, 1_000_000, "an idle row's last rate does not set the scale")
        let quiet = try XCTUnwrap(OpenCodeHUDGroup.make(rows: rows, detectionEnabled: true, openCodeEnabled: true,
                                                        rates: [:], rateUnit: .tokensPerHour))
        XCTAssertEqual(quiet.maxBarRate, 1, "floored at 1 like the runway")
    }

    func testRateUnitOnlyWhileRatesAreShown() throws {
        let rows = [rateRow("a", session: "ses_a")]
        XCTAssertNil(try XCTUnwrap(OpenCodeHUDGroup.make(rows: rows, detectionEnabled: true, openCodeEnabled: true)).rateUnit,
                     "no unit, no rate columns: the row keeps its plain label layout")
        XCTAssertEqual(try XCTUnwrap(OpenCodeHUDGroup.make(rows: rows, detectionEnabled: true, openCodeEnabled: true,
                                                           rateUnit: .dollarsPerHour)).rateUnit, .dollarsPerHour)
    }

    func testUnpricedHelpModelOnly() {
        XCTAssertEqual(OpenCodeHUDGroup.unpricedHelp(unknownModels: ["a", "b"], missingComponents: []),
                       "No API price for a, b")
    }

    func testUnpricedHelpComponentOnly() {
        XCTAssertEqual(OpenCodeHUDGroup.unpricedHelp(unknownModels: [], missingComponents: ["gpt-5:cacheWrite5m"]),
                       "Missing API price component: gpt-5:cacheWrite5m")
    }

    func testUnpricedHelpMixedShowsBoth() {
        XCTAssertEqual(OpenCodeHUDGroup.unpricedHelp(unknownModels: ["a"], missingComponents: ["gpt-5:cacheWrite5m"]),
                       "No API price for a\nMissing API price component: gpt-5:cacheWrite5m")
    }

    func testUnpricedHelpGenericWhenEmpty() {
        XCTAssertEqual(OpenCodeHUDGroup.unpricedHelp(unknownModels: [], missingComponents: []),
                       "No API price for this session's recent usage.")
    }

    func testToolbarControlUsesParentComputedGroupVisibility() {
        let rows = [rateRow("r", session: "ses_a")]
        XCTAssertTrue(OpenCodeHUDGroup.isVisible(rows: rows, detectionEnabled: true, openCodeEnabled: true))
        XCTAssertFalse(OpenCodeHUDGroup.isVisible(rows: rows, detectionEnabled: true, openCodeEnabled: false))
        XCTAssertFalse(OpenCodeHUDGroup.isVisible(rows: [row("c", source: .codex)], detectionEnabled: true, openCodeEnabled: true))
    }

    func testControlAvailableForOpenCodeOnly() {
        XCTAssertTrue(OpenCodeHUDGroup.controlAvailable(providersShown: false, openCodeGroupVisible: true))
        XCTAssertTrue(OpenCodeHUDGroup.controlAvailable(providersShown: true, openCodeGroupVisible: false))
        XCTAssertFalse(OpenCodeHUDGroup.controlAvailable(providersShown: false, openCodeGroupVisible: false))
    }

    func testDemandIsVisibleSessionsWithWorkingState() throws {
        let rows = [rateRow("w", session: "ses_w", state: .active), rateRow("i", session: "ses_i", state: .idle), row("none")]
        let group = try XCTUnwrap(make(rows))
        XCTAssertEqual(OpenCodeHUDGroup.demand(group: group, showsRates: true),
                       OpenCodeRateDemand(sessions: ["ses_w": true, "ses_i": false]))
        XCTAssertNil(OpenCodeHUDGroup.demand(group: group, showsRates: false))
    }

    func testAlwaysOffReportsNoDemand() throws {
        let rows = [rateRow("w", session: "ses_w")]
        let on = mountForDemand(rows: rows, store: OpenCodeRateStore(), visibility: .automatic, stripExpanded: nil)
        XCTAssertNotNil(on.mounted, "positive control: the same mount reports demand when rates are on")
        let off = mountForDemand(rows: rows, store: OpenCodeRateStore(), visibility: .alwaysOff, stripExpanded: nil)
        XCTAssertNil(off.mounted)
    }

    func testMountedStripReportsDemandOnlyWhenExpanded() throws {
        let rows = [rateRow("w", session: "ses_w")]
        let expected = OpenCodeRateDemand(sessions: ["ses_w": true])
        XCTAssertNil(mountForDemand(rows: rows, store: OpenCodeRateStore(), visibility: .automatic, stripExpanded: false).mounted,
                     "a collapsed strip shows no rates and asks for none")
        let expanded = mountForDemand(rows: rows, store: OpenCodeRateStore(), visibility: .automatic, stripExpanded: true)
        XCTAssertEqual(expanded.mounted, expected)
        XCTAssertNil(expanded.removed, "removing the surface withdraws its demand")
        XCTAssertEqual(mountForDemand(rows: rows, store: OpenCodeRateStore(), visibility: .automatic, stripExpanded: nil).mounted,
                       expected)
    }

    func testNewStringsHaveChineseTranslations() throws {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentSessions/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        let strings = try XCTUnwrap(json?["strings"] as? [String: Any])
        for key in ["No API price for %@", "Missing API price component: %@",
                    "No API price for this session's recent usage.", "Usage data for this session is incomplete."] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let zh = (entry["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any]
            let value = (zh?["stringUnit"] as? [String: Any])?["value"] as? String
            XCTAssertFalse(value?.isEmpty ?? true, "zh-Hans for \(key)")
        }
    }

    /// Mounts the real panel in a window, so appear/change handlers run, and returns
    /// the store's demand while it is mounted and after it is removed.
    @discardableResult
    private func mountForDemand(rows: [HUDRow], store: OpenCodeRateStore,
                                visibility: QuotaMeterRunwayVisibility,
                                stripExpanded: Bool?) -> (mounted: OpenCodeRateDemand?, removed: OpenCodeRateDemand?) {
        let defaults = UserDefaults.standard
        let keys = [PreferencesKey.Agents.openCodeEnabled, PreferencesKey.quotaMeterRunwayVisibility]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: PreferencesKey.Agents.openCodeEnabled)
        defaults.set(visibility.rawValue, forKey: PreferencesKey.quotaMeterRunwayVisibility)
        let host = NSHostingView(rootView: HUDLimitsRowsPanelTestHost.view(
            activeRows: rows, detectionEnabled: true, rateStore: store, stripExpanded: stripExpanded)
            .frame(width: 380))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let mounted = store.demandUnionForTesting
        window.contentView = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (mounted, store.demandUnionForTesting)
    }

    // MARK: - End to end through makeRowsSnapshot

    private func session(_ id: String, cwd: String? = nil, title: String? = nil, now: Date = Date()) -> Session {
        Session(
            id: id,
            source: .opencode,
            startTime: now.addingTimeInterval(-60),
            endTime: now,
            model: nil,
            filePath: "/tmp/opencode-hud-tests/\(id).json",
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil,
            customTitle: title
        )
    }

    private func presence(logPath: String? = nil,
                          sessionId: String? = nil,
                          workspace: String? = nil,
                          tty: String? = nil,
                          pid: Int? = nil,
                          kind: String? = nil,
                          termProgram: String? = nil) -> CodexActivePresence {
        var p = CodexActivePresence()
        p.source = .opencode
        p.sessionLogPath = logPath
        p.sessionId = sessionId
        p.workspaceRoot = workspace
        p.tty = tty
        p.pid = pid
        p.kind = kind
        p.lastSeenAt = Date()
        if let termProgram {
            var terminal = CodexActivePresence.Terminal()
            terminal.termProgram = termProgram
            p.terminal = terminal
        }
        return p
    }

    private func snapshotRows(sessions: [Session],
                              presences: [CodexActivePresence],
                              liveStates: [String: CodexLiveState] = [:],
                              showProbes: Bool = false) -> [HUDRow] {
        let model = CodexActiveSessionsModel()
        var snapshot = PresenceSnapshot.empty
        snapshot.presences = presences
        snapshot.membershipVersion = 1
        for presence in presences {
            let key = CodexActiveSessionsModel.presenceKey(for: presence)
            snapshot.liveStateByPresenceKey[key] = liveStates[key] ?? .openIdle
            if let log = presence.sessionLogPath {
                snapshot.byLogPath[CodexActiveSessionsModel.logLookupKey(
                    source: .opencode,
                    normalizedPath: CodexActiveSessionsModel.normalizePath(log))] = presence
            }
        }
        model.debugApply(PresenceEngine.Emission(snapshot: snapshot, isMembershipChange: true))
        let indexes = AgentCockpitHUDView.buildSessionLookupIndexes(
            codexSessions: [], claudeSessions: [], opencodeSessions: sessions)
        return AgentCockpitHUDView.makeRowsSnapshot(
            codexSessions: [],
            claudeSessions: [],
            opencodeSessions: sessions,
            presences: model.presences,
            activeSubagentCounts: [:],
            activeCodex: model,
            isCompact: true,
            lookupIndexes: indexes,
            showProbePresences: showProbes
        ).rows.filter { $0.source == .opencode }
    }

    func testTwoPresencesForOneSessionBecomeOneRow() {
        let s = session("ses_a")
        let rows = snapshotRows(sessions: [s], presences: [
            presence(logPath: s.filePath, tty: "/dev/ttys001", pid: 100),
            presence(logPath: s.filePath, tty: "/dev/ttys001", pid: 101)
        ])
        XCTAssertEqual(rows.count, 1)
    }

    func testWorkingAndIdleStatesMapToHUDStates() throws {
        let working = session("ses_w")
        let idle = session("ses_i")
        let pw = presence(logPath: working.filePath, pid: 1)
        let pi = presence(logPath: idle.filePath, pid: 2)
        let rows = snapshotRows(sessions: [working, idle], presences: [pw, pi],
                                liveStates: [CodexActiveSessionsModel.presenceKey(for: pw): .activeWorking,
                                             CodexActiveSessionsModel.presenceKey(for: pi): .openIdle])
        XCTAssertEqual(Set(rows.map(\.liveState)), [.active, .idle])
        let model = try XCTUnwrap(OpenCodeHUDGroup.make(rows: rows, detectionEnabled: true, openCodeEnabled: true))
        XCTAssertEqual(model.totalCount, 2, "running = working + idle")
    }

    func testProbeDirectoryFilterAppliesToOpenCode() {
        let probeDir = CodexProbeConfig.probeWorkingDirectory()
        let p = presence(sessionId: "ses_probe", workspace: probeDir, pid: 7)
        XCTAssertTrue(snapshotRows(sessions: [], presences: [p], showProbes: false).isEmpty,
                      "the probe filter is source-independent")
        XCTAssertEqual(snapshotRows(sessions: [], presences: [p], showProbes: true).count, 1)
    }

    func testUnresolvedPresenceRules() {
        // Session ID alone keeps an unresolved presence.
        XCTAssertEqual(snapshotRows(sessions: [], presences: [presence(sessionId: "ses_x", pid: 1)]).count, 1)
        // A subagent with no resolved session is hidden even with a session ID.
        XCTAssertTrue(snapshotRows(sessions: [], presences: [presence(sessionId: "ses_y", pid: 2, kind: "subagent")]).isEmpty)
        // Terminal focusability alone does not identify an OpenCode conversation.
        XCTAssertTrue(snapshotRows(sessions: [], presences: [presence(tty: "/dev/ttys009", pid: 3, termProgram: "iTerm.app")]).isEmpty)
        // A non-iTerm TTY-only presence with no workspace match is hidden.
        XCTAssertTrue(snapshotRows(sessions: [], presences: [presence(tty: "/dev/ttys010", pid: 4, termProgram: "Apple_Terminal")]).isEmpty)
    }

    func testWorkspaceAloneDoesNotIdentifyOpenCodeConversation() {
        let s = session("ses_ws", cwd: "/tmp/opencode-hud-tests/project")
        let rows = snapshotRows(sessions: [s], presences: [
            presence(workspace: "/tmp/opencode-hud-tests/project", tty: "/dev/ttys011", pid: 5, termProgram: "Apple_Terminal")
        ])
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(SessionRowsBuilder.buildFallbackPresenceMap(sessions: [s], presences: [presence(workspace: s.cwd, pid: 5)], directJoinSessionKeys: []).isEmpty)
    }

    func testCompetingWorkspaceMatchesTakeDistinctSessions() {
        let older = session("ses_old", cwd: "/tmp/opencode-hud-tests/shared", title: "Older conversation")
        let newer = session("ses_new", cwd: "/tmp/opencode-hud-tests/shared", title: "Newer conversation")
        let first = presence(sessionId: older.id, workspace: older.cwd, tty: "/dev/ttys012", pid: 6, termProgram: "Apple_Terminal")
        let second = presence(sessionId: newer.id, workspace: newer.cwd, tty: "/dev/ttys013", pid: 7, termProgram: "Apple_Terminal")
        let rows = snapshotRows(sessions: [older, newer], presences: [first, second])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.resolvedSessionID)).count, 2, "each presence claims its own session")
    }

    func testOpenCodeHomeAndMissingTitlesDoNotBorrowClosedConversation() throws {
        let cwd = "/tmp/opencode-hud-tests/shared"
        let old = session("ses_old", cwd: cwd, title: "Closed")
        var live = focusablePresence(workspace: cwd)
        for title in [nil, "OpenCode", "Research", "OC | Unknown"] as [String?] {
            live.terminal?.tabTitle = title
            XCTAssertTrue(snapshotRows(sessions: [old], presences: [live]).isEmpty)
            XCTAssertTrue(SessionRowsBuilder.buildFallbackPresenceMap(sessions: [old], presences: [live], directJoinSessionKeys: []).isEmpty)
        }
    }

    func testNativeOpenCodeIDSelectsOlderConversationWithDuplicateTitles() throws {
        let cwd = "/tmp/opencode-hud-tests/shared"
        let older = session("ses_older", cwd: cwd, title: "Same title", now: Date(timeIntervalSince1970: 100))
        let newer = session("ses_newer", cwd: cwd, title: "Same title", now: Date(timeIntervalSince1970: 200))
        let live = presence(sessionId: older.id, workspace: cwd, pid: 42)
        let rows = snapshotRows(sessions: [older, newer], presences: [live])
        XCTAssertEqual(try XCTUnwrap(rows.first).resolvedSessionID, older.id)
        XCTAssertEqual(rows.first?.displayName, "Same title")
        XCTAssertEqual(rows.count, 1)
    }

    private func focusablePresence(workspace: String) -> CodexActivePresence {
        var p = presence(workspace: workspace, tty: "/dev/ttys017", pid: 36725, termProgram: "iTerm.app")
        p.terminal?.itermSessionId = "w0t0p0:12345678-1234-1234-1234-123456789abc"
        return p
    }

    /// Found in the 2026-10-21 end-to-end run: a fresh `opencode` started in
    /// `/private/tmp/…/gamma`, with no conversation yet, showed the title of an old
    /// session started in `/private/tmp`. The workspace resolver accepted any
    /// parent folder, including shared roots.
    func testNewSessionDoesNotBorrowASessionFromASharedParentFolder() throws {
        for (index, root) in ["/private/tmp", "/tmp", NSHomeDirectory()].enumerated() {
            let old = session("ses_root_\(index)", cwd: root)
            let rows = snapshotRows(sessions: [old],
                                    presences: [focusablePresence(workspace: root + "/opencode-hud-tests/fresh")])
            XCTAssertTrue(rows.isEmpty, "\(root): an unidentified process must not claim an old conversation")
        }
    }

    func testPresenceInASharedRootDoesNotClaimADeeperSession() {
        let deeper = session("ses_deeper", cwd: NSHomeDirectory() + "/opencode-hud-tests/project")
        let rows = snapshotRows(sessions: [deeper], presences: [focusablePresence(workspace: NSHomeDirectory())])
        XCTAssertNil(rows.first?.resolvedSessionID)
    }

    func testProjectParentFolderDoesNotIdentifyOpenCodeConversation() {
        // A project parent is still not proof of the client's selected session.
        let repo = session("ses_repo", cwd: "/tmp/opencode-hud-tests/repo")
        let rows = snapshotRows(sessions: [repo],
                                presences: [focusablePresence(workspace: "/tmp/opencode-hud-tests/repo/sub")])
        XCTAssertTrue(rows.isEmpty)
    }

    func testHeadlessPresenceWithSessionIDIsShown() {
        // Mapper behaviour only: a synthetic no-TTY presence. This is not proof that
        // PresenceEngine discovers real headless processes.
        let rows = snapshotRows(sessions: [], presences: [presence(sessionId: "ses_headless", pid: 42)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.tty)
    }
}

final class OpenCodeServicePresenceTests: XCTestCase {
    private var registration: OpenCodeServicePresence.Registration {
        .init(id: "service-test", url: URL(string: "http://127.0.0.1:12345")!, pid: 123, password: "test-password")
    }

    func testNativeTUIRegistryStateDistinguishesIdleFromFreshHeartbeat() throws {
        for state in ["openIdle", "activeWorking"] {
            let data = Data("{\"publisher\":\"agent-sessions-opencode-tui\",\"source\":\"opencode\",\"sessionId\":\"ses_exact\",\"activityState\":\"\(state)\"}".utf8)
            let presence = try CodexActiveSessionsModel.makeDecoder().decode(CodexActivePresence.self, from: data)
            XCTAssertEqual(presence.sessionId, "ses_exact")
            XCTAssertEqual(presence.liveStateHint?.rawValue, state)
        }
    }

    func testNativeTUIRegistryRejectsDeadAndExpiredClients() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var presence = CodexActivePresence()
        presence.publisher = "agent-sessions-opencode-tui"
        presence.source = .opencode
        presence.sessionId = "ses_exact"
        presence.pid = Int(getpid())
        presence.lastSeenAt = now
        presence.liveStateHint = .openIdle
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = root.appendingPathComponent("client.json")
        try encoder.encode(presence).write(to: file)
        XCTAssertEqual(CodexActiveSessionsModel.loadPresences(from: root, decoder: CodexActiveSessionsModel.makeDecoder(), now: now, ttl: 60).count, 1)
        XCTAssertTrue(CodexActiveSessionsModel.loadPresences(from: root, decoder: CodexActiveSessionsModel.makeDecoder(), now: now.addingTimeInterval(6), ttl: 60).isEmpty)
        presence.pid = Int(Int32.max)
        try encoder.encode(presence).write(to: file)
        XCTAssertTrue(CodexActiveSessionsModel.loadPresences(from: root, decoder: CodexActiveSessionsModel.makeDecoder(), now: now, ttl: 60).isEmpty)
    }

    func testAbandonedNativeTUIFilesAreRemovedAndLiveOnesKept() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func write(_ name: String, pid: Int, lastSeenAt: Date, publisher: String = "agent-sessions-opencode-tui") throws -> URL {
            var presence = CodexActivePresence()
            presence.publisher = publisher
            presence.source = .opencode
            presence.sessionId = "ses_exact"
            presence.pid = pid
            presence.lastSeenAt = lastSeenAt
            presence.liveStateHint = .openIdle
            let file = root.appendingPathComponent(name)
            try encoder.encode(presence).write(to: file)
            return file
        }
        let live = try write("opencode-tui-live.json", pid: Int(getpid()), lastSeenAt: now)
        let crashed = try write("opencode-tui-crashed.json", pid: Int(Int32.max), lastSeenAt: now)
        let silent = try write("opencode-tui-silent.json", pid: Int(getpid()), lastSeenAt: now.addingTimeInterval(-11 * 60))
        // Files this integration did not publish are never removed.
        let foreign = try write("client.json", pid: Int(Int32.max), lastSeenAt: now)
        let otherPublisher = try write("opencode-tui-other.json", pid: Int(Int32.max), lastSeenAt: now, publisher: "someone-else")
        let oldTemporary = root.appendingPathComponent("opencode-tui-crashed.json.tmp")
        let freshTemporary = root.appendingPathComponent("opencode-tui-live.json.tmp")
        try Data("{}".utf8).write(to: oldTemporary)
        try Data("{}".utf8).write(to: freshTemporary)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-11 * 60)], ofItemAtPath: oldTemporary.path)

        let loaded = CodexActiveSessionsModel.loadPresences(from: root, decoder: CodexActiveSessionsModel.makeDecoder(), now: now, ttl: 60)
        let loadedNames = Set(loaded.compactMap { $0.sourceFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } })
        XCTAssertTrue(loadedNames.contains(live.lastPathComponent))
        XCTAssertTrue(loadedNames.isDisjoint(with: [crashed.lastPathComponent, silent.lastPathComponent]))
        for removed in [crashed, silent, oldTemporary] { XCTAssertFalse(fm.fileExists(atPath: removed.path), removed.lastPathComponent) }
        for kept in [live, foreign, otherPublisher, freshTemporary] { XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent) }
    }

    func testActiveServiceIDsIdentifySessionsWithoutTerminalMetadata() throws {
        let body = Data(#"{"data":{"ses_current":{"type":"running"},"ses_closed":{"type":"idle"}}}"#.utf8)
        let result = try XCTUnwrap(OpenCodeServicePresence.decode(body, registration: registration, now: Date()))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.sessionId, "ses_current")
        XCTAssertEqual(result.first?.liveStateHint, .activeWorking)
        XCTAssertNil(result.first?.tty)
        XCTAssertNil(result.first?.terminal)
    }

    func testIdleResponseDoesNotInventAnOpenConversation() throws {
        XCTAssertTrue(try XCTUnwrap(OpenCodeServicePresence.decode(Data(#"{"data":{}}"#.utf8), registration: registration, now: Date())).isEmpty)
        XCTAssertNil(OpenCodeServicePresence.decode(Data("not JSON".utf8), registration: registration, now: Date()))
    }

    func testServiceRequestUsesAdvertisedLoopbackPortAndNativeAuthentication() throws {
        let request = try XCTUnwrap(OpenCodeServicePresence.request(for: registration))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:12345/api/session/active")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("opencode:test-password".utf8).base64EncodedString())
        XCTAssertEqual(request.timeoutInterval, 1)
    }

    func testServiceRequestRejectsRemoteAndMalformedRegistrations() {
        for address in ["http://example.com:12345", "https://127.0.0.1:12345", "http://127.0.0.1:12345/foreign", "http://user@127.0.0.1:12345"] {
            let remote = OpenCodeServicePresence.Registration(id: "service-test", url: URL(string: address)!, pid: 123, password: "test-password")
            XCTAssertNil(OpenCodeServicePresence.request(for: remote))
        }
        let invalidPID = OpenCodeServicePresence.Registration(id: "service-test", url: registration.url, pid: Int.max, password: "test-password")
        XCTAssertNil(OpenCodeServicePresence.request(for: invalidPID))
    }
}
