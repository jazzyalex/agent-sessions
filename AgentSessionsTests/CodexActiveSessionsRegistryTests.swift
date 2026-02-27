import XCTest
@testable import AgentSessions

final class CodexActiveSessionsRegistryTests: XCTestCase {
    func testDecodePresence_buildsRevealURLFromITermSessionID() throws {
        let now = Date()
        let nowISO = iso8601(now)

        let json = """
        {
          "schema_version": 1,
          "publisher": "agent-sessions-shim",
          "kind": "interactive",
          "session_id": "abc-123",
          "session_log_path": "/tmp/rollout.jsonl",
          "workspace_root": "/tmp",
          "pid": 123,
          "tty": "/dev/ttys001",
          "started_at": "\(nowISO)",
          "last_seen_at": "\(nowISO)",
          "terminal": {
            "term_program": "iTerm.app",
            "iterm_session_id": "w0t0p0:66920DBE-B426-4370-A1BD-AA0BEAF3A3B6"
          }
        }
        """

        let decoder = CodexActiveSessionsModel.makeDecoder()
        let presence = try decoder.decode(CodexActivePresence.self, from: Data(json.utf8))
        XCTAssertEqual(presence.sessionId, "abc-123")
        XCTAssertEqual(presence.revealURL?.absoluteString, "iterm2:///reveal?sessionid=66920DBE-B426-4370-A1BD-AA0BEAF3A3B6")
    }

