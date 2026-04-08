import XCTest
import AppKit
import SwiftUI
import SQLite3
@testable import AgentSessions

final class CodexActiveSessionsRegistryTests: XCTestCase {
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    func testParseLsofMachineOutput_prefersLowestFDAndDeduplicatesOpenLogPaths() {
        let root = "/Users/alexm/.codex/sessions"
        let parentLog = "/Users/alexm/.codex/sessions/2026/03/28/rollout-2026-03-28T10-00-00-00000000-0000-0000-0000-000000000001.jsonl"
        let childLog = "/Users/alexm/.codex/sessions/2026/03/28/rollout-2026-03-28T10-01-00-00000000-0000-0000-0000-000000000002.jsonl"
        let text = """
        p789
        fcwd
        tDIR
        n/Users/alexm/Repository/Codex-History
        f0
        tCHR
        n/dev/ttys077
        f42w
        tREG
        n\(childLog)
        f40w
        tREG
        n\(parentLog)
        f55w
        tREG
        n\(parentLog)
        """

        let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [root])

        XCTAssertEqual(out[789]?.sessionLogPath, parentLog)
        XCTAssertEqual(out[789]?.sessionLogFD, 40)
        XCTAssertEqual(out[789]?.openSessionLogPaths, [childLog, parentLog])
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
            makeFallbackSession(id: "oldest", source: .claude, cwd: nil, modifiedAt: now.addingTimeInterval(-200)),
            makeFallbackSession(id: "older", source: .claude, cwd: nil, modifiedAt: now.addingTimeInterval(-100)),
            makeFallbackSession(id: "newest", source: .claude, cwd: nil, modifiedAt: now)
        ]
        let unresolved = [
            makeFallbackPresence(source: .claude, lastSeenAt: now, workspaceRoot: nil, tty: "/dev/ttys020", pid: 2020),
            makeFallbackPresence(source: .claude, lastSeenAt: now.addingTimeInterval(-10), workspaceRoot: nil, tty: "/dev/ttys021", pid: 2021)
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

    func testBuildFallbackPresenceMap_assignsDistinctWorkspacePresencesAcrossSameWorkspaceSessions() {
        let now = Date()
        let cwd = "/Users/alexm/Repository/Triada"
        let sessions = [
            makeFallbackSession(id: "older", source: .claude, cwd: cwd, modifiedAt: now.addingTimeInterval(-60)),
            makeFallbackSession(id: "newest", source: .claude, cwd: cwd, modifiedAt: now)
        ]
        let newestPresence = makeFallbackPresence(
            source: .claude,
            lastSeenAt: now,
            workspaceRoot: cwd,
            tty: "/dev/ttys012",
            pid: 12012
        )
        let olderPresence = makeFallbackPresence(
            source: .claude,
            lastSeenAt: now.addingTimeInterval(-5),
            workspaceRoot: cwd,
            tty: "/dev/ttys013",
            pid: 12013
        )

        let map = UnifiedSessionsView.buildFallbackPresenceMap(
            sessions: sessions,
            presences: [olderPresence, newestPresence],
            hasDirectJoin: { _ in false }
        )

        let newestKey = UnifiedSessionsView.fallbackPresenceKey(source: .claude, sessionID: "newest")
        let olderKey = UnifiedSessionsView.fallbackPresenceKey(source: .claude, sessionID: "older")
        XCTAssertEqual(map[newestKey]?.pid, 12012)
        XCTAssertEqual(map[olderKey]?.pid, 12013)
    }

    func testBuildFallbackPresenceMap_unresolvedFallbackSkipsDirectJoinAndUsesRemainingSessions() {
        let now = Date()
        let sessions = [
            makeFallbackSession(id: "direct", source: .claude, cwd: nil, modifiedAt: now),
            makeFallbackSession(id: "fallback", source: .claude, cwd: nil, modifiedAt: now.addingTimeInterval(-5))
        ]
        let unresolvedPresence = makeFallbackPresence(
            source: .claude,
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

        let directKey = UnifiedSessionsView.fallbackPresenceKey(source: .claude, sessionID: "direct")
        let fallbackKey = UnifiedSessionsView.fallbackPresenceKey(source: .claude, sessionID: "fallback")
        XCTAssertNil(map[directKey])
        XCTAssertNotNil(map[fallbackKey])
    }

    func testBuildFallbackPresenceMap_supportsClaudeAndOpenCodeSources() {
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

    func testClaudeSessionDiscoveredViaPIDBasedLsofQuery() {
        // Simulates the output from `lsof -p {PID}` (the ps fallback path),
        // NOT from `lsof -c claude` (which returns nothing because Claude Code
        // sets process.title to its version string).
        let root = "/Users/test/.claude"
        let text = """
        p42001
        fcwd
        tDIR
        n/Users/test/Repository/MyProject
        f0
        tCHR
        n/dev/ttys015
        f26w
        tREG
        n/Users/test/.claude/projects/-Users-test-Repository-MyProject/abc12345-6789-abcd-ef01-234567890abc.jsonl
        """

        let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [root], source: .claude)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[42001]?.cwd, "/Users/test/Repository/MyProject")
        XCTAssertEqual(out[42001]?.tty, "/dev/ttys015")
        XCTAssertEqual(
            out[42001]?.sessionLogPath,
            "/Users/test/.claude/projects/-Users-test-Repository-MyProject/abc12345-6789-abcd-ef01-234567890abc.jsonl"
        )
        XCTAssertEqual(out[42001]?.sessionID, "abc12345-6789-abcd-ef01-234567890abc")
    }

    func testClaudeSessionLogCandidates_returnsNewestFirst() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectDir = tmp.appendingPathComponent("projects/-Users-test-MyProject")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create three JSONL files with different modification times
        let oldFile = projectDir.appendingPathComponent("aaaa1111-0000-0000-0000-000000000001.jsonl")
        let midFile = projectDir.appendingPathComponent("bbbb2222-0000-0000-0000-000000000002.jsonl")
        let newFile = projectDir.appendingPathComponent("cccc3333-0000-0000-0000-000000000003.jsonl")
        // Also a non-JSONL file and history.jsonl that should be excluded
        let txtFile = projectDir.appendingPathComponent("notes.txt")
        let historyFile = projectDir.appendingPathComponent("history.jsonl")

        for file in [oldFile, midFile, newFile, txtFile, historyFile] {
            try Data("{}".utf8).write(to: file)
        }

        // Set modification times: old < mid < new
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: midFile.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newFile.path)

        let candidates = CodexActiveSessionsModel.claudeSessionLogCandidates(
            cwd: "/Users/test/MyProject",
            claudeRoot: tmp.path
        )

        // Should return 3 candidates (excluding .txt and history.jsonl), newest first.
        // Standardize paths to handle /var → /private/var symlinks on macOS.
        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(candidates[0].path.hasSuffix("cccc3333-0000-0000-0000-000000000003.jsonl"))
        XCTAssertEqual(candidates[0].sessionID, "cccc3333-0000-0000-0000-000000000003")
        XCTAssertTrue(candidates[1].path.hasSuffix("bbbb2222-0000-0000-0000-000000000002.jsonl"))
        XCTAssertTrue(candidates[2].path.hasSuffix("aaaa1111-0000-0000-0000-000000000001.jsonl"))
    }

    func testClaudeSessionLogCandidates_returnsEmptyForMissingDir() {
        let candidates = CodexActiveSessionsModel.claudeSessionLogCandidates(
            cwd: "/nonexistent/path",
            claudeRoot: "/nonexistent/root"
        )
        XCTAssertTrue(candidates.isEmpty)
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
        XCTAssertEqual(out[0].displayName, "AS-CX II (codex)")
        XCTAssertEqual(out[1].sessionID, "75A64ABD-FF8F-44C8-A1CE-4225F536D7E3")
        XCTAssertEqual(out[1].name, "-zsh")
        XCTAssertEqual(out[1].displayName, "-zsh")
        XCTAssertEqual(out[2].sessionID, "03167519-C7CD-4109-8999-641F9A8085E1")
        XCTAssertEqual(out[2].tty, "/dev/ttys014")
        XCTAssertEqual(out[2].name, "codex")
        XCTAssertEqual(out[2].displayName, "codex")
    }

    func testParseITermSessionListOutput_fallsBackToWindowNameWhenSessionNameEmpty() {
        let text = """
        11111111-1111-1111-1111-111111111111\t/dev/ttys001\t\tCodex Window
        22222222-2222-2222-2222-222222222222tab/dev/ttys002tabtabClaude Window
        """

        let out = CodexActiveSessionsModel.parseITermSessionListOutput(text)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].sessionID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(out[0].name, "Codex Window")
        XCTAssertEqual(out[0].displayName, "Codex Window")
        XCTAssertEqual(out[1].sessionID, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(out[1].name, "Claude Window")
        XCTAssertEqual(out[1].displayName, "Claude Window")
    }

    func testParseITermSessionListOutput_prefersCustomTabOrWindowDisplayName() {
        let text = """
        AAAA1111-1111-1111-1111-111111111111\t/dev/ttys021\tcodex\tTennis - CX\tTennis
        BBBB2222-2222-2222-2222-222222222222\t/dev/ttys022\tcodex\tcodex\tTennis
        """

        let out = CodexActiveSessionsModel.parseITermSessionListOutput(text)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].name, "codex")
        XCTAssertEqual(out[0].displayName, "Tennis - CX")
        XCTAssertEqual(out[1].name, "codex")
        XCTAssertEqual(out[1].displayName, "Tennis")
    }

    func testParseITermSessionListOutput_usesTabTitleWhenWindowTitleEmpty() {
        let text = "EEEE5555-2222-2222-2222-222222222222\t/dev/ttys025\tcodex\tSCRIPTS - CX\t"
        let out = CodexActiveSessionsModel.parseITermSessionListOutput(text)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].name, "codex")
        XCTAssertEqual(out[0].displayName, "SCRIPTS - CX")
    }

    func testParseITermSessionListOutput_prefersWindowDisplayNameForGenericSessionName() {
        let text = "CCCC3333-2222-2222-2222-222222222222\t/dev/ttys023\tcodex\tTennis"
        let out = CodexActiveSessionsModel.parseITermSessionListOutput(text)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].name, "codex")
        XCTAssertEqual(out[0].displayName, "Tennis")
    }

    func testParseITermSessionListOutput_keepsCustomSessionNameWhenWindowDiffers() {
        let text = "DDDD4444-2222-2222-2222-222222222222\t/dev/ttys024\tAS-CX II (codex)\tTennis"
        let out = CodexActiveSessionsModel.parseITermSessionListOutput(text)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].name, "AS-CX II (codex)")
        XCTAssertEqual(out[0].displayName, "AS-CX II (codex)")
    }

    func testPresencesFromITermSessions_mapsRowsBySourceFromSingleSessionList() {
        let now = Date()
        let sessions = [
            CodexActiveSessionsModel.ITermSessionInfo(sessionID: "COD-1", tty: "/dev/ttys006", name: "AS-CX II (codex)"),
            CodexActiveSessionsModel.ITermSessionInfo(sessionID: "CLA-1", tty: "/dev/ttys010", name: "Claude"),
            CodexActiveSessionsModel.ITermSessionInfo(sessionID: "SHELL-1", tty: "/dev/ttys011", name: "-zsh")
        ]

        let codex = CodexActiveSessionsModel.presencesFromITermSessions(sessions, source: .codex, now: now)
        XCTAssertEqual(codex.count, 1)
        XCTAssertEqual(codex[0].terminal?.itermSessionId, "COD-1")
        XCTAssertEqual(codex[0].tty, "/dev/ttys006")
        XCTAssertEqual(codex[0].terminal?.tabTitle, "AS-CX II (codex)")

        let claude = CodexActiveSessionsModel.presencesFromITermSessions(sessions, source: .claude, now: now)
        XCTAssertEqual(claude.count, 1)
        XCTAssertEqual(claude[0].terminal?.itermSessionId, "CLA-1")
        XCTAssertEqual(claude[0].tty, "/dev/ttys010")
        XCTAssertEqual(claude[0].terminal?.tabTitle, "Claude")
    }

    func testPresencesFromITermSessions_usesDisplayNameForTabSubtitle() {
        let now = Date()
        let sessions = [
            CodexActiveSessionsModel.ITermSessionInfo(
                sessionID: "COD-2",
                tty: "/dev/ttys021",
                name: "codex",
                displayName: "Tennis - CX"
            )
        ]

        let codex = CodexActiveSessionsModel.presencesFromITermSessions(sessions, source: .codex, now: now)
        XCTAssertEqual(codex.count, 1)
        XCTAssertEqual(codex[0].terminal?.itermSessionId, "COD-2")
        XCTAssertEqual(codex[0].terminal?.tabTitle, "Tennis - CX")
    }

    func testITermTabTitleByTTY_buildsMapAndPrefersFirstNonEmptyTitle() {
        let sessions = [
            CodexActiveSessionsModel.ITermSessionInfo(
                sessionID: "A",
                tty: "/dev/ttys001",
                name: "codex",
                displayName: "First"
            ),
            CodexActiveSessionsModel.ITermSessionInfo(sessionID: "B", tty: "/dev/ttys001", name: "Second"),
            CodexActiveSessionsModel.ITermSessionInfo(sessionID: "C", tty: "/dev/ttys002", name: "Claude")
        ]

        let map = CodexActiveSessionsModel.itermTabTitleByTTY(sessions)
        XCTAssertEqual(map["/dev/ttys001"], "First")
        XCTAssertEqual(map["/dev/ttys002"], "Claude")
    }

    func testEnrichPresencesWithITermTabTitles_prefersFreshITermTitles() {
        var codexMissing = CodexActivePresence()
        codexMissing.source = .codex
        codexMissing.tty = "/dev/ttys001"
        var codexTerminal = CodexActivePresence.Terminal()
        codexTerminal.itermSessionId = "SID-1"
        codexMissing.terminal = codexTerminal

        var claudeExisting = CodexActivePresence()
        claudeExisting.source = .claude
        claudeExisting.tty = "/dev/ttys002"
        var claudeTerminal = CodexActivePresence.Terminal()
        claudeTerminal.tabTitle = "Already Set"
        claudeExisting.terminal = claudeTerminal

        let enriched = CodexActiveSessionsModel.enrichPresencesWithITermTabTitles(
            [codexMissing, claudeExisting],
            tabTitleByTTY: ["/dev/ttys001": "Codex Window", "/dev/ttys002": "Claude Window"]
        )

        XCTAssertEqual(enriched[0].terminal?.tabTitle, "Codex Window")
        XCTAssertEqual(enriched[1].terminal?.tabTitle, "Claude Window")
    }

    func testITermTabTitleBySessionGuid_buildsMapAndPrefersFirstNonEmptyTitle() {
        let sessions = [
            CodexActiveSessionsModel.ITermSessionInfo(
                sessionID: "w0t0p0:AAAA1111-BBBB-2222-CCCC-333333333333",
                tty: "/dev/ttys001",
                name: "codex",
                displayName: "Alpha"
            ),
            CodexActiveSessionsModel.ITermSessionInfo(
                sessionID: "AAAA1111-BBBB-2222-CCCC-333333333333",
                tty: "/dev/ttys009",
                name: "codex",
                displayName: "Ignored Duplicate"
            ),
            CodexActiveSessionsModel.ITermSessionInfo(
                sessionID: "w0t0p0:DDDD4444-BBBB-2222-CCCC-333333333333",
                tty: "/dev/ttys002",
                name: "codex",
                displayName: "Beta"
            )
        ]

        let map = CodexActiveSessionsModel.itermTabTitleBySessionGuid(sessions)
        XCTAssertEqual(map["AAAA1111-BBBB-2222-CCCC-333333333333"], "Alpha")
        XCTAssertEqual(map["DDDD4444-BBBB-2222-CCCC-333333333333"], "Beta")
    }

    func testEnrichPresencesWithITermTabTitles_usesSessionGuidWhenTTYMissing() {
        var codex = CodexActivePresence()
        codex.source = .codex
        var terminal = CodexActivePresence.Terminal()
        terminal.itermSessionId = "w0t0p0:AAAA1111-BBBB-2222-CCCC-333333333333"
        codex.terminal = terminal

        let enriched = CodexActiveSessionsModel.enrichPresencesWithITermTabTitles(
            [codex],
            tabTitleByTTY: [:],
            tabTitleBySessionGuid: ["AAAA1111-BBBB-2222-CCCC-333333333333": "Guid Title"]
        )

        XCTAssertEqual(enriched[0].terminal?.tabTitle, "Guid Title")
    }

    func testEffectivePollIntervalSeconds_usesCockpitVisibilityInBackground() {
        XCTAssertEqual(
            CodexActiveSessionsModel.effectivePollIntervalSeconds(
                appIsActive: false,
                hasVisibleConsumer: true,
                isCockpitVisible: true,
                isPinnedCockpitVisible: true
            ),
            CodexActiveSessionsModel.pinnedBackgroundPollInterval
        )

        XCTAssertEqual(
            CodexActiveSessionsModel.effectivePollIntervalSeconds(
                appIsActive: false,
                hasVisibleConsumer: true,
                isCockpitVisible: true,
                isPinnedCockpitVisible: false
            ),
            CodexActiveSessionsModel.pinnedBackgroundPollInterval
        )

        XCTAssertEqual(
            CodexActiveSessionsModel.effectivePollIntervalSeconds(
                appIsActive: false,
                hasVisibleConsumer: true,
                isCockpitVisible: false,
                isPinnedCockpitVisible: false
            ),
            CodexActiveSessionsModel.backgroundPollInterval
        )
    }

    func testEffectiveStableBackoffPollInterval_appliesAfterStableThreshold() {
        let interval = CodexActiveSessionsModel.effectiveStableBackoffPollInterval(
            baseInterval: CodexActiveSessionsModel.pinnedBackgroundPollInterval,
            consecutiveStableCycles: 3,
            appIsActive: false,
            isCockpitVisible: true,
            isPinnedCockpitVisible: true
        )
        XCTAssertEqual(interval, CodexActiveSessionsModel.stablePinnedBackgroundPollInterval)
    }

    func testEffectiveStableBackoffPollInterval_doesNotApplyBeforeThreshold() {
        let interval = CodexActiveSessionsModel.effectiveStableBackoffPollInterval(
            baseInterval: CodexActiveSessionsModel.pinnedBackgroundPollInterval,
            consecutiveStableCycles: 2,
            appIsActive: false,
            isCockpitVisible: true,
            isPinnedCockpitVisible: true
        )
        XCTAssertEqual(interval, CodexActiveSessionsModel.pinnedBackgroundPollInterval)
    }

    func testEffectiveStableBackoffPollInterval_doesNotApplyWhenActive() {
        let interval = CodexActiveSessionsModel.effectiveStableBackoffPollInterval(
            baseInterval: CodexActiveSessionsModel.defaultPollInterval,
            consecutiveStableCycles: 20,
            appIsActive: true,
            isCockpitVisible: true,
            isPinnedCockpitVisible: true
        )
        XCTAssertEqual(interval, CodexActiveSessionsModel.defaultPollInterval)
    }

    func testShouldResetStablePollBackoff_falseWhenNoMembershipLiveOrMetadataChange() {
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldResetStablePollBackoff(
                membershipChanged: false,
                liveStateChanged: false,
                metadataChanged: false
            )
        )
    }

    func testShouldResetStablePollBackoff_trueWhenMetadataChanges() {
        XCTAssertTrue(
            CodexActiveSessionsModel.shouldResetStablePollBackoff(
                membershipChanged: false,
                liveStateChanged: false,
                metadataChanged: true
            )
        )
    }

    func testShouldProbeITermSessions_requiresVisibleConsumer() {
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldProbeITermSessions(
                appIsActive: true,
                hasVisibleConsumer: false,
                isCockpitVisible: false,
                isPinnedCockpitVisible: false
            )
        )
    }

    func testShouldProbeITermSessions_backgroundAllowsVisibleCockpit() {
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldProbeITermSessions(
                appIsActive: false,
                hasVisibleConsumer: true,
                isCockpitVisible: false,
                isPinnedCockpitVisible: false
            )
        )
        XCTAssertTrue(
            CodexActiveSessionsModel.shouldProbeITermSessions(
                appIsActive: false,
                hasVisibleConsumer: true,
                isCockpitVisible: true,
                isPinnedCockpitVisible: false
            )
        )
        XCTAssertTrue(
            CodexActiveSessionsModel.shouldProbeITermSessions(
                appIsActive: false,
                hasVisibleConsumer: true,
                isCockpitVisible: true,
                isPinnedCockpitVisible: true
            )
        )
    }

    func testITermProbeMinIntervalSeconds_keepsPinnedBackgroundProbeSteady() {
        XCTAssertEqual(
            CodexActiveSessionsModel.itermProbeMinIntervalSeconds(
                appIsActive: false,
                isCockpitVisible: true,
                isPinnedCockpitVisible: true
            ),
            CodexActiveSessionsModel.pinnedBackgroundITermProbeMinInterval
        )

        XCTAssertEqual(
            CodexActiveSessionsModel.itermProbeMinIntervalSeconds(
                appIsActive: true,
                isCockpitVisible: true,
                isPinnedCockpitVisible: true
            ),
            0
        )
    }

    func testProcessProbeMinIntervalSeconds_usesLongerPinnedBackgroundCadence() {
        XCTAssertEqual(
            CodexActiveSessionsModel.processProbeMinIntervalSeconds(
                registryHasPresences: false,
                hasVisibleConsumer: true,
                appIsActive: false,
                isCockpitVisible: true,
                isPinnedCockpitVisible: true
            ),
            CodexActiveSessionsModel.pinnedBackgroundProcessProbeMinInterval
        )

        XCTAssertEqual(
            CodexActiveSessionsModel.processProbeMinIntervalSeconds(
                registryHasPresences: false,
                hasVisibleConsumer: true,
                appIsActive: true,
                isCockpitVisible: true,
                isPinnedCockpitVisible: true
            ),
            CodexActiveSessionsModel.processProbeMinIntervalRegistryEmptyForeground
        )
    }

    func testEffectiveCachedProcessPresenceTTL_bridgesPinnedBackgroundDeferredProbeWindow() {
        let processProbeMinInterval = CodexActiveSessionsModel.processProbeMinIntervalSeconds(
            registryHasPresences: false,
            hasVisibleConsumer: true,
            appIsActive: false,
            isCockpitVisible: true,
            isPinnedCockpitVisible: true
        )
        let pollInterval = CodexActiveSessionsModel.effectivePollIntervalSeconds(
            appIsActive: false,
            hasVisibleConsumer: true,
            isCockpitVisible: true,
            isPinnedCockpitVisible: true
        )

        let ttl = CodexActiveSessionsModel.effectiveCachedProcessPresenceTTL(
            baseTTL: CodexActiveSessionsModel.defaultStaleTTL,
            processProbeMinInterval: processProbeMinInterval,
            pollInterval: pollInterval,
            hasVisibleConsumer: true
        )

        XCTAssertEqual(ttl, processProbeMinInterval * 2 + pollInterval)
        XCTAssertGreaterThanOrEqual(ttl, processProbeMinInterval + pollInterval)
    }

    func testEffectiveCachedProcessPresenceTTL_keepsForegroundTTLWhenBaseAlreadyCoversGap() {
        let processProbeMinInterval = CodexActiveSessionsModel.processProbeMinIntervalSeconds(
            registryHasPresences: false,
            hasVisibleConsumer: true,
            appIsActive: true,
            isCockpitVisible: true,
            isPinnedCockpitVisible: true
        )
        let pollInterval = CodexActiveSessionsModel.effectivePollIntervalSeconds(
            appIsActive: true,
            hasVisibleConsumer: true,
            isCockpitVisible: true,
            isPinnedCockpitVisible: true
        )

        let ttl = CodexActiveSessionsModel.effectiveCachedProcessPresenceTTL(
            baseTTL: CodexActiveSessionsModel.defaultStaleTTL,
            processProbeMinInterval: processProbeMinInterval,
            pollInterval: pollInterval,
            hasVisibleConsumer: true
        )

        // Foreground probe interval (6s) < base TTL (10s), so 2x multiplier is not applied.
        XCTAssertEqual(ttl, CodexActiveSessionsModel.defaultStaleTTL)
    }

    func testEffectiveCachedProcessPresenceTTL_usesBaseWhenNoVisibleConsumer() {
        let ttl = CodexActiveSessionsModel.effectiveCachedProcessPresenceTTL(
            baseTTL: CodexActiveSessionsModel.defaultStaleTTL,
            processProbeMinInterval: CodexActiveSessionsModel.pinnedBackgroundProcessProbeMinInterval,
            pollInterval: CodexActiveSessionsModel.pinnedBackgroundPollInterval,
            hasVisibleConsumer: false
        )

        XCTAssertEqual(ttl, CodexActiveSessionsModel.defaultStaleTTL)
    }

    func testResolveLiveState_preservesPreviousStateWhenITermProbeWasDeferred() {
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveLiveState(
                probedState: nil,
                previousState: .activeWorking,
                heuristic: .openIdle,
                attemptedITermProbe: false,
                preservePreviousWhenProbeDeferred: true
            ),
            .activeWorking
        )
    }

    func testNextITermProbeBudget_progressesThenFallsBackToSteadyState() {
        var index: Int? = 0
        let first = CodexActiveSessionsModel.nextITermProbeBudget(resumeIndex: index)
        index = first.nextResumeIndex
        let second = CodexActiveSessionsModel.nextITermProbeBudget(resumeIndex: index)
        index = second.nextResumeIndex
        let third = CodexActiveSessionsModel.nextITermProbeBudget(resumeIndex: index)
        index = third.nextResumeIndex
        let steady = CodexActiveSessionsModel.nextITermProbeBudget(resumeIndex: index)

        XCTAssertEqual(first.budget, 1)
        XCTAssertEqual(second.budget, 2)
        XCTAssertEqual(third.budget, 4)
        XCTAssertEqual(steady.budget, 4)
        XCTAssertNil(steady.nextResumeIndex)
    }

    func testSelectRoundRobinKeys_cyclesWithoutSkipping() {
        let keys = ["a", "b", "c", "d"]

        let first = CodexActiveSessionsModel.selectRoundRobinKeys(sortedKeys: keys, start: 0, budget: 2)
        XCTAssertEqual(first.selected, ["a", "b"])
        XCTAssertEqual(first.nextCursor, 2)

        let second = CodexActiveSessionsModel.selectRoundRobinKeys(sortedKeys: keys, start: first.nextCursor, budget: 2)
        XCTAssertEqual(second.selected, ["c", "d"])
        XCTAssertEqual(second.nextCursor, 0)
    }

    func testSelectPinnedBackgroundITermProbeKeys_preservesActiveRowsAndRotatesWaitingRows() {
        let previous: [String: CodexLiveState] = [
            "a": .activeWorking,
            "b": .openIdle,
            "c": .openIdle,
            "d": .activeWorking,
            "e": .openIdle
        ]

        let first = CodexActiveSessionsModel.selectPinnedBackgroundITermProbeKeys(
            sortedCandidateKeys: ["a", "b", "c", "d", "e"],
            previousLiveStates: previous,
            waitingBudget: 2,
            start: 0
        )
        XCTAssertEqual(first.selected, ["a", "d", "b", "c"])
        XCTAssertEqual(first.nextCursor, 2)

        let second = CodexActiveSessionsModel.selectPinnedBackgroundITermProbeKeys(
            sortedCandidateKeys: ["a", "b", "c", "d", "e"],
            previousLiveStates: previous,
            waitingBudget: 2,
            start: first.nextCursor
        )
        XCTAssertEqual(second.selected, ["a", "d", "e", "b"])
        XCTAssertEqual(second.nextCursor, 1)
    }

    func testITermProbeCandidateKeys_filtersToProbeableCodexAndClaudeRows() {
        var codex = CodexActivePresence()
        codex.source = .codex
        codex.sessionId = "sid-codex"
        codex.tty = "/dev/ttys001"

        var claude = CodexActivePresence()
        claude.source = .claude
        claude.sessionId = "sid-claude"
        var terminal = CodexActivePresence.Terminal()
        terminal.itermSessionId = "w0t0p0:CLA"
        claude.terminal = terminal

        var gemini = CodexActivePresence()
        gemini.source = .gemini
        gemini.sessionId = "sid-gemini"
        gemini.tty = "/dev/ttys003"

        let keys = Set(CodexActiveSessionsModel.itermProbeCandidateKeys(for: [codex, claude, gemini]))
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.contains("codex|sid:sid-codex"))
        XCTAssertTrue(keys.contains("claude|sid:sid-claude"))
    }

    func testShouldSuppressTransientEmptyPublish_requiresVisibleCockpitAndFullConfirmation() {
        XCTAssertTrue(
            CodexActiveSessionsModel.shouldSuppressTransientEmptyPublish(
                ui: [],
                cockpitVisible: true,
                didProbeProcesses: false,
                didProbeITerm: false,
                registryHadPresences: false
            )
        )

        XCTAssertTrue(
            CodexActiveSessionsModel.shouldSuppressTransientEmptyPublish(
                ui: [],
                cockpitVisible: true,
                didProbeProcesses: true,
                didProbeITerm: true,
                registryHadPresences: true
            )
        )

        XCTAssertFalse(
            CodexActiveSessionsModel.shouldSuppressTransientEmptyPublish(
                ui: [],
                cockpitVisible: true,
                didProbeProcesses: true,
                didProbeITerm: true,
                registryHadPresences: false
            )
        )

        XCTAssertFalse(
            CodexActiveSessionsModel.shouldSuppressTransientEmptyPublish(
                ui: [],
                cockpitVisible: false,
                didProbeProcesses: false,
                didProbeITerm: false,
                registryHadPresences: false
            )
        )
    }

    func testResolveLiveState_prefersPreviousStateWhenProbeSkipped() {
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveLiveState(
                probedState: nil,
                previousState: .activeWorking,
                heuristic: .openIdle,
                attemptedITermProbe: false,
                preservePreviousWhenProbeDeferred: true
            ),
            .activeWorking
        )
    }

    func testResolveLiveState_usesHeuristicWhenProbeNotDeferred() {
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveLiveState(
                probedState: nil,
                previousState: .activeWorking,
                heuristic: .openIdle,
                attemptedITermProbe: false,
                preservePreviousWhenProbeDeferred: false
            ),
            .openIdle
        )

        XCTAssertEqual(
            CodexActiveSessionsModel.resolveLiveState(
                probedState: nil,
                previousState: .activeWorking,
                heuristic: .openIdle,
                attemptedITermProbe: true,
                preservePreviousWhenProbeDeferred: true
            ),
            .openIdle
        )
    }

    func testClassifyLiveStates_selectedProbeWithoutBatchRowFallsBackToHeuristic() {
        var codex = CodexActivePresence()
        codex.source = .codex
        codex.sessionId = "sid-codex"
        codex.tty = "/dev/ttys001"

        var claude = CodexActivePresence()
        claude.source = .claude
        claude.sessionId = "sid-claude"
        claude.tty = "/dev/ttys002"

        let codexKey = "codex|sid:sid-codex"
        let claudeKey = "claude|sid:sid-claude"
        let states = CodexActiveSessionsModel.classifyLiveStatesForTesting(
            for: [codex, claude],
            now: Date(),
            probeITerm: true,
            previousLiveStates: [codexKey: .activeWorking, claudeKey: .activeWorking],
            probedITermPresenceKeys: [codexKey, claudeKey],
            batchProbeResults: [:]
        )

        XCTAssertEqual(states[codexKey], .openIdle)
        XCTAssertEqual(states[claudeKey], .openIdle)
    }

    func testClassifyLiveStates_deferredProbePreservesPreviousState() {
        var codex = CodexActivePresence()
        codex.source = .codex
        codex.sessionId = "sid-codex"
        codex.tty = "/dev/ttys001"

        let key = "codex|sid:sid-codex"
        let states = CodexActiveSessionsModel.classifyLiveStatesForTesting(
            for: [codex],
            now: Date(),
            probeITerm: true,
            previousLiveStates: [key: .activeWorking],
            probedITermPresenceKeys: [],
            batchProbeResults: [:]
        )

        XCTAssertEqual(states[key], .activeWorking)
    }

    func testIsLikelyCodexITermSessionName_matchesExpectedTabNames() {
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyCodexITermSessionName("codex"))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyCodexITermSessionName("codex --resume 123"))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyCodexITermSessionName("AS-CX II (codex)"))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyCodexITermSessionName("AS-CX II (codex*)"))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyCodexITermSessionName("AS-CX II (codex\")"))
        XCTAssertFalse(CodexActiveSessionsModel.isLikelyCodexITermSessionName("-zsh"))
        XCTAssertFalse(CodexActiveSessionsModel.isLikelyCodexITermSessionName("Codex-History"))
    }

    func testIsLikelyITermSessionName_matchesClaudeAndOpenCodeNames() {
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyITermSessionName("Claude", source: .claude))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyITermSessionName("claude --model sonnet", source: .claude))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyITermSessionName("opencode", source: .opencode))
        XCTAssertTrue(CodexActiveSessionsModel.isLikelyITermSessionName("opencode --continue", source: .opencode))
        XCTAssertFalse(CodexActiveSessionsModel.isLikelyITermSessionName("zsh", source: .claude))
        XCTAssertFalse(CodexActiveSessionsModel.isLikelyITermSessionName("workspace shell", source: .opencode))
    }

    @MainActor
    func testSupportsLiveSessions_includesCodexClaudeAndOpenCode() {
        let model = CodexActiveSessionsModel()
        XCTAssertTrue(model.supportsLiveSessions(for: .codex))
        XCTAssertTrue(model.supportsLiveSessions(for: .claude))
        XCTAssertTrue(model.supportsLiveSessions(for: .opencode))
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

    func testCanAttemptITerm2Focus_allowsTTYForKnownNonITermTerminal() {
        XCTAssertTrue(CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: nil,
            tty: "/dev/ttys012",
            termProgram: "Apple_Terminal"
        ))
    }

    func testCanAttemptITerm2Focus_rejectsWhenNoTTYAndNoGUID() {
        XCTAssertFalse(CodexActiveSessionsModel.canAttemptITerm2Focus(
            itermSessionId: nil,
            tty: nil,
            termProgram: "tmux"
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

    func testClassifyITermTail_nonPromptTailReturnsNilForHeuristicFallback() {
        let tail = """
        Analyzing files...
        Fetching status...
        """
        XCTAssertNil(CodexActiveSessionsModel.classifyITermTail(tail))
    }

    func testClassifyITermTail_historicalWorkedForDoesNotForceActive() {
        let tail = """
        — Worked for 1m 14s —

        › Explain this codebase
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyITermTail(tail), .openIdle)
    }

    func testClassifyGenericITermTail_prefersPromptOverHistoricalWeakBusyMarkers() {
        let tail = """
        thinking about plan
        running command
        ›
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyGenericITermTail(tail), .openIdle)
    }

    func testClassifyGenericITermTail_keepsActiveWhenStrongMarkerNearBottomEvenWithPrompt() {
        let tail = """
        status line
        Esc to interrupt
        ›
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyGenericITermTail(tail), .activeWorking)
    }

    func testClassifyGenericITermTail_ignoresStaleStrongMarkerWhenPromptAtBottom() {
        let tail = """
        Esc to interrupt
        old output line 1
        old output line 2
        old output line 3
        old output line 4
        ›
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyGenericITermTail(tail), .openIdle)
    }

    func testClassifyGenericITermTail_marksActiveWhenWeakBusyMarkerNearBottom() {
        let tail = """
        status: processing
        still working on this
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyGenericITermTail(tail), .activeWorking)
    }

    func testClassifyGenericITermTail_returnsNilForAmbiguousNonPromptTail() {
        let tail = """
        thinking
        status complete
        next step ready
        """
        XCTAssertNil(CodexActiveSessionsModel.classifyGenericITermTail(tail))
    }

    func testClassifyClaudeITermTail_marksActiveForStrongNearBottomMarker() {
        let tail = """
        status line
        Esc to interrupt
        ›
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyClaudeITermTail(tail), .activeWorking)
    }

    func testClassifyClaudeITermTail_stripsANSIStylesBeforeMarkerMatch() {
        let tail = "\u{001B}[2mEsc\u{001B}[0m to interrupt"
        XCTAssertEqual(CodexActiveSessionsModel.classifyClaudeITermTail(tail), .activeWorking)
    }

    func testClassifyClaudeITermTail_marksOpenWhenPromptAndNoStrongMarker() {
        let tail = """
        previous line
        ›
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyClaudeITermTail(tail), .openIdle)
    }

    func testClassifyClaudeITermTail_marksOpenForZshPercentPrompt() {
        let tail = """
        previous line
        alex@mbp %
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyClaudeITermTail(tail), .openIdle)
    }

    func testClassifyClaudeITermTail_returnsNilForAmbiguousNonPromptTail() {
        let tail = """
        preparing tool execution
        status update
        """
        XCTAssertNil(CodexActiveSessionsModel.classifyClaudeITermTail(tail))
    }

    func testClassifyClaudeITermTail_promptWinsOverGenericLexicalHistory() {
        let tail = """
        thinking about plan
        running command
        alex@mbp %
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyClaudeITermTail(tail), .openIdle)
    }

    func testClassifyClaudeITermTail_treatsPercentStatusTailAsAmbiguous() {
        let tail = """
        Downloading dependencies
        78%
        """
        XCTAssertNil(CodexActiveSessionsModel.classifyClaudeITermTail(tail))
    }

    func testClassifyClaudeITermTail_marksActiveForWeakBusyMarkerNearBottom() {
        let tail = """
        status line
        still thinking about the next tool call
        """
        XCTAssertEqual(CodexActiveSessionsModel.classifyClaudeITermTail(tail), .activeWorking)
    }

    func testParseITermProbeMetadata_parsesTabDelimitedMetadata() {
        let parsed = CodexActiveSessionsModel.parseITermProbeMetadata("true\tfalse")
        XCTAssertEqual(parsed.isProcessing, true)
        XCTAssertEqual(parsed.isAtShellPrompt, false)
    }

    func testParseITermProbeMetadata_parsesLegacyLiteralTabTokenMetadata() {
        let parsed = CodexActiveSessionsModel.parseITermProbeMetadata("falsetabtrue")
        XCTAssertEqual(parsed.isProcessing, false)
        XCTAssertEqual(parsed.isAtShellPrompt, true)
    }

    func testParseBatchedITermProbeOutput_preservesTailAndMetadataPerPresence() {
        let rowSeparator = String(UnicodeScalar(0x1E)!)
        let fieldSeparator = String(UnicodeScalar(0x1F)!)
        let text = [
            ["codex|sid:a", "true", "false", "first line\nsecond line"].joined(separator: fieldSeparator),
            ["claude|sid:b", "false", "true", ""].joined(separator: fieldSeparator)
        ].joined(separator: rowSeparator)

        let parsed = CodexActiveSessionsModel.parseBatchedITermProbeOutput(
            text,
            rowSeparator: rowSeparator,
            fieldSeparator: fieldSeparator
        )

        XCTAssertEqual(
            parsed["codex|sid:a"],
            CodexActiveSessionsModel.ITermProbeResult(
                tail: "first line\nsecond line",
                isProcessing: true,
                isAtShellPrompt: false
            )
        )
        XCTAssertEqual(
            parsed["claude|sid:b"],
            CodexActiveSessionsModel.ITermProbeResult(
                tail: nil,
                isProcessing: false,
                isAtShellPrompt: true
            )
        )
    }

    func testResolveClaudeStateFromITermProbe_prefersProcessingFlag() {
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveClaudeStateFromITermProbe(
                isProcessing: true,
                isAtShellPrompt: false,
                tail: "›"
            ),
            .activeWorking
        )
    }

    func testResolveClaudeStateFromITermProbe_usesPromptFlagWhenNotProcessing() {
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveClaudeStateFromITermProbe(
                isProcessing: false,
                isAtShellPrompt: true,
                tail: "status line"
            ),
            .openIdle
        )
    }

    func testResolveClaudeStateFromITermProbe_marksOpenForNoObviousNextStepPromptLine() {
        let tail = """
        response line
        ❯ (No obvious next step)
        ~/Repository/Triada  main
        """
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveClaudeStateFromITermProbe(
                isProcessing: false,
                isAtShellPrompt: false,
                tail: tail
            ),
            .openIdle
        )
    }

    func testResolveClaudeStateFromITermProbe_prefersProcessingWhenBothFlagsTrue() {
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveClaudeStateFromITermProbe(
                isProcessing: true,
                isAtShellPrompt: true,
                tail: "Esc to interrupt"
            ),
            .activeWorking
        )
    }

    func testResolveClaudeStateFromITermProbe_marksActiveForAmbiguousTailWithoutPrompt() {
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveClaudeStateFromITermProbe(
                isProcessing: false,
                isAtShellPrompt: false,
                tail: "test\ntest\ntest"
            ),
            .activeWorking
        )
    }

    func testResolveClaudeStateFromITermProbe_marksOpenWhenPromptExistsNearBottom() {
        let tail = """
        status line
        ❯
        ~/Repository/Triada  main
        """
        XCTAssertEqual(
            CodexActiveSessionsModel.resolveClaudeStateFromITermProbe(
                isProcessing: false,
                isAtShellPrompt: false,
                tail: tail
            ),
            .openIdle
        )
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

    func testHeuristicLiveStateFromLogMTime_claudeWindow15s_staysActiveAt10s() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("as-live-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("claude-test.jsonl")
        try Data("{}".utf8).write(to: file)

        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: file.path)

        XCTAssertEqual(
            CodexActiveSessionsModel.heuristicLiveStateFromLogMTime(
                logPath: file.path,
                now: now,
                activeWriteWindow: 15.0
            ),
            .activeWorking
        )
    }

    func testHeuristicLiveStateFromLogMTime_usesSourceFilePathWhenLogPathMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("as-live-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let source = dir.appendingPathComponent("presence.json")
        try Data("{}".utf8).write(to: source)

        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-0.5)], ofItemAtPath: source.path)

        XCTAssertEqual(
            CodexActiveSessionsModel.heuristicLiveStateFromLogMTime(
                logPath: nil,
                sourceFilePath: source.path,
                now: now,
                activeWriteWindow: 2.5
            ),
            .activeWorking
        )
    }

    func testHeuristicLiveStateFromLogMTime_prefersLogPathOverFreshSourceFilePath() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("as-live-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let logFile = dir.appendingPathComponent("session.jsonl")
        try Data("{}".utf8).write(to: logFile)
        let source = dir.appendingPathComponent("presence.json")
        try Data("{}".utf8).write(to: source)

        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-15)], ofItemAtPath: logFile.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-0.5)], ofItemAtPath: source.path)

        XCTAssertEqual(
            CodexActiveSessionsModel.heuristicLiveStateFromLogMTime(
                logPath: logFile.path,
                sourceFilePath: source.path,
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

    func testCockpitUnresolvedPlaceholder_hidesCodexWithSessionID() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.publisher = "agent-sessions-shim"
        presence.kind = "interactive"
        presence.sessionId = "sid-codex"

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

    func testCockpitUnresolvedPlaceholder_hidesCodexWithLogPath() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.publisher = "agent-sessions-shim"
        presence.kind = "interactive"
        presence.sessionLogPath = "/tmp/codex-rollout.jsonl"

        XCTAssertTrue(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_hidesCodexTTYOnlyITermFallback() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.publisher = "agent-sessions-iterm"
        presence.kind = "interactive"
        presence.tty = "/dev/ttys099"
        var terminal = CodexActivePresence.Terminal()
        terminal.termProgram = "iTerm2"
        terminal.itermSessionId = "ABC-123"
        presence.terminal = terminal

        XCTAssertTrue(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_keepsResolvedCodexPresence() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.publisher = "agent-sessions-shim"
        presence.kind = "interactive"
        presence.sessionId = "sid-codex"
        let resolved = makeFallbackSession(
            id: "sid-codex",
            source: .codex,
            cwd: "/Users/alexm/Repository/Codex-History",
            modifiedAt: Date()
        )

        XCTAssertFalse(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: resolved,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_hidesTTYOnlyNonITermPresence() {
        var presence = CodexActivePresence()
        presence.source = .claude
        presence.publisher = "agent-sessions-shim"
        presence.tty = "/dev/ttys011"
        var terminal = CodexActivePresence.Terminal()
        terminal.termProgram = "tmux"
        presence.terminal = terminal

        XCTAssertTrue(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_hidesTTYOnlyPresenceWhenTermProgramMissing() {
        var presence = CodexActivePresence()
        presence.source = .claude
        presence.publisher = "agent-sessions-shim"
        presence.tty = "/dev/ttys011"
        var terminal = CodexActivePresence.Terminal()
        terminal.termProgram = nil
        presence.terminal = terminal

        XCTAssertTrue(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_keepsITermGuidPresence() {
        var presence = CodexActivePresence()
        presence.source = .claude
        presence.publisher = "agent-sessions-process"
        presence.tty = "/dev/ttys011"
        var terminal = CodexActivePresence.Terminal()
        terminal.termProgram = "tmux"
        terminal.itermSessionId = "w0t0p0:ABCDEF"
        presence.terminal = terminal

        XCTAssertFalse(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testCockpitUnresolvedPlaceholder_keepsClaudeWithLogPathButNoITermIdentity() {
        var presence = CodexActivePresence()
        presence.source = .claude
        presence.publisher = "agent-sessions-process"
        presence.sessionLogPath = "/tmp/claude-unresolved.jsonl"
        presence.tty = "/dev/ttys011"
        var terminal = CodexActivePresence.Terminal()
        terminal.termProgram = "tmux"
        presence.terminal = terminal

        XCTAssertFalse(
            CockpitView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testAgentCockpitHUD_mapLiveStateForHUD_mapsActiveAndIdle() {
        XCTAssertEqual(AgentCockpitHUDView.mapLiveStateForHUD(.activeWorking), .active)
        XCTAssertEqual(AgentCockpitHUDView.mapLiveStateForHUD(.openIdle), .idle)
    }

    func testAgentCockpitHUD_normalizedCockpitTabTitle_stripsDefaultSuffixes() {
        XCTAssertEqual(
            AgentCockpitHUDView.normalizedCockpitTabTitle("CC - AS III (codex*)", source: .codex),
            "CC - AS III"
        )
        XCTAssertEqual(
            AgentCockpitHUDView.normalizedCockpitTabTitle("CC - AS III (codex\")", source: .codex),
            "CC - AS III"
        )
        XCTAssertEqual(
            AgentCockpitHUDView.normalizedCockpitTabTitle("Project triage (claude code*)", source: .claude),
            "Project triage"
        )
    }

    func testAgentCockpitHUD_normalizedCockpitTabTitle_hidesDefaultOnlyNames() {
        XCTAssertNil(AgentCockpitHUDView.normalizedCockpitTabTitle("codex", source: .codex))
        XCTAssertNil(AgentCockpitHUDView.normalizedCockpitTabTitle("codex*", source: .codex))
        XCTAssertNil(AgentCockpitHUDView.normalizedCockpitTabTitle("codex\"", source: .codex))
        XCTAssertNil(AgentCockpitHUDView.normalizedCockpitTabTitle("claude", source: .claude))
        XCTAssertNil(AgentCockpitHUDView.normalizedCockpitTabTitle("claude code*", source: .claude))
    }

    func testAgentCockpitHUD_normalizedCockpitTabTitle_keepsCustomTitles() {
        XCTAssertEqual(
            AgentCockpitHUDView.normalizedCockpitTabTitle("release-checklist", source: .codex),
            "release-checklist"
        )
        XCTAssertEqual(
            AgentCockpitHUDView.normalizedCockpitTabTitle("Code Review (workspace)", source: .claude),
            "Code Review (workspace)"
        )
    }

    func testAgentCockpitHUDWindowSanitization_restoresNormalFromPinnedBaseline() {
        XCTAssertEqual(
            AgentCockpitHUDWindowConfigurator.Coordinator.sanitizedUnpinnedLevel(from: .screenSaver),
            .normal
        )
        XCTAssertEqual(
            AgentCockpitHUDWindowConfigurator.Coordinator.sanitizedUnpinnedLevel(from: .statusBar),
            .normal
        )
        XCTAssertEqual(
            AgentCockpitHUDWindowConfigurator.Coordinator.sanitizedUnpinnedLevel(from: .floating),
            .floating
        )
    }

    func testAgentCockpitHUDWindowSanitization_removesPinnedCollectionFlags() {
        let baseline: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        let sanitized = AgentCockpitHUDWindowConfigurator.Coordinator.sanitizedUnpinnedCollectionBehavior(
            from: baseline
        )
        XCTAssertFalse(sanitized.contains(.canJoinAllSpaces))
        XCTAssertFalse(sanitized.contains(.fullScreenAuxiliary))
        XCTAssertTrue(sanitized.contains(.moveToActiveSpace))
    }

    func testAgentCockpitHUD_filteredRows_appliesStateAndQuery() {
        let rows = [
            makeHUDRow(id: "active-one", project: "Alpha", name: "Implement parser", state: .active),
            makeHUDRow(id: "idle-one", project: "Beta", name: "Review docs", state: .idle),
            makeHUDRow(id: "idle-two", project: "Alpha", name: "Ship release", state: .idle)
        ]

        let activeOnly = AgentCockpitHUDView.filteredRows(rows, mode: .active, query: "")
        XCTAssertEqual(activeOnly.map(\.id), ["active-one"])

        let idleWithQuery = AgentCockpitHUDView.filteredRows(rows, mode: .idle, query: "alpha")
        XCTAssertEqual(idleWithQuery.map(\.id), ["idle-two"])
    }

    func testAgentCockpitHUDRowEquality_includesElapsedAndLastActivityTooltip() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = HUDRow(
            id: "row-1",
            source: .codex,
            agentType: .codex,
            projectName: "Alpha",
            displayName: "Build feature",
            liveState: .idle,
            preview: "Build feature",
            elapsed: "1m",
            lastSeenAt: now,
            itermSessionId: "guid-1",
            revealURL: URL(string: "iterm2:///reveal?sessionid=guid-1"),
            tty: "/dev/ttys001",
            termProgram: "iTerm.app",
            tabTitle: "Build",
            cleanedTabTitle: "Build",
            resolvedSessionID: "session-1",
            runtimeSessionID: "runtime-1",
            logPath: "/tmp/log.jsonl",
            workingDirectory: "/tmp",
            lastActivityAt: now,
            lastActivityTooltip: "Mar 1, 2026 at 12:00:00 PM"
        )
        let b = HUDRow(
            id: "row-1",
            source: .codex,
            agentType: .codex,
            projectName: "Alpha",
            displayName: "Build feature",
            liveState: .idle,
            preview: "Build feature",
            elapsed: "8m",
            lastSeenAt: now,
            itermSessionId: "guid-1",
            revealURL: URL(string: "iterm2:///reveal?sessionid=guid-1"),
            tty: "/dev/ttys001",
            termProgram: "iTerm.app",
            tabTitle: "Build",
            cleanedTabTitle: "Build",
            resolvedSessionID: "session-1",
            runtimeSessionID: "runtime-1",
            logPath: "/tmp/log.jsonl",
            workingDirectory: "/tmp",
            lastActivityAt: now,
            lastActivityTooltip: "Mar 1, 2026 at 12:08:00 PM"
        )

        XCTAssertNotEqual(a, b)
    }

    func testAgentCockpitHUD_displayPriority_marksWaitingRowsStaleAfterThreshold() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = makeHUDRow(
            id: "fresh",
            project: "Alpha",
            name: "Fresh wait",
            state: .idle,
            lastActivityAt: now.addingTimeInterval(-(3 * 60 * 60))
        )
        let stale = makeHUDRow(
            id: "stale",
            project: "Alpha",
            name: "Stale wait",
            state: .idle,
            lastActivityAt: now.addingTimeInterval(-(4 * 60 * 60 + 1))
        )
        let unknown = makeHUDRow(
            id: "unknown",
            project: "Alpha",
            name: "Unknown wait",
            state: .idle,
            lastActivityAt: nil
        )

        XCTAssertEqual(AgentCockpitHUDView.displayPriority(for: fresh, now: now), .waitingFresh)
        XCTAssertEqual(AgentCockpitHUDView.displayPriority(for: stale, now: now), .waitingStale)
        XCTAssertEqual(AgentCockpitHUDView.displayPriority(for: unknown, now: now), .waitingFresh)
    }

    func testAgentCockpitHUD_groupedRows_ordersCurrentProjectsBeforeStaleOnlyProjects() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rows = [
            makeHUDRow(
                id: "idle-beta",
                project: "Beta",
                name: "B",
                state: .idle,
                lastActivityAt: now.addingTimeInterval(-(5 * 60 * 60))
            ),
            makeHUDRow(
                id: "active-gamma",
                project: "Gamma",
                name: "G",
                state: .active,
                lastActivityAt: now.addingTimeInterval(-120)
            ),
            makeHUDRow(
                id: "idle-alpha",
                project: "Alpha",
                name: "A",
                state: .idle,
                lastActivityAt: now.addingTimeInterval(-(45 * 60))
            )
        ]

        let grouped = AgentCockpitHUDView.groupedRows(rows, now: now)
        XCTAssertEqual(grouped.map(\.projectName), ["Gamma", "Alpha", "Beta"])
        XCTAssertEqual(grouped.map(\.displayPriority), [.active, .waitingFresh, .waitingStale])
        XCTAssertEqual(grouped.map(\.idleCount), [0, 1, 1])
        XCTAssertEqual(grouped.last?.isStaleOnly, true)
    }

    func testAgentCockpitHUD_counts_reportsActiveAndIdleTotals() {
        let rows = [
            makeHUDRow(id: "a1", project: "Alpha", name: "A1", state: .active),
            makeHUDRow(id: "i1", project: "Alpha", name: "I1", state: .idle),
            makeHUDRow(id: "a2", project: "Beta", name: "A2", state: .active)
        ]
        let counts = AgentCockpitHUDView.counts(for: rows)
        XCTAssertEqual(counts.active, 2)
        XCTAssertEqual(counts.idle, 1)
    }

    func testAgentCockpitHUD_liveSessionSummary_countsFreshAndStaleWaitingTogether() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rows = [
            makeHUDRow(id: "active", project: "Alpha", name: "Active", state: .active, lastActivityAt: now.addingTimeInterval(-30)),
            makeHUDRow(id: "fresh-wait", project: "Alpha", name: "Fresh", state: .idle, lastActivityAt: now.addingTimeInterval(-(60 * 60))),
            makeHUDRow(id: "stale-wait", project: "Beta", name: "Stale", state: .idle, lastActivityAt: now.addingTimeInterval(-(5 * 60 * 60)))
        ]

        let summary = AgentCockpitHUDView.liveSessionSummary(for: rows, now: now)
        XCTAssertEqual(summary.activeCount, 1)
        XCTAssertEqual(summary.waitingCount, 2)
    }

    func testAgentCockpitHUD_liveSessionSummary_treatsUnknownWaitingAsWaiting() {
        let rows = [
            makeHUDRow(id: "waiting", project: "Alpha", name: "Unknown", state: .idle, lastActivityAt: nil)
        ]

        let summary = AgentCockpitHUDView.liveSessionSummary(for: rows)
        XCTAssertEqual(summary.activeCount, 0)
        XCTAssertEqual(summary.waitingCount, 1)
    }

    func testAgentCockpitHUD_groupedRows_ordersStaleWaitingRowsLastInsideMixedProject() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rows = [
            makeHUDRow(
                id: "stale",
                project: "Alpha",
                name: "Stale row",
                state: .idle,
                lastActivityAt: now.addingTimeInterval(-(2 * 86_400))
            ),
            makeHUDRow(
                id: "fresh",
                project: "Alpha",
                name: "Fresh row",
                state: .idle,
                lastActivityAt: now.addingTimeInterval(-(30 * 60))
            ),
            makeHUDRow(
                id: "active",
                project: "Alpha",
                name: "Active row",
                state: .active,
                lastActivityAt: now.addingTimeInterval(-60)
            )
        ]

        let grouped = AgentCockpitHUDView.groupedRows(rows, now: now)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].rows.map(\.id), ["active", "fresh", "stale"])
        XCTAssertFalse(grouped[0].isStaleOnly)
    }

    func testAgentCockpitHUD_hasPriorityChurn_detectsFreshWaitingTurningStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let existing = [
            makeHUDRow(
                id: "same",
                project: "Alpha",
                name: "Wait",
                state: .idle,
                lastActivityAt: now.addingTimeInterval(-(3 * 60 * 60))
            )
        ]
        let incoming = [
            makeHUDRow(
                id: "same",
                project: "Alpha",
                name: "Wait",
                state: .idle,
                lastActivityAt: now.addingTimeInterval(-(5 * 60 * 60))
            )
        ]

        XCTAssertTrue(AgentCockpitHUDView.hasPriorityChurn(existing: existing, incoming: incoming, now: now))
    }

    func testAgentCockpitHUD_hasPriorityChurn_detectsOrderShiftForSameRows() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nearThreshold = makeHUDRow(
            id: "near-threshold",
            project: "Alpha",
            name: "Near threshold",
            state: .idle,
            lastActivityAt: now.addingTimeInterval(-(3 * 60 * 60 + 59 * 60))
        )
        let fresh = makeHUDRow(
            id: "fresh",
            project: "Alpha",
            name: "Fresh",
            state: .idle,
            lastActivityAt: now.addingTimeInterval(-(3 * 60 * 60 + 50 * 60))
        )

        let existing = [nearThreshold, fresh]
        let incoming = [fresh, nearThreshold]
        XCTAssertTrue(AgentCockpitHUDView.hasPriorityChurn(existing: existing, incoming: incoming, now: now))
    }

    func testAgentCockpitHUD_hasPriorityChurn_detectsTimeOnlyStaleTransitionAcrossSnapshots() {
        let existingSnapshotAt = Date(timeIntervalSince1970: 1_000_000)
        let incomingSnapshotAt = existingSnapshotAt.addingTimeInterval(31 * 60)
        let lastActivityAt = existingSnapshotAt.addingTimeInterval(-(3 * 60 * 60 + 45 * 60))

        let row = makeHUDRow(
            id: "same",
            project: "Alpha",
            name: "Wait",
            state: .idle,
            lastActivityAt: lastActivityAt
        )

        XCTAssertTrue(
            AgentCockpitHUDView.hasPriorityChurn(
                existing: [row],
                existingSnapshotAt: existingSnapshotAt,
                incoming: [row],
                incomingSnapshotAt: incomingSnapshotAt
            )
        )
    }

    func testAgentCockpitHUD_synchronizeCollapsedProjects_clearsCompactOnlyStateWhenLeavingCompactMode() {
        let staleGroup = makeHUDGroup(
            id: "stale",
            rows: [makeHUDRow(id: "s1", project: "stale", name: "S1", state: .idle)],
            activeCount: 0,
            idleCount: 1,
            freshIdleCount: 0,
            staleIdleCount: 1
        )
        let synchronized = AgentCockpitHUDView.synchronizeCollapsedProjectsForStaleGroups(
            isCompact: false,
            groupByProject: true,
            groups: [staleGroup],
            collapsedProjects: ["stale", "manual"],
            staleAutoCollapsedProjects: ["stale"],
            manuallyExpandedStaleProjects: ["stale"]
        )

        XCTAssertEqual(synchronized.collapsedProjects, ["manual"])
        XCTAssertEqual(synchronized.staleAutoCollapsedProjects, [])
        XCTAssertEqual(synchronized.manuallyExpandedStaleProjects, [])
    }

    func testAgentCockpitHUD_synchronizeCollapsedProjects_autoCollapsesStaleOnlyGroupsInCompactMode() {
        let staleGroup = makeHUDGroup(
            id: "stale",
            rows: [makeHUDRow(id: "s1", project: "stale", name: "S1", state: .idle)],
            activeCount: 0,
            idleCount: 1,
            freshIdleCount: 0,
            staleIdleCount: 1
        )
        let activeGroup = makeHUDGroup(
            id: "active",
            rows: [makeHUDRow(id: "a1", project: "active", name: "A1", state: .active)],
            activeCount: 1,
            idleCount: 0,
            freshIdleCount: 0,
            staleIdleCount: 0
        )

        let synchronized = AgentCockpitHUDView.synchronizeCollapsedProjectsForStaleGroups(
            isCompact: true,
            groupByProject: true,
            groups: [activeGroup, staleGroup],
            collapsedProjects: [],
            staleAutoCollapsedProjects: [],
            manuallyExpandedStaleProjects: []
        )

        XCTAssertEqual(synchronized.collapsedProjects, ["stale"])
        XCTAssertEqual(synchronized.staleAutoCollapsedProjects, ["stale"])
        XCTAssertEqual(synchronized.manuallyExpandedStaleProjects, [])
    }

    func testAgentCockpitHUD_projectLabel_prefersWorkspaceInferenceForUnresolvedPresence() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.workspaceRoot = "/Users/test/Repository/ProjectAlpha"

        XCTAssertEqual(
            AgentCockpitHUDView.projectLabel(resolvedSession: nil, presence: presence),
            "ProjectAlpha"
        )
    }

    func testAgentCockpitHUD_projectLabel_fallsBackToHyphenWhenInferenceFails() {
        var presence = CodexActivePresence()
        presence.source = .codex

        XCTAssertEqual(
            AgentCockpitHUDView.projectLabel(resolvedSession: nil, presence: presence),
            "-"
        )
    }

    func testAgentCockpitHUD_shouldHideUnresolvedCodexPlaceholder_allowsWorkspaceMatch() {
        var presence = CodexActivePresence()
        presence.source = .codex
        presence.workspaceRoot = "/Users/test/Repository/ProjectAlpha"

        XCTAssertFalse(
            AgentCockpitHUDView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: true
            )
        )
    }

    func testAgentCockpitHUD_shouldHideUnresolvedCodexPlaceholder_hidesWithoutWorkspaceMatch() {
        var presence = CodexActivePresence()
        presence.source = .codex

        XCTAssertTrue(
            AgentCockpitHUDView.shouldHideUnresolvedPresencePlaceholder(
                presence,
                resolvedSession: nil,
                hasWorkspaceMatch: false
            )
        )
    }

    func testAgentCockpitHUD_stableMergedOrder_preservesExistingAndAppendsInserted() {
        let existing = ["a", "b", "c"]
        let incoming = ["b", "d", "c"]
        let result = AgentCockpitHUDView.stableMergedOrder(existing: existing, incoming: incoming)
        XCTAssertEqual(result.order, ["b", "c", "d"])
        XCTAssertEqual(result.inserted, ["d"])
    }

    func testAgentCockpitHUD_hasMembershipChurn_detectsAddedOrRemovedRows() {
        XCTAssertFalse(AgentCockpitHUDView.hasMembershipChurn(existing: ["a", "b"], incoming: ["b", "a"]))
        XCTAssertTrue(AgentCockpitHUDView.hasMembershipChurn(existing: ["a", "b"], incoming: ["a", "b", "c"]))
        XCTAssertTrue(AgentCockpitHUDView.hasMembershipChurn(existing: ["a", "b"], incoming: ["a"]))
    }

    func testAgentCockpitHUD_groupedRowsPreservingOrder_usesFirstSeenProjectOrder() {
        let rows = [
            makeHUDRow(id: "r1", project: "Beta", name: "B1", state: .active),
            makeHUDRow(id: "r2", project: "Alpha", name: "A1", state: .idle),
            makeHUDRow(id: "r3", project: "Beta", name: "B2", state: .idle)
        ]

        let grouped = AgentCockpitHUDView.groupedRowsPreservingOrder(rows)
        XCTAssertEqual(grouped.map(\.projectName), ["Beta", "Alpha"])
        XCTAssertEqual(grouped.first?.rows.map(\.id), ["r1", "r3"])
    }

    @MainActor
    func testWindowAutosave_marksWindowRestorableWhenAutosaveNameAlreadySet() {
        let autosaveName = "WindowAutosaveTests.\(UUID().uuidString)"
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setFrameAutosaveName(autosaveName)
        window.isRestorable = false

        let host = NSHostingView(rootView: WindowAutosave(name: autosaveName))
        host.frame = .zero
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(host)

        drainMainRunLoop()
        XCTAssertTrue(window.isRestorable)
    }

    @MainActor
    func testWindowAutosave_setsAutosaveNameWhenMissing() {
        let autosaveName = "WindowAutosaveTests.\(UUID().uuidString)"
        let window = NSWindow(
            contentRect: NSRect(x: 50, y: 50, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        XCTAssertEqual(window.frameAutosaveName, "")

        let host = NSHostingView(rootView: WindowAutosave(name: autosaveName))
        host.frame = .zero
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(host)

        drainMainRunLoop()
        drainMainRunLoop() // second drain: subagent workload queues extra main-thread work under full suite load
        XCTAssertEqual(window.frameAutosaveName, autosaveName)
        XCTAssertTrue(window.isRestorable)
    }

    @MainActor
    func testShouldRestorePinnedCockpitOnLaunch_trueWhenPinnedAndEnabled() {
        let suite = "AppWindowRouterTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled)
        defaults.set(true, forKey: PreferencesKey.Cockpit.hudPinned)

        XCTAssertTrue(AppWindowRouter.shouldRestorePinnedCockpitOnLaunch(defaults: defaults))
    }

    @MainActor
    func testShouldRestorePinnedCockpitOnLaunch_falseWhenUnpinnedOrDisabled() {
        let suite = "AppWindowRouterTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled)
        defaults.set(true, forKey: PreferencesKey.Cockpit.hudPinned)
        XCTAssertFalse(AppWindowRouter.shouldRestorePinnedCockpitOnLaunch(defaults: defaults))

        defaults.set(true, forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled)
        defaults.set(false, forKey: PreferencesKey.Cockpit.hudPinned)
        XCTAssertFalse(AppWindowRouter.shouldRestorePinnedCockpitOnLaunch(defaults: defaults))
    }

    private func makeHUDRow(id: String,
                            project: String,
                            name: String,
                            state: HUDLiveState,
                            lastActivityAt: Date? = Date()) -> HUDRow {
        HUDRow(
            id: id,
            source: .codex,
            agentType: .codex,
            projectName: project,
            displayName: name,
            liveState: state,
            preview: name,
            elapsed: "1m",
            lastSeenAt: Date(),
            itermSessionId: nil,
            revealURL: nil,
            tty: nil,
            termProgram: nil,
            lastActivityAt: lastActivityAt
        )
    }

    private func makeHUDGroup(id: String,
                              rows: [HUDRow],
                              activeCount: Int,
                              idleCount: Int,
                              freshIdleCount: Int,
                              staleIdleCount: Int) -> HUDGroup {
        HUDGroup(
            id: id,
            projectName: id,
            rows: rows,
            activeCount: activeCount,
            idleCount: idleCount,
            freshIdleCount: freshIdleCount,
            staleIdleCount: staleIdleCount
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

    func testMergeMetadata_doesNotInheritLoserGUIDWhenWinnerHasTTY() {
        // Winner has a TTY but no itermSessionId; loser has a GUID but no TTY.
        // The loser's GUID belongs to a different terminal session — it must not be inherited,
        // because the two-pass AppleScript will correctly use TTY-based focusing for the winner.
        let winner = makeMappedRow(tty: "/dev/ttys010", itermSessionId: nil)
        let loser  = makeMappedRow(tty: nil, itermSessionId: "GUID-FROM-OTHER-SESSION")
        let merged = AgentCockpitHUDView.mergeMetadata(into: winner, from: loser)
        XCTAssertNil(merged.itermSessionId)
        XCTAssertEqual(merged.tty, "/dev/ttys010")
    }

    func testMergeMetadata_inheritsLoserTerminalIdentityWhenWinnerHasNeither() {
        // Winner has neither TTY nor GUID; loser has both. The loser is the sole source
        // of terminal identity so both should be inherited together.
        let winner = makeMappedRow(tty: nil, itermSessionId: nil)
        let loser  = makeMappedRow(tty: "/dev/ttys020", itermSessionId: "GUID-LOSER")
        let merged = AgentCockpitHUDView.mergeMetadata(into: winner, from: loser)
        XCTAssertEqual(merged.itermSessionId, "GUID-LOSER")
        XCTAssertEqual(merged.tty, "/dev/ttys020")
    }

    func testMergeMetadata_winnerGUIDTakesPrecedenceOverLoser() {
        // Winner already has both TTY and GUID — loser values must not override either.
        let winner = makeMappedRow(tty: "/dev/ttys030", itermSessionId: "GUID-WINNER")
        let loser  = makeMappedRow(tty: "/dev/ttys031", itermSessionId: "GUID-LOSER")
        let merged = AgentCockpitHUDView.mergeMetadata(into: winner, from: loser)
        XCTAssertEqual(merged.itermSessionId, "GUID-WINNER")
        XCTAssertEqual(merged.tty, "/dev/ttys030")
    }

    func testNavigationConfidence_runtimeIDMatchIsNavigable() {
        let row = makeMappedRow(
            tty: nil,
            itermSessionId: nil,
            resolvedSessionID: "resolved-session",
            sessionID: "runtime-session",
            isDefinitiveMatch: false
        )
        let confidence = AgentCockpitHUDView.navigationConfidence(for: row)
        XCTAssertEqual(confidence, .runtimeID)
        XCTAssertTrue(confidence.isNavigable)
    }

    func testNavigationConfidence_cwdOnlyMatchIsNotNavigable() {
        let row = makeMappedRow(
            tty: nil,
            itermSessionId: nil,
            resolvedSessionID: "resolved-session",
            sessionID: nil,
            isDefinitiveMatch: false
        )
        let confidence = AgentCockpitHUDView.navigationConfidence(for: row)
        XCTAssertEqual(confidence, .cwdOnly)
        XCTAssertFalse(confidence.isNavigable)
    }

    func testNavigationConfidence_exactMatchIsNavigable() {
        let row = makeMappedRow(
            tty: nil,
            itermSessionId: nil,
            resolvedSessionID: "resolved-session",
            sessionID: "runtime-session",
            isDefinitiveMatch: true
        )
        let confidence = AgentCockpitHUDView.navigationConfidence(for: row)
        XCTAssertEqual(confidence, .exact)
        XCTAssertTrue(confidence.isNavigable)
    }

    func testNavigationConfidence_noResolvedSessionIsNone() {
        let row = makeMappedRow(
            tty: nil,
            itermSessionId: nil,
            resolvedSessionID: nil,
            sessionID: "runtime-session",
            isDefinitiveMatch: false
        )
        let confidence = AgentCockpitHUDView.navigationConfidence(for: row)
        XCTAssertEqual(confidence, .none)
        XCTAssertFalse(confidence.isNavigable)
    }

    // MARK: - mergeMetadata helpers

    private func makeMappedRow(tty: String?,
                               itermSessionId: String?,
                               resolvedSessionID: String? = nil,
                               sessionID: String? = nil,
                               isDefinitiveMatch: Bool = false) -> LegacyMappedRow {
        LegacyMappedRow(
            id: UUID().uuidString,
            source: .claude,
            title: "Test",
            liveState: .openIdle,
            lastSeenAt: nil,
            repo: "",
            date: nil,
            focusURL: nil,
            itermSessionId: itermSessionId,
            tty: tty,
            termProgram: nil,
            tabTitle: nil,
            resolvedSessionID: resolvedSessionID,
            sessionID: sessionID,
            logPath: nil,
            workingDirectory: nil,
            lastActivityAt: nil,
            idleReason: nil,
            isDefinitiveMatch: isDefinitiveMatch
        )
    }

    func testShouldSuppressTransientEmptyPublish_suppressesWhenRecentlyVisibleEvenIfCurrentlyHidden() {
        // When cockpit was recently visible but is now hidden (e.g. user switched apps),
        // an empty publish should still be suppressed to prevent a "No sessions" flash.
        XCTAssertTrue(
            CodexActiveSessionsModel.shouldSuppressTransientEmptyPublish(
                ui: [],
                cockpitVisible: false,
                cockpitRecentlyVisible: true,
                didProbeProcesses: false,
                didProbeITerm: false,
                registryHadPresences: false
            )
        )

        // When cockpit was neither visible nor recently visible, empty publish must not be suppressed.
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldSuppressTransientEmptyPublish(
                ui: [],
                cockpitVisible: false,
                cockpitRecentlyVisible: false,
                didProbeProcesses: false,
                didProbeITerm: false,
                registryHadPresences: false
            )
        )
    }

    func testShouldSuppressEmptyTransition_suppressesWhenTransitioningFromNonEmptyToEmpty() {
        // When cockpit previously had presences and now sees empty, suppress for up to 3 cycles.
        XCTAssertTrue(
            CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: true,
                hadPreviouslyPublishedPresences: true,
                cockpitIsOrWasVisible: true,
                consecutiveSuppressedCycles: 0
            )
        )
        XCTAssertTrue(
            CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: true,
                hadPreviouslyPublishedPresences: true,
                cockpitIsOrWasVisible: true,
                consecutiveSuppressedCycles: 2
            )
        )
        // After 3 consecutive suppressed cycles, allow the empty publish through.
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: true,
                hadPreviouslyPublishedPresences: true,
                cockpitIsOrWasVisible: true,
                consecutiveSuppressedCycles: 3
            )
        )
    }

    func testShouldSuppressEmptyTransition_doesNotSuppressWhenNoPriorPresences() {
        // First launch with no sessions — don't suppress, there's nothing to protect.
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: true,
                hadPreviouslyPublishedPresences: false,
                cockpitIsOrWasVisible: true,
                consecutiveSuppressedCycles: 0
            )
        )
    }

    func testShouldSuppressEmptyTransition_doesNotSuppressWhenCockpitHidden() {
        // Cockpit not visible — no need to prevent visual flicker.
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: true,
                hadPreviouslyPublishedPresences: true,
                cockpitIsOrWasVisible: false,
                consecutiveSuppressedCycles: 0
            )
        )
    }

    func testShouldSuppressEmptyTransition_doesNotSuppressWhenUIIsNonEmpty() {
        // Non-empty ui — nothing to suppress.
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: false,
                hadPreviouslyPublishedPresences: true,
                cockpitIsOrWasVisible: true,
                consecutiveSuppressedCycles: 0
            )
        )
    }

    func testShouldSuppressEmptyTransition_counterLifecycle() {
        // Simulates the increment/reset logic from refreshOnce().
        // Cycles 0..2 suppress; cycle 3 stops suppressing; non-empty resets.
        var counter = 0
        for cycle in 0..<3 {
            let suppress = CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: true,
                hadPreviouslyPublishedPresences: true,
                cockpitIsOrWasVisible: true,
                consecutiveSuppressedCycles: counter
            )
            XCTAssertTrue(suppress, "Expected suppression at cycle \(cycle)")
            counter += 1
        }
        // Cycle 3: cap reached, suppression stops.
        XCTAssertFalse(
            CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: true,
                hadPreviouslyPublishedPresences: true,
                cockpitIsOrWasVisible: true,
                consecutiveSuppressedCycles: counter
            )
        )
        // After a non-empty cycle, counter resets (caller sets to 0).
        counter = 0
        XCTAssertTrue(
            CodexActiveSessionsModel.shouldSuppressEmptyTransition(
                uiIsEmpty: true,
                hadPreviouslyPublishedPresences: true,
                cockpitIsOrWasVisible: true,
                consecutiveSuppressedCycles: counter
            )
        )
    }

    func testEffectiveITermTitleMaps_usesProbeDataForGuidOnlyResult() {
        // A successful probe with GUID titles but no TTY titles is not a failure.
        let fresh = CodexActiveSessionsModel.effectiveITermTitleMaps(
            didProbeITerm: true,
            probeTitleByTTY: [:],
            probeTitleBySessionGuid: ["guid-1": "Fresh"],
            cachedTitleByTTY: ["tty-old": "Stale TTY"],
            cachedTitleBySessionGuid: ["guid-1": "Stale GUID"]
        )
        XCTAssertTrue(fresh.tty.isEmpty)
        XCTAssertEqual(fresh.guid, ["guid-1": "Fresh"])
    }

    func testEffectiveITermTitleMaps_fallsToCacheWhenBothMapsEmpty() {
        // Both maps empty after probe → transient failure, use cache.
        let cached = CodexActiveSessionsModel.effectiveITermTitleMaps(
            didProbeITerm: true,
            probeTitleByTTY: [:],
            probeTitleBySessionGuid: [:],
            cachedTitleByTTY: ["tty-1": "Cached TTY"],
            cachedTitleBySessionGuid: ["guid-1": "Cached GUID"]
        )
        XCTAssertEqual(cached.tty, ["tty-1": "Cached TTY"])
        XCTAssertEqual(cached.guid, ["guid-1": "Cached GUID"])
    }

    func testEffectiveITermTitleMaps_usesProbeDataWhenNotProbed() {
        // Probe didn't run (deferred) — use whatever the caller passed (cached maps
        // are already substituted by performRefreshDiscovery in this case).
        let deferred = CodexActiveSessionsModel.effectiveITermTitleMaps(
            didProbeITerm: false,
            probeTitleByTTY: [:],
            probeTitleBySessionGuid: [:],
            cachedTitleByTTY: ["tty-1": "Should Not Use"],
            cachedTitleBySessionGuid: ["guid-1": "Should Not Use"]
        )
        XCTAssertTrue(deferred.tty.isEmpty)
        XCTAssertTrue(deferred.guid.isEmpty)
    }

    func testEffectiveITermTitleMaps_usesProbeDataWhenBothMapsPopulated() {
        // Normal case: probe returned both TTY and GUID maps.
        let normal = CodexActiveSessionsModel.effectiveITermTitleMaps(
            didProbeITerm: true,
            probeTitleByTTY: ["tty-1": "Fresh TTY"],
            probeTitleBySessionGuid: ["guid-1": "Fresh GUID"],
            cachedTitleByTTY: ["tty-1": "Stale"],
            cachedTitleBySessionGuid: ["guid-1": "Stale"]
        )
        XCTAssertEqual(normal.tty, ["tty-1": "Fresh TTY"])
        XCTAssertEqual(normal.guid, ["guid-1": "Fresh GUID"])
    }

    func testClaudeSessionLogCandidates_excludesFilesOlderThanRecencyCutoff() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectDir = tmp.appendingPathComponent("projects/-Users-test-MyProject")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let now = Date()
        let recentFile = projectDir.appendingPathComponent("recent00-0000-0000-0000-000000000001.jsonl")
        let oldFile    = projectDir.appendingPathComponent("oldfiled-0000-0000-0000-000000000002.jsonl")
        for file in [recentFile, oldFile] {
            try Data("{}".utf8).write(to: file)
        }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)],  ofItemAtPath: recentFile.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: oldFile.path)

        // With a 60 s cutoff only the recently-modified file should be returned.
        let candidates = CodexActiveSessionsModel.claudeSessionLogCandidates(
            cwd: "/Users/test/MyProject",
            claudeRoot: tmp.path,
            recencyCutoff: now.addingTimeInterval(-60)
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].path.hasSuffix("recent00-0000-0000-0000-000000000001.jsonl"))
    }

    func testActiveSubagentCounts_prefersResolvedParentAndIgnoresStaleCodexChildren() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parentLog = tmp.appendingPathComponent("rollout-2026-03-28T10-00-00-00000000-0000-0000-0000-000000000001.jsonl")
        let recentChildLog = tmp.appendingPathComponent("rollout-2026-03-28T10-01-00-00000000-0000-0000-0000-000000000002.jsonl")
        let staleChildLog = tmp.appendingPathComponent("rollout-2026-03-28T10-02-00-00000000-0000-0000-0000-000000000003.jsonl")
        for file in [parentLog, recentChildLog, staleChildLog] {
            try Data("{}".utf8).write(to: file)
        }

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parentLog.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: recentChildLog.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90)], ofItemAtPath: staleChildLog.path)

        let parentSession = Session(
            id: "parent-session",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: parentLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: "parent-runtime-id",
            parentSessionID: nil,
            subagentType: nil
        )
        let recentChildSession = Session(
            id: "child-recent",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: recentChildLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: "child-runtime-id-1",
            parentSessionID: "parent-runtime-id",
            subagentType: "thread_spawn"
        )
        let staleChildSession = Session(
            id: "child-stale",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: staleChildLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: "child-runtime-id-2",
            parentSessionID: "parent-runtime-id",
            subagentType: "thread_spawn"
        )

        let sessions = [parentSession, recentChildSession, staleChildSession]
        let sessionsByLogPath = Dictionary(uniqueKeysWithValues: sessions.map { session in
            let key = CodexActiveSessionsModel.logLookupKey(
                source: session.source,
                normalizedPath: CodexActiveSessionsModel.normalizePath(session.filePath)
            )
            return (key, session)
        })

        var presence = CodexActivePresence()
        presence.source = .codex
        presence.sessionId = recentChildSession.codexInternalSessionIDHint
        presence.sessionLogPath = recentChildLog.path
        presence.openSessionLogPaths = [recentChildLog.path, parentLog.path, staleChildLog.path]

        let counts = CodexActiveSessionsModel.activeSubagentCounts(
            presences: [presence],
            sessionsByLogPath: sessionsByLogPath,
            now: now,
            recentWriteWindow: 45,
            codexRuntimeStateDBURL: tmp.appendingPathComponent("missing.sqlite")
        )

        XCTAssertEqual(counts[parentSession.id], 1)
        XCTAssertNil(counts[recentChildSession.id])
    }

    func testActiveSubagentCounts_countsRecentClaudeSubagents() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let projectDir = tmp.appendingPathComponent("projects/-Users-test-MyProject")
        let parentLog = projectDir.appendingPathComponent("90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a.jsonl")
        let subagentsDir = projectDir
            .appendingPathComponent("90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a")
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: parentLog)

        let recentSubagent = subagentsDir.appendingPathComponent("agent-recent.jsonl")
        let oldSubagent = subagentsDir.appendingPathComponent("agent-old.jsonl")
        for file in [recentSubagent, oldSubagent] {
            try Data("{}".utf8).write(to: file)
        }

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: recentSubagent.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90)], ofItemAtPath: oldSubagent.path)

        let parentSession = Session(
            id: "claude-parent",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: parentLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: "90fb4e5c-9eb2-4db8-80ce-30a0728ccf7a",
            parentSessionID: nil,
            subagentType: nil
        )
        let key = CodexActiveSessionsModel.logLookupKey(
            source: .claude,
            normalizedPath: CodexActiveSessionsModel.normalizePath(parentSession.filePath)
        )

        var presence = CodexActivePresence()
        presence.source = .claude
        presence.sessionLogPath = parentLog.path

        let counts = CodexActiveSessionsModel.activeSubagentCounts(
            presences: [presence],
            sessionsByLogPath: [key: parentSession],
            now: now,
            recentWriteWindow: 45
        )

        XCTAssertEqual(counts[parentSession.id], 1)
    }

    func testActiveSubagentCounts_fallsBackToLiveCodexSessionMetaWhenIndexMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parentLog = tmp.appendingPathComponent("rollout-2026-03-28T17-59-21-019d371a-45f2-7443-a076-d68981630bf3.jsonl")
        let childLog = tmp.appendingPathComponent("rollout-2026-03-28T18-00-11-019d371b-06c0-79d1-ad85-17ba4e23290a.jsonl")

        try Data("""
        {"timestamp":"2026-03-29T00:59:41.003Z","type":"session_meta","payload":{"id":"019d371a-45f2-7443-a076-d68981630bf3","cwd":"/Users/alexm/Repository/Codex-History","source":"cli"}}
        """.utf8).write(to: parentLog)
        try Data("""
        {"timestamp":"2026-03-29T01:00:12.991Z","type":"session_meta","payload":{"id":"019d371b-06c0-79d1-ad85-17ba4e23290a","cwd":"/Users/alexm/Repository/Codex-History","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019d371a-45f2-7443-a076-d68981630bf3","depth":1}}}}}
        """.utf8).write(to: childLog)

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: parentLog.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: childLog.path)

        var presence = CodexActivePresence()
        presence.source = .codex
        presence.sessionId = "019d371a-45f2-7443-a076-d68981630bf3"
        presence.sessionLogPath = parentLog.path
        presence.openSessionLogPaths = [parentLog.path, childLog.path]

        let counts = CodexActiveSessionsModel.activeSubagentCounts(
            presences: [presence],
            sessionsByLogPath: [:],
            now: now,
            recentWriteWindow: 45,
            codexRuntimeStateDBURL: tmp.appendingPathComponent("missing.sqlite")
        )

        XCTAssertEqual(counts["019d371a-45f2-7443-a076-d68981630bf3"], 1)
    }

    func testActiveSubagentCounts_usesCodexRuntimeOpenEdgesForStaleChildren() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parentLog = tmp.appendingPathComponent("rollout-2026-03-28T17-59-21-019d371a-45f2-7443-a076-d68981630bf3.jsonl")
        let childLog = tmp.appendingPathComponent("rollout-2026-03-28T18-06-12-019d3720-8a6c-7561-9209-28e8b3ca1a9c.jsonl")
        try Data("{}".utf8).write(to: parentLog)
        try Data("{}".utf8).write(to: childLog)

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: parentLog.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: childLog.path)

        let parentSession = Session(
            id: "parent-db-id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: parentLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: "019d371a-45f2-7443-a076-d68981630bf3",
            parentSessionID: nil,
            subagentType: nil
        )
        let parentKey = CodexActiveSessionsModel.logLookupKey(
            source: .codex,
            normalizedPath: CodexActiveSessionsModel.normalizePath(parentSession.filePath)
        )

        var presence = CodexActivePresence()
        presence.source = .codex
        presence.sessionId = "019d371a-45f2-7443-a076-d68981630bf3"
        presence.sessionLogPath = parentLog.path
        presence.openSessionLogPaths = [parentLog.path, childLog.path]

        let dbURL = try makeCodexRuntimeStateDB(
            edges: [("019d371a-45f2-7443-a076-d68981630bf3", "019d3720-8a6c-7561-9209-28e8b3ca1a9c", "open")]
        )

        let counts = CodexActiveSessionsModel.activeSubagentCounts(
            presences: [presence],
            sessionsByLogPath: [parentKey: parentSession],
            now: now,
            recentWriteWindow: 45,
            codexRuntimeStateDBURL: dbURL
        )

        XCTAssertEqual(counts[parentSession.id], 1)
        XCTAssertEqual(counts["019d371a-45f2-7443-a076-d68981630bf3"], 1)
    }

    func testActiveSubagentCounts_usesCodexRuntimeOpenEdgesWhenPrimaryLogIsChild() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parentRuntimeID = "019d3fff-1111-7222-8333-a11111111111"
        let childRuntimeID = "019d3fff-2222-7333-8444-b22222222222"

        let parentLog = tmp.appendingPathComponent("rollout-2026-03-28T17-59-21-\(parentRuntimeID).jsonl")
        let childLog = tmp.appendingPathComponent("rollout-2026-03-28T18-06-12-\(childRuntimeID).jsonl")
        try Data("{}".utf8).write(to: parentLog)
        try Data("{}".utf8).write(to: childLog)

        let parentSession = Session(
            id: "parent-db-id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: parentLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: parentRuntimeID,
            parentSessionID: nil,
            subagentType: nil
        )
        let childSession = Session(
            id: "child-db-id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: childLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: childRuntimeID,
            parentSessionID: parentRuntimeID,
            subagentType: "thread_spawn"
        )
        let sessionsByLogPath = Dictionary(uniqueKeysWithValues: [parentSession, childSession].map { session in
            let key = CodexActiveSessionsModel.logLookupKey(
                source: session.source,
                normalizedPath: CodexActiveSessionsModel.normalizePath(session.filePath)
            )
            return (key, session)
        })

        var presence = CodexActivePresence()
        presence.source = .codex
        presence.sessionId = childRuntimeID
        presence.sessionLogPath = childLog.path
        presence.openSessionLogPaths = [childLog.path, parentLog.path]

        let dbURL = try makeCodexRuntimeStateDB(edges: [(parentRuntimeID, childRuntimeID, "open")])
        let counts = CodexActiveSessionsModel.activeSubagentCounts(
            presences: [presence],
            sessionsByLogPath: sessionsByLogPath,
            now: Date(),
            recentWriteWindow: 45,
            codexRuntimeStateDBURL: dbURL
        )

        XCTAssertEqual(counts[parentSession.id], 1)
        XCTAssertEqual(counts[parentRuntimeID], 1)
        XCTAssertNil(counts[childSession.id])
    }

    func testActiveSubagentCounts_honorsCODEXHOMEForRuntimeStateDB() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let codexHome = tmp.appendingPathComponent("custom-codex-home")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let parentRuntimeID = "019d3fff-aaaa-7555-8999-c33333333333"
        let childRuntimeID = "019d3fff-bbbb-7666-8aaa-d44444444444"
        let stateDBURL = codexHome.appendingPathComponent("state_2026-03-29.sqlite")
        _ = try makeCodexRuntimeStateDB(at: stateDBURL, edges: [(parentRuntimeID, childRuntimeID, "open")])

        let parentLog = tmp.appendingPathComponent("rollout-2026-03-28T17-59-21-\(parentRuntimeID).jsonl")
        try Data("{}".utf8).write(to: parentLog)

        let parentSession = Session(
            id: "parent-db-id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: parentLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: parentRuntimeID,
            parentSessionID: nil,
            subagentType: nil
        )
        let parentKey = CodexActiveSessionsModel.logLookupKey(
            source: .codex,
            normalizedPath: CodexActiveSessionsModel.normalizePath(parentSession.filePath)
        )

        var presence = CodexActivePresence()
        presence.source = .codex
        presence.sessionId = parentRuntimeID
        presence.sessionLogPath = parentLog.path

        let defaults = UserDefaults.standard
        let originalSessionsRootOverride = defaults.string(forKey: "SessionsRootOverride")
        defaults.removeObject(forKey: "SessionsRootOverride")
        defer {
            if let originalSessionsRootOverride {
                defaults.set(originalSessionsRootOverride, forKey: "SessionsRootOverride")
            } else {
                defaults.removeObject(forKey: "SessionsRootOverride")
            }
        }

        let counts = withEnvironmentVariable("CODEX_HOME", value: codexHome.path) {
            CodexActiveSessionsModel.activeSubagentCounts(
                presences: [presence],
                sessionsByLogPath: [parentKey: parentSession],
                now: Date(),
                recentWriteWindow: 45,
                codexRuntimeStateDBURL: nil
            )
        }

        XCTAssertEqual(counts[parentSession.id], 1)
        XCTAssertEqual(counts[parentRuntimeID], 1)
    }

    func testActiveSubagentCounts_respectsClosedCodexRuntimeEdges() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parentLog = tmp.appendingPathComponent("rollout-2026-03-28T17-59-21-019d371a-45f2-7443-a076-d68981630bf3.jsonl")
        let childLog = tmp.appendingPathComponent("rollout-2026-03-28T18-06-12-019d3720-8a6c-7561-9209-28e8b3ca1a9c.jsonl")
        try Data("{}".utf8).write(to: parentLog)
        try Data("{}".utf8).write(to: childLog)

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: parentLog.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: childLog.path)

        let parentSession = Session(
            id: "parent-db-id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: parentLog.path,
            eventCount: 0,
            events: [],
            codexInternalSessionIDHint: "019d371a-45f2-7443-a076-d68981630bf3",
            parentSessionID: nil,
            subagentType: nil
        )
        let parentKey = CodexActiveSessionsModel.logLookupKey(
            source: .codex,
            normalizedPath: CodexActiveSessionsModel.normalizePath(parentSession.filePath)
        )

        var presence = CodexActivePresence()
        presence.source = .codex
        presence.sessionId = "019d371a-45f2-7443-a076-d68981630bf3"
        presence.sessionLogPath = parentLog.path
        presence.openSessionLogPaths = [parentLog.path, childLog.path]

        let dbURL = try makeCodexRuntimeStateDB(
            edges: [("019d371a-45f2-7443-a076-d68981630bf3", "019d3720-8a6c-7561-9209-28e8b3ca1a9c", "closed")]
        )

        let counts = CodexActiveSessionsModel.activeSubagentCounts(
            presences: [presence],
            sessionsByLogPath: [parentKey: parentSession],
            now: now,
            recentWriteWindow: 45,
            codexRuntimeStateDBURL: dbURL
        )

        XCTAssertNil(counts[parentSession.id])
        XCTAssertNil(counts["019d371a-45f2-7443-a076-d68981630bf3"])
    }

    func testUnifiedMergedSessions_respectsEnablementFavoritesAndSortOrder() {
        let now = Date()
        let codex = makeFallbackSession(id: "codex-a", source: .codex, cwd: nil, modifiedAt: now)
        let claude = makeFallbackSession(id: "claude-z", source: .claude, cwd: nil, modifiedAt: now.addingTimeInterval(5))
        let hiddenGemini = makeFallbackSession(id: "gemini-hidden", source: .gemini, cwd: nil, modifiedAt: now.addingTimeInterval(-60))
        let favoriteKey = StarredSessionKey(source: .claude, id: claude.id)
        let work = UnifiedSessionIndexer.SessionAggregationWork(
            codexList: [codex],
            claudeList: [claude],
            geminiList: [hiddenGemini],
            opencodeList: [],
            copilotList: [],
            droidList: [],
            openclawList: [],
            cursorList: [],
            favoritesSnapshot: UnifiedSessionIndexer.FavoritesStore.Snapshot(legacyIDs: [], scopedKeys: [favoriteKey]),
            favoritesVersion: 1,
            enablement: UnifiedSessionIndexer.AgentEnablementSnapshot(
                codex: true,
                claude: true,
                gemini: false,
                openCode: false,
                copilot: false,
                droid: false,
                openClaw: false,
                cursor: false
            )
        )

        let merged = UnifiedSessionIndexer.mergedSessions(from: work)

        XCTAssertEqual(merged.map(\.id), ["claude-z", "codex-a"])
        XCTAssertEqual(merged.map(\.isFavorite), [true, false])
    }

    func testUnifiedMergedAggregationResult_isRejectedWhenFavoritesVersionIsStale() {
        let now = Date()
        let session = makeFallbackSession(id: "codex-a", source: .codex, cwd: nil, modifiedAt: now)
        let work = UnifiedSessionIndexer.SessionAggregationWork(
            codexList: [session],
            claudeList: [],
            geminiList: [],
            opencodeList: [],
            copilotList: [],
            droidList: [],
            openclawList: [],
            cursorList: [],
            favoritesSnapshot: UnifiedSessionIndexer.FavoritesStore.Snapshot(legacyIDs: [], scopedKeys: []),
            favoritesVersion: 3,
            enablement: UnifiedSessionIndexer.AgentEnablementSnapshot(
                codex: true,
                claude: false,
                gemini: false,
                openCode: false,
                copilot: false,
                droid: false,
                openClaw: false,
                cursor: false
            )
        )

        let result = UnifiedSessionIndexer.mergedAggregationResult(from: work)

        XCTAssertFalse(
            UnifiedSessionIndexer.shouldPublishAggregationResult(result, currentFavoritesVersion: 4)
        )
        XCTAssertTrue(
            UnifiedSessionIndexer.shouldPublishAggregationResult(result, currentFavoritesVersion: 3)
        )
    }

    @MainActor
    func testDebugRunManagedCommand_returnsOutputBeforeTimeout() async {
        let model = CodexActiveSessionsModel()

        let data = await model.debugRunManagedCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf ready"],
            timeout: 1
        )

        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "ready")
    }

    @MainActor
    func testDebugRunManagedCommand_returnsNilAfterTimeout() async {
        let model = CodexActiveSessionsModel()

        let data = await model.debugRunManagedCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 1"],
            timeout: 0.1
        )

        XCTAssertNil(data)
    }

    @MainActor
    func testDebugRunManagedCommand_replacedProbeDropsEarlierResult() async {
        let model = CodexActiveSessionsModel()

        let firstTask = Task { @MainActor in
            await model.debugRunManagedCommand(
                kind: .processDiscovery,
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 1; printf late"],
                timeout: 2
            )
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        let replacement = await model.debugRunManagedCommand(
            kind: .processDiscovery,
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf replacement"],
            timeout: 1
        )
        let first = await firstTask.value

        XCTAssertNil(first)
        XCTAssertEqual(replacement.map { String(decoding: $0, as: UTF8.self) }, "replacement")
    }

    @MainActor
    private func drainMainRunLoop() {
        let until = Date().addingTimeInterval(0.06)
        while Date() < until && RunLoop.main.run(mode: .default, before: until) {}
    }

    private func withEnvironmentVariable<T>(_ key: String,
                                            value: String,
                                            perform: () throws -> T) rethrows -> T {
        let previousValue = getenv(key).map { String(cString: $0) }
        setenv(key, value, 1)
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }
        return try perform()
    }

    private func makeCodexRuntimeStateDB(at dbURL: URL? = nil,
                                         edges: [(parent: String, child: String, status: String)]) throws -> URL {
        let dbURL = dbURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("codex-runtime-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "CodexActiveSessionsRegistryTests", code: 1)
        }
        defer { sqlite3_close(db) }

        let schemaSQL = """
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL PRIMARY KEY,
                status TEXT NOT NULL
            );
            """
        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexActiveSessionsRegistryTests", code: 2)
        }

        let insertSQL = "INSERT INTO thread_spawn_edges(parent_thread_id, child_thread_id, status) VALUES(?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw NSError(domain: "CodexActiveSessionsRegistryTests", code: 3)
        }
        defer { sqlite3_finalize(stmt) }

        for edge in edges {
            sqlite3_bind_text(stmt, 1, edge.parent, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, edge.child, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, edge.status, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw NSError(domain: "CodexActiveSessionsRegistryTests", code: 4)
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        return dbURL
    }
}
