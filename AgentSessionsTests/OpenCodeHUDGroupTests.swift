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

    // MARK: - End to end through makeRowsSnapshot

    private func session(_ id: String, cwd: String? = nil) -> Session {
        Session(
            id: id,
            source: .opencode,
            startTime: Date().addingTimeInterval(-60),
            endTime: Date(),
            model: nil,
            filePath: "/tmp/opencode-hud-tests/\(id).json",
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil
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
        // A focusable (iTerm) presence is kept.
        XCTAssertEqual(snapshotRows(sessions: [], presences: [presence(tty: "/dev/ttys009", pid: 3, termProgram: "iTerm.app")]).count, 1)
        // A non-iTerm TTY-only presence with no workspace match is hidden.
        XCTAssertTrue(snapshotRows(sessions: [], presences: [presence(tty: "/dev/ttys010", pid: 4, termProgram: "Apple_Terminal")]).isEmpty)
    }

    func testWorkspaceMatchResolvesOtherwiseHiddenPresence() {
        let s = session("ses_ws", cwd: "/tmp/opencode-hud-tests/project")
        let rows = snapshotRows(sessions: [s], presences: [
            presence(workspace: "/tmp/opencode-hud-tests/project", tty: "/dev/ttys011", pid: 5, termProgram: "Apple_Terminal")
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.resolvedSessionID, s.id)
    }

    func testCompetingWorkspaceMatchesTakeDistinctSessions() {
        let older = session("ses_old", cwd: "/tmp/opencode-hud-tests/shared")
        let newer = session("ses_new", cwd: "/tmp/opencode-hud-tests/shared")
        let rows = snapshotRows(sessions: [older, newer], presences: [
            presence(workspace: "/tmp/opencode-hud-tests/shared", tty: "/dev/ttys012", pid: 6, termProgram: "Apple_Terminal"),
            presence(workspace: "/tmp/opencode-hud-tests/shared", tty: "/dev/ttys013", pid: 7, termProgram: "Apple_Terminal")
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.resolvedSessionID)).count, 2, "each presence claims its own session")
    }

    func testHeadlessPresenceWithSessionIDIsShown() {
        // Mapper behaviour only: a synthetic no-TTY presence. This is not proof that
        // PresenceEngine discovers real headless processes.
        let rows = snapshotRows(sessions: [], presences: [presence(sessionId: "ses_headless", pid: 42)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.tty)
    }
}
