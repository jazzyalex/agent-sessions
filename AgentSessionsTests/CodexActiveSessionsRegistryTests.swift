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

    func testParsePSEnvironmentOutput_extractsITermSessionID() throws {
        let text = """
          PID   TT  STAT      TIME COMMAND
        66606 s000  S+     4:52.44 /Users/alexm/.npm-global/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex --yolo TERM_PROGRAM=iTerm.app ITERM_SESSION_ID=w0t0p0:ABCDEF TERM_SESSION_ID=w0t0p0:ABCDEF
        """
        let out = CodexActiveSessionsModel.parsePSEnvironmentOutput(text)
        XCTAssertEqual(out[66606]?.termProgram, "iTerm.app")
        XCTAssertEqual(out[66606]?.itermSessionId, "w0t0p0:ABCDEF")
    }
}
