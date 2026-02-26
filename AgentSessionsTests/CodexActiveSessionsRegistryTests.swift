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
}