    func testLoadPresences_filtersStaleByTTL() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("active-presence-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let now = Date()
        let fresh = now.addingTimeInterval(-1)
        let stale = now.addingTimeInterval(-30)

        try writePresenceJSON(to: dir.appendingPathComponent("as-fresh.json"), lastSeenAt: fresh)
        try writePresenceJSON(to: dir.appendingPathComponent("as-stale.json"), lastSeenAt: stale)

        let decoder = CodexActiveSessionsModel.makeDecoder()
        let loaded = CodexActiveSessionsModel.loadPresences(from: dir, decoder: decoder, now: now, ttl: 10)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.sessionId, "test-session")
        XCTAssertFalse(loaded.first?.isStale(now: now, ttl: 10) ?? true)
    }

    // MARK: - Helpers

    private func writePresenceJSON(to url: URL, lastSeenAt: Date) throws {
        let ts = iso8601(lastSeenAt)
        let json = """
        {
          "schema_version": 1,
          "publisher": "agent-sessions-shim",
          "kind": "interactive",
          "session_id": "test-session",
          "session_log_path": "/tmp/rollout.jsonl",
          "workspace_root": "/tmp",
          "pid": 123,
          "tty": "/dev/ttys001",
          "started_at": "\(ts)",
          "last_seen_at": "\(ts)",
          "terminal": { "term_program": "iTerm.app", "iterm_session_id": "w0t0p0.guid" }
        }
        """
        try Data(json.utf8).write(to: url, options: [.atomic])
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    func testParseLsofMachineOutput_extractsSessionLogAndTTYAndCwd() throws {
        let root = "/Users/alexm/.codex/sessions"
        let text = """
        p123
        fcwd
        tDIR
        n/Users/alexm/Repository/Scripts
        f0
        tCHR
        n/dev/ttys012
        f26w
        tREG
        n/Users/alexm/.codex/sessions/2026/02/09/rollout-2026-02-09T12-34-56-00000000-0000-0000-0000-000000000000.jsonl
        """

        let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [root])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[123]?.cwd, "/Users/alexm/Repository/Scripts")
        XCTAssertEqual(out[123]?.tty, "/dev/ttys012")
        XCTAssertEqual(out[123]?.sessionLogPath, "/Users/alexm/.codex/sessions/2026/02/09/rollout-2026-02-09T12-34-56-00000000-0000-0000-0000-000000000000.jsonl")
    }

    func testParseLsofMachineOutput_keepsTTYOnlySessionWhenNoRolloutOpenYet() throws {
        let root = "/Users/alexm/.codex/sessions"
        let text = """
        p456
        fcwd
        tDIR
        n/Users/alexm/Repository/Codex-History
        f0
        tCHR
        n/dev/ttys099
        """

        let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [root])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[456]?.cwd, "/Users/alexm/Repository/Codex-History")
        XCTAssertEqual(out[456]?.tty, "/dev/ttys099")
        XCTAssertNil(out[456]?.sessionLogPath)
    }

    func testParsePSEnvironmentOutput_extractsITermSessionID() throws {
        let text = """
          PID   TT  STAT      TIME COMMAND
        66606 s000  S+     4:52.44 /Users/alexm/.npm-global/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex --yolo TERM_PROGRAM=iTerm.app ITERM_SESSION_ID=w0t0p0:ABCDEF TERM_SESSION_ID=w0t0p0:ABCDEF
        """
        let out = CodexActiveSessionsModel.parsePSEnvironmentOutput(text)
        XCTAssertEqual(out[66606]?.termProgram, "iTerm.app")
        XCTAssertEqual(out[66606]?.itermSessionId, "w0t0p0:ABCDEF")
    }

    func testParsePSCommandListOutput_parsesPIDTTYAndCommand() {
        let text = """
         4880 ttys013  claude
        46371 ??       /Applications/Claude.app/Contents/MacOS/Claude
         1707 ttys006  node /Users/alexm/.npm-global/bin/codex --yolo
        """

        let out = CodexActiveSessionsModel.parsePSCommandListOutput(text)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].pid, 4880)
        XCTAssertEqual(out[0].tty, "ttys013")
        XCTAssertEqual(out[0].command, "claude")
        XCTAssertEqual(out[1].pid, 46371)
        XCTAssertNil(out[1].tty)
        XCTAssertEqual(out[2].pid, 1707)
        XCTAssertEqual(out[2].tty, "ttys006")
        XCTAssertEqual(out[2].command, "node /Users/alexm/.npm-global/bin/codex --yolo")
    }

    func testCommandContainsNeedle_matchesExecutableTokensOnly() {
        XCTAssertTrue(CodexActiveSessionsModel.commandContainsNeedle(
            "node /Users/alexm/.local/bin/claude --verbose",
            needles: ["claude"]
        ))
        XCTAssertTrue(CodexActiveSessionsModel.commandContainsNeedle(
            "opencode --project .",
            needles: ["opencode"]
        ))
        XCTAssertFalse(CodexActiveSessionsModel.commandContainsNeedle(
            "/Applications/Claude.app/Contents/MacOS/Claude",
            needles: ["opencode"]
        ))
        XCTAssertFalse(CodexActiveSessionsModel.commandContainsNeedle(
            "python -m http.server",
            needles: ["claude"]
        ))
        XCTAssertFalse(CodexActiveSessionsModel.commandContainsNeedle(
            "vim opencode",
            needles: ["opencode"]
        ))
        XCTAssertFalse(CodexActiveSessionsModel.commandContainsNeedle(
            "zsh -lc \"vim claude_notes.md\"",
            needles: ["claude"]
        ))
        XCTAssertTrue(CodexActiveSessionsModel.commandContainsNeedle(
            "zsh -lc \"claude --resume 123\"",
            needles: ["claude"]
        ))
        XCTAssertTrue(CodexActiveSessionsModel.commandContainsNeedle(
            "env TERM_PROGRAM=iTerm.app /opt/homebrew/bin/opencode --continue",
            needles: ["opencode"]
        ))
        XCTAssertTrue(CodexActiveSessionsModel.commandContainsNeedle(
            "pnpm dlx opencode --continue",
            needles: ["opencode"]
        ))
        XCTAssertTrue(CodexActiveSessionsModel.commandContainsNeedle(
            "npm exec claude -- --resume abc",
            needles: ["claude"]
        ))
        XCTAssertTrue(CodexActiveSessionsModel.commandContainsNeedle(
            "yarn dlx opencode --project .",
            needles: ["opencode"]
        ))
    }

    func testUnifiedFallbackClaimedPresence_assignsByPresenceCountForSameWorkspaceSessions() {
        let cwd = "/Users/alexm/Repository/Codex-History"
        let now = Date()
        let sessions = [
            makeFallbackSession(id: "oldest", source: .claude, cwd: cwd, modifiedAt: now.addingTimeInterval(-120)),
            makeFallbackSession(id: "older", source: .claude, cwd: cwd, modifiedAt: now.addingTimeInterval(-60)),
            makeFallbackSession(id: "newest", source: .claude, cwd: cwd, modifiedAt: now)
        ]
        let fallbackPresences = [
            makeFallbackPresence(source: .claude, lastSeenAt: now, workspaceRoot: cwd, tty: "/dev/ttys010", pid: 1010),
            makeFallbackPresence(source: .claude, lastSeenAt: now.addingTimeInterval(-5), workspaceRoot: cwd, tty: "/dev/ttys011", pid: 1011)
        ]

        XCTAssertNotNil(UnifiedSessionsView.fallbackClaimedPresence(for: sessions[2], among: sessions, using: fallbackPresences))
        XCTAssertNotNil(UnifiedSessionsView.fallbackClaimedPresence(for: sessions[1], among: sessions, using: fallbackPresences))
        XCTAssertNil(UnifiedSessionsView.fallbackClaimedPresence(for: sessions[0], among: sessions, using: fallbackPresences))
    }

    func testUnifiedFallbackClaimedPresence_supportsMultipleUnresolvedPresences() {
        let now = Date()
        let sessions = [
            makeFallbackSession(id: "oldest", source: .opencode, cwd: nil, modifiedAt: now.addingTimeInterval(-200)),
            makeFallbackSession(id: "older", source: .opencode, cwd: nil, modifiedAt: now.addingTimeInterval(-100)),
            makeFallbackSession(id: "newest", source: .opencode, cwd: nil, modifiedAt: now)
        ]
        let unresolved = [
            makeFallbackPresence(source: .opencode, lastSeenAt: now, workspaceRoot: nil, tty: "/dev/ttys020", pid: 2020),
            makeFallbackPresence(source: .opencode, lastSeenAt: now.addingTimeInterval(-10), workspaceRoot: nil, tty: "/dev/ttys021", pid: 2021)
        ]

        XCTAssertNotNil(UnifiedSessionsView.fallbackClaimedPresence(for: sessions[2], among: sessions, using: unresolved))
        XCTAssertNotNil(UnifiedSessionsView.fallbackClaimedPresence(for: sessions[1], among: sessions, using: unresolved))
        XCTAssertNil(UnifiedSessionsView.fallbackClaimedPresence(for: sessions[0], among: sessions, using: unresolved))
    }

    func testUnifiedFallbackEligibleSessions_excludesDirectJoinRowsFromRankMatching() {
        let now = Date()
        let direct = makeFallbackSession(id: "direct", source: .claude, cwd: nil, modifiedAt: now)
        let unresolved = makeFallbackSession(id: "unresolved", source: .claude, cwd: nil, modifiedAt: now.addingTimeInterval(-60))
        let sessions = [direct, unresolved]
        let presence = makeFallbackPresence(
            source: .claude,
            lastSeenAt: now,
            workspaceRoot: nil,
            tty: "/dev/ttys022",
            pid: 2022
        )

        XCTAssertNil(UnifiedSessionsView.fallbackClaimedPresence(for: unresolved, among: sessions, using: [presence]))

        let eligible = UnifiedSessionsView.fallbackEligibleSessions(from: sessions) { session in
            session.id == "direct"
        }
        XCTAssertEqual(eligible.map(\.id), ["unresolved"])
        XCTAssertNotNil(UnifiedSessionsView.fallbackClaimedPresence(for: unresolved, among: eligible, using: [presence]))
    }

    func testBuildFallbackPresenceMap_assignsWorkspaceFallbackToNewestEligibleSession() {
        let now = Date()
        let cwd = "/Users/alexm/Repository/Codex-History"
        let sessions = [
            makeFallbackSession(id: "older", source: .claude, cwd: cwd, modifiedAt: now.addingTimeInterval(-30)),
            makeFallbackSession(id: "newest", source: .claude, cwd: cwd, modifiedAt: now)
        ]
        let workspacePresence = makeFallbackPresence(
            source: .claude,
            lastSeenAt: now,
            workspaceRoot: cwd,
            tty: "/dev/ttys101",
            pid: 1101
        )

        let map = UnifiedSessionsView.buildFallbackPresenceMap(
            sessions: sessions,
            presences: [workspacePresence],
            hasDirectJoin: { _ in false }
        )

        let newestKey = UnifiedSessionsView.fallbackPresenceKey(source: .claude, sessionID: "newest")
        let olderKey = UnifiedSessionsView.fallbackPresenceKey(source: .claude, sessionID: "older")
        XCTAssertNotNil(map[newestKey])
        XCTAssertNil(map[olderKey])
    }

    func testBuildFallbackPresenceMap_unresolvedFallbackSkipsDirectJoinAndUsesRemainingSessions() {
        let now = Date()
        let sessions = [
            makeFallbackSession(id: "direct", source: .opencode, cwd: nil, modifiedAt: now),
            makeFallbackSession(id: "fallback", source: .opencode, cwd: nil, modifiedAt: now.addingTimeInterval(-5))
        ]
        let unresolvedPresence = makeFallbackPresence(
            source: .opencode,
            lastSeenAt: now,
            workspaceRoot: nil,
            tty: "/dev/ttys202",
            pid: 2202
        )

        let map = UnifiedSessionsView.buildFallbackPresenceMap(
            sessions: sessions,
            presences: [unresolvedPresence],
            hasDirectJoin: { $0.id == "direct" }
        )

        let directKey = UnifiedSessionsView.fallbackPresenceKey(source: .opencode, sessionID: "direct")
        let fallbackKey = UnifiedSessionsView.fallbackPresenceKey(source: .opencode, sessionID: "fallback")
        XCTAssertNil(map[directKey])
        XCTAssertNotNil(map[fallbackKey])
    }

    func testBuildFallbackPresenceMap_keepsSourceScopedEntriesWhenSessionIDsCollide() {
        let now = Date()
        let sharedID = "shared-session-id"
        let sessions = [
            makeFallbackSession(id: sharedID, source: .claude, cwd: nil, modifiedAt: now),
            makeFallbackSession(id: sharedID, source: .opencode, cwd: nil, modifiedAt: now)
        ]
        let claudePresence = makeFallbackPresence(
            source: .claude,
            lastSeenAt: now,
            workspaceRoot: nil,
            tty: "/dev/ttys301",
            pid: 3301
        )
        let openCodePresence = makeFallbackPresence(
            source: .opencode,
            lastSeenAt: now,
            workspaceRoot: nil,
            tty: "/dev/ttys302",
            pid: 3302
        )

        let map = UnifiedSessionsView.buildFallbackPresenceMap(
            sessions: sessions,
            presences: [claudePresence, openCodePresence],
            hasDirectJoin: { _ in false }
        )

        let claudeKey = UnifiedSessionsView.fallbackPresenceKey(source: .claude, sessionID: sharedID)
        let openCodeKey = UnifiedSessionsView.fallbackPresenceKey(source: .opencode, sessionID: sharedID)
        XCTAssertEqual(map[claudeKey]?.source, .claude)
        XCTAssertEqual(map[openCodeKey]?.source, .opencode)
    }

    func testParseLsofMachineOutput_matchesClaudeSessionFilesAndSkipsHistory() {
        let root = "/Users/alexm/.claude"
        let text = """
        p777
        fcwd
        tDIR
        n/Users/alexm/Repository/Codex-History
        f0
        tCHR
        n/dev/ttys021
        f31w
        tREG
        n/Users/alexm/.claude/history.jsonl
        f32w
        tREG
        n/Users/alexm/.claude/projects/-Users-alexm-Repository-Codex-History/90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a.jsonl
        """

        let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [root], source: .claude)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[777]?.tty, "/dev/ttys021")
        XCTAssertEqual(
            out[777]?.sessionLogPath,
            "/Users/alexm/.claude/projects/-Users-alexm-Repository-Codex-History/90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a.jsonl"
        )
        XCTAssertEqual(out[777]?.sessionID, "90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a")
    }

    func testParseLsofMachineOutput_extractsOpenCodeSessionIDFromSessionPath() {
        let root = "/Users/alexm/.local/share/opencode/storage/session"
        let text = """
        p888
        fcwd
        tDIR
        n/Users/alexm/Repository/Codex-History
        f0
        tCHR
        n/dev/ttys031
        f27w
        tREG
        n/Users/alexm/.local/share/opencode/storage/session/proj_test/ses_s_stage0_small.json
        """

        let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [root], source: .opencode)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[888]?.tty, "/dev/ttys031")
        XCTAssertEqual(out[888]?.sessionID, "s_stage0_small")
        XCTAssertEqual(
            out[888]?.sessionLogPath,
            "/Users/alexm/.local/share/opencode/storage/session/proj_test/ses_s_stage0_small.json"
        )
    }

    func testParseLsofMachineOutput_matchesClaudeSessionWhenRootNormalizationDiffers() throws {
        let lexicalRoot = URL(fileURLWithPath: "/var/tmp", isDirectory: true).standardized.path
        let canonicalRoot = URL(fileURLWithPath: "/var/tmp", isDirectory: true).standardizedFileURL.path
        guard lexicalRoot != canonicalRoot else {
            throw XCTSkip("No root normalization difference for /var/tmp on this runtime.")
        }

        let sessionLog = "\(canonicalRoot)/projects/proj/90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a.jsonl"
        let text = """
        p999
        fcwd
        tDIR
        n\(canonicalRoot)
        f0
        tCHR
        n/dev/ttys041
        f27w
        tREG
        n\(sessionLog)
        """

        let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [lexicalRoot], source: .claude)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[999]?.sessionLogPath, sessionLog)
        XCTAssertEqual(out[999]?.sessionID, "90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a")
    }

    func testParseITermSessionListOutput_parsesSessionRows() {
        let text = """
        349331C2-4268-4AEB-BD48-83342A767CF2\t/dev/ttys006\tAS-CX II (codex)
        75A64ABD-FF8F-44C8-A1CE-4225F536D7E3\t/dev/ttys010\t-zsh
        03167519-C7CD-4109-8999-641F9A8085E1tab/dev/ttys014tabcodex
        """

        let out = CodexActiveSessionsModel.parseITermSessionListOutput(text)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].sessionID, "349331C2-4268-4AEB-BD48-83342A767CF2")
        XCTAssertEqual(out[0].tty, "/dev/ttys006")
        XCTAssertEqual(out[0].name, "AS-CX II (codex)")
        XCTAssertEqual(out[1].sessionID, "75A64ABD-FF8F-44C8-A1CE-4225F536D7E3")
        XCTAssertEqual(out[1].name, "-zsh")
        XCTAssertEqual(out[2].sessionID, "03167519-C7CD-4109-8999-641F9A8085E1")
        XCTAssertEqual(out[2].tty, "/dev/ttys014")
        XCTAssertEqual(out[2].name, "codex")
    }

    func testIsLikelyCodexITermSessionName_matchesExpectedTabNames() {
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyCodexITermSessionName("codex"))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyCodexITermSessionName("AS-CX II (codex)"))
        XCTAssertFalse(CodexActiveSessionsModel.isLikelyCodexITermSessionName("-zsh"))
        XCTAssertFalse(CodexActiveSessionsModel.isLikelyCodexITermSessionName("Codex-History"))
    }

    func testIsLikelyITermSessionName_matchesClaudeAndOpenCodeNames() {
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyITermSessionName("Claude", source: .claude))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyITermSessionName("opencode", source: .opencode))
        XCTAssertFalse(CodexActiveSessionsModel.isLikelyITermSessionName("zsh", source: .claude))
        XCTAssertFalse(CodexActiveSessionsModel.isLikelyITermSessionName("workspace shell", source: .opencode))
    }

    func testLiveSessionIDCandidates_extractsClaudeRuntimeUUIDFromPath() {
        let session = Session(
            id: "hashed-path-id",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/alexm/.claude/projects/proj/90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a.jsonl",
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil
        )

        let ids = CodexActiveSessionsModel.liveSessionIDCandidates(for: session)
        XCTAssertEqual(ids, ["90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a"])
    }

    func testLiveSessionIDCandidates_prefersClaudeRuntimeHintOverPathHashID() {
        let session = Session(
            id: "hashed-path-id",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/alexm/.claude/projects/proj/90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a.jsonl",
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            codexInternalSessionIDHint: "live-uuid-from-log"
        )

        let ids = CodexActiveSessionsModel.liveSessionIDCandidates(for: session)
        XCTAssertEqual(ids.first, "live-uuid-from-log")
        XCTAssertTrue(ids.contains("90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a"))
        XCTAssertFalse(ids.contains("hashed-path-id"))
    }

    func testNormalizePath_trimsAndStandardizesPath() {
        let path = "  ~/tmp/./sessions/../rollout.jsonl  "
        let normalized = CodexActiveSessionsModel.normalizePath(path)
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tmp/rollout.jsonl")
            .standardizedFileURL
            .path
        XCTAssertEqual(normalized, expected)

        // Second call should return the same normalized value.
        XCTAssertEqual(CodexActiveSessionsModel.normalizePath(path), expected)
    }

    func testNormalizePath_resolvesKnownSymlinkedRoots() throws {
        let symlinkedPath = "/var/tmp"
        let lexical = URL(fileURLWithPath: symlinkedPath, isDirectory: true).standardized.path
        let canonical = URL(fileURLWithPath: symlinkedPath, isDirectory: true).standardizedFileURL.path
        guard lexical != canonical else {
            throw XCTSkip("No symlink canonicalization difference for /var/tmp on this runtime.")
        }
        XCTAssertEqual(CodexActiveSessionsModel.normalizePath(symlinkedPath), canonical)
    }

    func testNormalizePath_emptyInputReturnsEmptyString() {
        XCTAssertEqual(CodexActiveSessionsModel.normalizePath(""), "")
        XCTAssertEqual(CodexActiveSessionsModel.normalizePath("   \n\t "), "")
    }

    func testCanAttemptITerm2Focus_allowsTTYWhenTermProgramUnavailable() {
        XCTAssertTrue(CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: nil,
            tty: "/dev/ttys012",
            termProgram: nil
        ))
    }

    func testCanAttemptITerm2Focus_rejectsKnownNonITermTerminal() {
        XCTAssertFalse(CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: nil,
            tty: "/dev/ttys012",
            termProgram: "Apple_Terminal"
        ))
    }

    func testCanAttemptITerm2TailProbe_allowsTTYForTmux() {
        XCTAssertTrue(CodexActiveSessionsModel.canAttemptITerm2TailProbe(
            itermSessionId: nil,
            tty: "/dev/ttys012",
            termProgram: "tmux"
        ))
    }

    func testCanAttemptITerm2TailProbe_allowsTTYForKnownNonITermTerminal() {
        XCTAssertTrue(CodexActiveSessionsModel.canAttemptITerm2TailProbe(
            itermSessionId: nil,
            tty: "/dev/ttys012",
            termProgram: "Apple_Terminal"
        ))
    }

    func testCanAttemptITerm2TailProbe_rejectsWhenNoTTYAndNoGUID() {
        XCTAssertFalse(CodexActiveSessionsModel.canAttemptITerm2TailProbe(
            itermSessionId: nil,
            tty: nil,
            termProgram: "tmux"
        ))
    }

    func testCanAttemptITerm2TailProbe_allowsGUIDWithoutTTY() {
        XCTAssertTrue(CodexActiveSessionsModel.canAttemptITerm2TailProbe(
            itermSessionId: "w0t0p0:ABCDEF",
            tty: nil,
            termProgram: "Apple_Terminal"
        ))
    }

    func testClassifyITermTail_detectsActiveWorkingMarkers() {
        let tail = """
        • The bridge-session run is still active with CPU usage
        Waiting for background terminal . python3 scripts/build_report.py
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyITermTail(tail), .activeWorking)
    }

    func testClassifyITermTail_detectsOpenIdlePrompt() {
        let tail = """
        Explain this codebase
        ›
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyITermTail(tail), .openIdle)
    }

    func testClassifyITermTail_usesLastLinePromptNotHistoricalPrompt() {
        let tail = """
        › previous prompt
        • Working for 12s
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyITermTail(tail), .activeWorking)
    }

    func testClassifyITermTail_nonPromptTailDefaultsToOpenIdle() {
        let tail = """
        Analyzing files...
        Fetching status...
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyITermTail(tail), .openIdle)
    }

    func testClassifyITermTail_historicalWorkedForDoesNotForceActive() {
        let tail = """
        — Worked for 1m 14s —

        › Explain this codebase
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyITermTail(tail), .openIdle)
    }

    @MainActor
    func testCoalescePresencesByTTY_preservesDistinctSessionsOnSameTTY() {
        var first = CodexActivePresence()
        first.sessionId = "sid-a"
        first.sessionLogPath = "/tmp/rollout-a.jsonl"
        first.tty = "/dev/ttys011"
        first.pid = 101
        first.lastSeenAt = Date()

        var second = CodexActivePresence()
        second.sessionId = "sid-b"
        second.sessionLogPath = "/tmp/rollout-b.jsonl"
        second.tty = "/dev/ttys011"
        second.pid = 202
        second.lastSeenAt = Date()

        let out = CodexActiveSessionsModel.coalescePresencesByTTY([first, second])

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.compactMap(\.sessionId)), Set(["sid-a", "sid-b"]))
    }

    @MainActor
    func testCoalescePresencesByTTY_mergesDuplicateIdentityOnSameTTY() {
        var processPresence = CodexActivePresence()
        processPresence.sessionId = "sid-a"
        processPresence.sessionLogPath = "/tmp/rollout-a.jsonl"
        processPresence.tty = "/dev/ttys011"
        processPresence.pid = 101
        processPresence.publisher = "agent-sessions-process"
        processPresence.lastSeenAt = Date()

        var registryPresence = CodexActivePresence()
        registryPresence.sessionId = "sid-a"
        registryPresence.sessionLogPath = "/tmp/rollout-a.jsonl"
        registryPresence.tty = "/dev/ttys011"
        registryPresence.publisher = "agent-sessions-shim"
        registryPresence.sourceFilePath = "/tmp/as-registry.json"
        registryPresence.lastSeenAt = Date()

        let out = CodexActiveSessionsModel.coalescePresencesByTTY([processPresence, registryPresence])

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.sessionId, "sid-a")
        XCTAssertEqual(out.first?.tty, "/dev/ttys011")
    }

    @MainActor
    func testReconcileFallbackPresences_mergesTTYOnlyITermFallbackIntoKeyedRow() {
        var keyed = CodexActivePresence()
        keyed.sessionId = "sid-a"
        keyed.sessionLogPath = "/tmp/rollout-a.jsonl"
        keyed.tty = "/dev/ttys011"
        keyed.publisher = "agent-sessions-process"
        keyed.lastSeenAt = Date()

        var ttyOnlyITerm = CodexActivePresence()
        ttyOnlyITerm.publisher = "agent-sessions-iterm"
        ttyOnlyITerm.tty = "/dev/ttys011"
        ttyOnlyITerm.lastSeenAt = Date()
        var terminal = CodexActivePresence.Terminal()
        terminal.termProgram = "iTerm2"
        terminal.itermSessionId = "ABC-123"
        ttyOnlyITerm.terminal = terminal

        let out = CodexActiveSessionsModel.reconcileFallbackPresences([ttyOnlyITerm], into: [keyed])

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.sessionId, "sid-a")
        XCTAssertEqual(out.first?.terminal?.itermSessionId, "ABC-123")
    }

    @MainActor
    func testReconcileFallbackPresences_keepsTTYOnlyITermFallbackWhenNoTTYMatch() {
        var keyed = CodexActivePresence()
        keyed.sessionId = "sid-a"
        keyed.sessionLogPath = "/tmp/rollout-a.jsonl"
        keyed.tty = "/dev/ttys011"
        keyed.publisher = "agent-sessions-process"
        keyed.lastSeenAt = Date()

        var ttyOnlyITerm = CodexActivePresence()
        ttyOnlyITerm.publisher = "agent-sessions-iterm"
        ttyOnlyITerm.tty = "/dev/ttys099"
        ttyOnlyITerm.lastSeenAt = Date()

        let out = CodexActiveSessionsModel.reconcileFallbackPresences([ttyOnlyITerm], into: [keyed])

        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.contains { $0.sessionId == "sid-a" })
        XCTAssertTrue(out.contains { $0.publisher == "agent-sessions-iterm" && $0.tty == "/dev/ttys099" })
    }

    func testHeuristicLiveStateFromLogMTime_recentWriteIsActive() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("as-live-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("rollout-test.jsonl")
        try Data("{}".utf8).write(to: file)

        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-0.6)], ofItemAtPath: file.path)

        XCTAssertEqual(
            CodexActiveSessionsModel.heuristicLiveStateFromLogMTime(
                logPath: file.path,
                now: now,
                activeWriteWindow: 2.5
            ),
            .activeWorking
        )
    }

    func testHeuristicLiveStateFromLogMTime_staleWriteIsOpen() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("as-live-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("rollout-test.jsonl")
        try Data("{}".utf8).write(to: file)

        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-15)], ofItemAtPath: file.path)

        XCTAssertEqual(
            CodexActiveSessionsModel.heuristicLiveStateFromLogMTime(
                logPath: file.path,
                now: now,
                activeWriteWindow: 2.5
            ),
            .openIdle
        )
    }

    func testCockpitUnresolvedPlaceholder_hidesSourceFileOnlyPresence() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.publisher = "agent-sessions-shim"
        presence.kind = "subagent"
        presence.sourceFilePath = "/Users/alexm/.codex/active/subagent.json"

        XCTAssertTrue(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_hidesSubagentEvenWithSessionID() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.publisher = "agent-sessions-shim"
        presence.kind = "subagent"
        presence.sessionId = "sid-subagent"

        XCTAssertTrue(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_hidesSubagentEvenWithLogPath() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.publisher = "agent-sessions-shim"
        presence.kind = "subagent"
        presence.sessionLogPath = "/tmp/subagent-rollout.jsonl"

        XCTAssertTrue(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_keepsFocusableTTYPresence() {
        var presence = CodexActivePresence()
        presence.source = .claude
        presence.publisher = "agent-sessions-shim"
        presence.tty = "/dev/ttys011"

        XCTAssertFalse(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    private func makeFallbackSession(id: String,
                                     source: SessionSource,
                                     cwd: String?,
                                     modifiedAt: Date) -> Session {
        Session(
            id: id,
            source: source,
            startTime: modifiedAt.addingTimeInterval(-10),
            endTime: modifiedAt,
            model: nil,
            filePath: "/tmp/\(id).jsonl",
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil
        )
    }

    private func makeFallbackPresence(source: SessionSource,
                                      lastSeenAt: Date,
                                      workspaceRoot: String?,
                                      tty: String?,
                                      pid: Int?) -> CodexActivePresence {
        var p = CodexActivePresence()
        p.source = source
        p.lastSeenAt = lastSeenAt
        p.workspaceRoot = workspaceRoot
        p.tty = tty
        p.pid = pid
        return p
    }
}
