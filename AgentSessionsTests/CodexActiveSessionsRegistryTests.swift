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

    func testClassifyITermTail_nonPromptTailDefaultsToActiveWorking() {
        let tail = """
        Analyzing files...
        Fetching status...
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyITermTail(tail), .activeWorking)
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
