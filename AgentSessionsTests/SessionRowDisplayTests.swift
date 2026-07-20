import XCTest
@testable import AgentSessions

/// W7 Task 1 parity pins for the row-body diet: these must stay green across
/// the refactor from per-access allocation to shared/cached/off-main
/// computation. They pin *output*, not implementation — any shape that keeps
/// them green satisfies the task.
final class SessionRowDisplayTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(
        id: String = "session-1",
        source: SessionSource = .codex,
        modifiedStart: Date? = nil,
        modifiedEnd: Date? = nil,
        cwd: String? = nil,
        repoName: String? = nil
    ) -> Session {
        Session(
            id: id,
            source: source,
            startTime: modifiedStart,
            endTime: modifiedEnd,
            model: nil,
            filePath: "/tmp/\(id).jsonl",
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: repoName,
            lightweightTitle: nil
        )
    }

    // MARK: - Step 1: modifiedRelative formatter-reuse parity

    func testModifiedRelativeMatchesFreshFormatterOutput() {
        let date = Date(timeIntervalSinceNow: -3600)
        let s = makeSession(modifiedEnd: date)
        let fresh = RelativeDateTimeFormatter()
        fresh.unitsStyle = .short // matches Session.swift's modifiedRelative config exactly
        XCTAssertEqual(s.modifiedRelative, fresh.localizedString(for: date, relativeTo: Date()))
    }

    func testModifiedRelativeIsStableAcrossRepeatedAccess() {
        let s = makeSession(modifiedEnd: Date(timeIntervalSinceNow: -7200))
        XCTAssertEqual(s.modifiedRelative, s.modifiedRelative)
    }

    func testModifiedRelativeOffMainThreadDoesNotCrash() {
        // SessionTranscriptBuilder.headerLine (off-main, called from
        // SessionTerminalView's Task.detached rebuild) reads modifiedRelative.
        // The shared-formatter refactor must not assume a main-thread caller.
        let s = makeSession(modifiedEnd: Date(timeIntervalSinceNow: -60))
        let expectation = expectation(description: "off-main read completes")
        var result: String?
        DispatchQueue.global(qos: .utility).async {
            result = s.modifiedRelative
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, s.modifiedRelative)
    }

    // MARK: - Step 6b: ProjectPathNormalizer memoization parity

    func testRowRepoNameWorktreePathParity() {
        // MyProject/.worktrees/feature-x — the marker-based heuristic reads the
        // component immediately before ".worktrees" as the project name.
        let s = makeSession(cwd: "/Users/dev/projects/MyProject/.worktrees/feature-x")
        XCTAssertEqual(s.rowRepoName, "MyProject")
        // Repeated access must return the same value (cache correctness).
        XCTAssertEqual(s.rowRepoName, s.rowRepoName)
    }

    func testRowRepoNameHomePathParity() {
        let s = makeSession(cwd: "~/Projects/Sample")
        let expected = s.rowRepoName
        XCTAssertEqual(s.rowRepoName, expected)
    }

    func testRowRepoNameNilCwdParity() {
        let s = makeSession(cwd: nil)
        XCTAssertNil(s.rowRepoName)
        XCTAssertEqual(s.rowRepoDisplay, "—")
    }

    func testRowRepoNameDistinctPathsDoNotCollideInCache() {
        let a = makeSession(id: "a", cwd: "/Users/dev/Repository/ProjectA")
        let b = makeSession(id: "b", cwd: "/Users/dev/Repository/ProjectB")
        XCTAssertNotEqual(a.rowRepoName, b.rowRepoName)
    }

    // MARK: - Step 5: surfacePills static/dynamic split parity

    private func makeClaudeDesktopSession(id: String = "claude-desktop-1") -> Session {
        Session(
            id: id,
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/\(id).jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Claude desktop",
            originator: "Claude Desktop"
        )
    }

    func testStaticSurfacePillsMatchesLegacyWithArchivedFalse() {
        // staticSurfacePills always assumes isClaudeArchived == false; for a
        // non-Claude-Desktop session (unaffected by the flag either way) it must
        // match surfacePills(for:) exactly.
        let s = makeSession(cwd: "/Users/dev/Repo")
        XCTAssertEqual(
            UnifiedSessionsView.staticSurfacePills(for: s).map(\.identity),
            UnifiedSessionsView.surfacePills(for: s).map(\.identity)
        )
    }

    func testApplyingLiveClaudeArchiveStatePatchesArchivedBitOnly() {
        let s = makeClaudeDesktopSession()
        let staticPills = UnifiedSessionsView.staticSurfacePills(for: s)
        XCTAssertEqual(staticPills.map(\.isArchived), [false])

        let patchedLive = UnifiedSessionsView.applyingLiveClaudeArchiveState(
            to: staticPills,
            session: s,
            isClaudeArchived: true
        )
        XCTAssertEqual(patchedLive.map(\.isArchived), [true])
        XCTAssertEqual(patchedLive.map(\.label), ["desk"])

        // Matches what the legacy single-call surfacePills(for:isClaudeArchived:)
        // would have produced directly.
        let legacyDirect = UnifiedSessionsView.surfacePills(for: s, isClaudeArchived: true)
        XCTAssertEqual(patchedLive.map(\.identity), legacyDirect.map(\.identity))
    }

    func testApplyingLiveClaudeArchiveStateNoOpWhenNotArchived() {
        let s = makeClaudeDesktopSession()
        let staticPills = UnifiedSessionsView.staticSurfacePills(for: s)
        let patched = UnifiedSessionsView.applyingLiveClaudeArchiveState(
            to: staticPills,
            session: s,
            isClaudeArchived: false
        )
        XCTAssertEqual(patched.map(\.isArchived), staticPills.map(\.isArchived))
    }

    func testApplyingLiveClaudeArchiveStatePromotesSwitchBranchDesktopPill() {
        // A Claude session can reach [.desktop(isArchived: false)] via the
        // surface == .desktop SWITCH branch of surfacePills -- e.g.
        // originSource "claude-desktop", which claudeDesktopSurfacePill does
        // NOT match -- while isArchivedClaudeDesktop is true via the
        // filename-UUID sidecar join. The legacy single-call
        // surfacePills(for:isClaudeArchived: true) left that pill UNARCHIVED
        // (the parameter was only consulted inside claudeDesktopSurfacePill).
        // The live-patch deliberately diverges and promotes it: an archived
        // session shows the archived pill regardless of which heuristic
        // classified it as Desktop (adjudicated in the 8a3512f0 review; the
        // legacy non-promotion was the bug).
        let s = Session(
            id: "claude-switch-desktop-1",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/claude-switch-desktop-1.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Claude via switch branch",
            originSource: "claude-desktop",
            surface: .desktop
        )
        // Precondition: this shape resolves through the switch branch, not
        // claudeDesktopSurfacePill -- legacy ignores isClaudeArchived here.
        let legacyDirect = UnifiedSessionsView.surfacePills(for: s, isClaudeArchived: true)
        XCTAssertEqual(legacyDirect.map(\.label), ["desk"])
        XCTAssertEqual(legacyDirect.map(\.isArchived), [false], "precondition: legacy switch branch never promoted")

        let staticPills = UnifiedSessionsView.staticSurfacePills(for: s)
        XCTAssertEqual(staticPills.map(\.label), ["desk"])
        XCTAssertEqual(staticPills.map(\.isArchived), [false])

        let patched = UnifiedSessionsView.applyingLiveClaudeArchiveState(
            to: staticPills,
            session: s,
            isClaudeArchived: true
        )
        XCTAssertEqual(patched.map(\.isArchived), [true], "archived session must show the archived pill (new behavior, supersedes legacy)")
        XCTAssertEqual(patched.map(\.identity), ["desk-archived"])
    }

    func testApplyingLiveClaudeArchiveStateNoOpForSideChatSession() {
        // A side-chat session's surfacePills also short-circuits to a bare
        // [.standard(label: "desk", ...)] pill (before claudeDesktopSurfacePill
        // is ever consulted) -- label/isArchived-identical to an unarchived
        // Claude Desktop pill, but must never be promoted to an archived
        // Desktop pill by the live-patch.
        let s = Session(
            id: "side-chat-1",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/side-chat-1.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Side chat",
            parentSessionID: "parent-1",
            relationshipKind: .sideChat
        )
        XCTAssertTrue(s.isSideChat)
        let staticPills = UnifiedSessionsView.staticSurfacePills(for: s)
        XCTAssertEqual(staticPills.map(\.label), ["desk"])
        XCTAssertEqual(staticPills.map(\.isArchived), [false])

        let patched = UnifiedSessionsView.applyingLiveClaudeArchiveState(
            to: staticPills,
            session: s,
            isClaudeArchived: true
        )
        XCTAssertEqual(patched.map(\.isArchived), [false], "a side-chat pill must never be promoted to archived")
        XCTAssertEqual(
            patched.map { $0.accessibilityLabel(agentLabel: "Claude") },
            staticPills.map { $0.accessibilityLabel(agentLabel: "Claude") },
            "patch must be a true no-op for side chats, not just isArchived"
        )
    }

    func testApplyingLiveClaudeArchiveStateNoOpForNonClaudeSession() {
        // A Codex desktop session's "desk" pill must never be patched by the
        // Claude-archive flag, even though the label matches.
        let s = Session(
            id: "codex-desktop-1",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/codex-desktop-1.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Codex desktop",
            codexOriginator: "Codex Desktop",
            codexSurface: .desktop
        )
        let staticPills = UnifiedSessionsView.staticSurfacePills(for: s)
        XCTAssertEqual(staticPills.map(\.isArchived), [false])
        let patched = UnifiedSessionsView.applyingLiveClaudeArchiveState(
            to: staticPills,
            session: s,
            isClaudeArchived: true
        )
        XCTAssertEqual(patched.map(\.isArchived), [false], "isClaudeArchived must not affect a non-Claude session")
    }

    // MARK: - Cowork classification (2026-07-19 cowork labeling)

    private func makeClaudeSession(
        filePath: String,
        source: SessionSource = .claude,
        originator: String? = nil,
        originSource: String? = nil
    ) -> Session {
        Session(
            id: "cowork-test",
            source: source,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: filePath,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            originator: originator,
            originSource: originSource
        )
    }

    private static let coworkTranscriptPath =
        "/Users/test/Library/Application Support/Claude/local-agent-mode-sessions/acct-1/ws-1/local_0b5ef277-1234/.claude/projects/-sessions-outputs/44ebb75a-48e4-4460-9d76-a19c62c10701.jsonl"

    func testIsClaudeCoworkSessionMatchesLocalAgentModePath() {
        // Path-only signal: hydrated sessions have nil originator/originSource.
        let s = makeClaudeSession(filePath: Self.coworkTranscriptPath)
        XCTAssertTrue(s.isClaudeCoworkSession)
    }

    func testIsClaudeCoworkSessionFalseForCodeTabTranscript() {
        // Claude Desktop Code-tab transcript: ~/.claude/projects path, desktop metadata.
        let s = makeClaudeSession(
            filePath: "/Users/test/.claude/projects/-Users-test-Repo/aaaa1111-2222-3333-4444-555566667777.jsonl",
            originator: "Claude Desktop",
            originSource: "claude-desktop"
        )
        XCTAssertFalse(s.isClaudeCoworkSession)
    }

    func testIsClaudeCoworkSessionMatchesOriginSourceFallback() {
        // Freshly-parsed session under a custom root: metadata still identifies it.
        let s = makeClaudeSession(filePath: "/tmp/some-transcript.jsonl", originSource: "local-agent-mode")
        XCTAssertTrue(s.isClaudeCoworkSession)
    }

    func testIsClaudeCoworkSessionFalseForNonClaudeSource() {
        let s = makeClaudeSession(filePath: Self.coworkTranscriptPath, source: .codex)
        XCTAssertFalse(s.isClaudeCoworkSession)
    }

    // MARK: - Cowork surface pill

    func testCoworkSessionGetsCoworkPillNotDeskPill() {
        // Freshly-parsed Cowork session: sidecar enrichment sets originator
        // "Claude Desktop" — the cowork path check must win over that.
        let s = makeClaudeSession(
            filePath: Self.coworkTranscriptPath,
            originator: "Claude Desktop",
            originSource: "local-agent-mode"
        )
        let pills = UnifiedSessionsView.surfacePills(for: s)
        XCTAssertEqual(pills.map(\.label), ["cowork"])
        XCTAssertEqual(pills.map(\.isArchived), [false])
    }

    func testHydratedCoworkSessionWithNilMetadataGetsCoworkPill() {
        // Hydrated-from-DB shape: all surface metadata nil, path is the only signal.
        let s = makeClaudeSession(filePath: Self.coworkTranscriptPath)
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s).map(\.label), ["cowork"])
    }

    func testClaudeCodeTabSessionKeepsDeskPill() {
        let s = makeClaudeSession(
            filePath: "/Users/test/.claude/projects/-Users-test-Repo/aaaa1111-2222-3333-4444-555566667777.jsonl",
            originator: "Claude Desktop"
        )
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s).map(\.label), ["desk"])
    }

    func testApplyingLiveClaudeArchiveStatePromotesCoworkPill() {
        let s = makeClaudeSession(filePath: Self.coworkTranscriptPath)
        let staticPills = UnifiedSessionsView.staticSurfacePills(for: s)
        XCTAssertEqual(staticPills.map(\.label), ["cowork"])
        XCTAssertEqual(staticPills.map(\.isArchived), [false])

        let patched = UnifiedSessionsView.applyingLiveClaudeArchiveState(
            to: staticPills,
            session: s,
            isClaudeArchived: true
        )
        XCTAssertEqual(patched.map(\.label), ["cowork"])
        XCTAssertEqual(patched.map(\.isArchived), [true])

        // Parity with the legacy single-call path.
        let legacyDirect = UnifiedSessionsView.surfacePills(for: s, isClaudeArchived: true)
        XCTAssertEqual(patched.map(\.identity), legacyDirect.map(\.identity))
    }

    // MARK: - Codex work-desktop classification (2026-07-19)

    private func makeCodexSession(
        cwd: String?,
        filePath: String = "/Users/test/.codex/sessions/2026/07/18/rollout-2026-07-18T22-29-02-abc.jsonl",
        source: SessionSource = .codex,
        codexOriginator: String? = nil,
        codexSurface: CodexSessionSurface? = nil
    ) -> Session {
        Session(
            id: "codex-work-test",
            source: source,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: filePath,
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil,
            codexOriginator: codexOriginator,
            codexSurface: codexSurface
        )
    }

    private static let codexWorkCwd = "/Users/test/Documents/Codex/2026-07-18/i-m-attaching-my-site-logo"

    func testIsCodexWorkSessionMatchesDatedWorkspaceCwd() {
        let s = makeCodexSession(cwd: Self.codexWorkCwd)
        XCTAssertTrue(s.isCodexWorkSession)
    }

    func testIsCodexWorkSessionMatchesLocalizedDocumentsPath() {
        // ~/Documents is localizable and can be iCloud-backed, so the check keys
        // on the Codex/<date>/<slug> shape rather than an absolute Documents path.
        let s = makeCodexSession(cwd: "/Users/test/Documentos/Codex/2026-05-19/check-codex-app-github")
        XCTAssertTrue(s.isCodexWorkSession)
    }

    func testIsCodexWorkSessionFalseForOrdinaryRepoCwd() {
        let s = makeCodexSession(cwd: "/Users/test/Repository/Codex-History")
        XCTAssertFalse(s.isCodexWorkSession)
    }

    func testIsCodexWorkSessionFalseWhenDateSegmentIsNotADate() {
        // A directory literally named Codex with a non-date child must not match.
        let s = makeCodexSession(cwd: "/Users/test/Projects/Codex/src/parser")
        XCTAssertFalse(s.isCodexWorkSession)
    }

    func testIsCodexWorkSessionFalseForNonCodexSource() {
        let s = makeCodexSession(cwd: Self.codexWorkCwd, source: .claude)
        XCTAssertFalse(s.isCodexWorkSession)
    }

    func testIsCodexWorkSessionFalseWhenCwdMissing() {
        let s = makeCodexSession(cwd: nil)
        XCTAssertFalse(s.isCodexWorkSession)
    }

    // MARK: - Codex work surface pill

    func testCodexWorkSessionGetsWorkPillNotDeskPill() {
        // Freshly-parsed shape: Codex reports originator "Codex Desktop" and the
        // surface classifier resolves .desktop — the cwd check must win.
        let s = makeCodexSession(
            cwd: Self.codexWorkCwd,
            codexOriginator: "Codex Desktop",
            codexSurface: .desktop
        )
        let pills = UnifiedSessionsView.surfacePills(for: s)
        XCTAssertEqual(pills.map(\.label), ["work"])
        XCTAssertEqual(pills.map(\.isArchived), [false])
    }

    func testHydratedCodexWorkSessionWithNilMetadataGetsWorkPill() {
        // Hydrated-from-DB shape: codexOriginator/codexSurface are NULL, and cwd
        // is the only surviving signal.
        let s = makeCodexSession(cwd: Self.codexWorkCwd)
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s).map(\.label), ["work"])
    }

    func testArchivedCodexWorkSessionGetsArchivedWorkPill() {
        let s = makeCodexSession(
            cwd: Self.codexWorkCwd,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-07-14T11-18-02-abc.jsonl"
        )
        let pills = UnifiedSessionsView.surfacePills(for: s)
        XCTAssertEqual(pills.map(\.label), ["work"])
        XCTAssertEqual(pills.map(\.isArchived), [true])
    }

    func testOrdinaryCodexDesktopSessionKeepsDeskPill() {
        let s = makeCodexSession(
            cwd: "/Users/test/Repository/Codex-History",
            codexOriginator: "Codex Desktop",
            codexSurface: .desktop
        )
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s).map(\.label), ["desk"])
    }
}
