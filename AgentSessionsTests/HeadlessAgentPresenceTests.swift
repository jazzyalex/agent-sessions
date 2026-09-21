import XCTest
@testable import AgentSessions

final class CodexDesktopPresenceTests: XCTestCase {
    private let root = "/tmp/codex-desktop-presence/sessions"
    private let firstID = "00000000-0000-4000-8000-000000000001"
    private let secondID = "00000000-0000-4000-8000-000000000002"

    func testRecognizesRenamedAndSpaceContainingDesktopBackends() {
        let commands = [
            "/Applications/Codex.app/Contents/Resources/codex app-server",
            "/Applications/ChatGPT.app/Contents/Resources/codex -c features.example=true app-server --analytics-default-enabled",
            "/Applications/My Codex.app/Contents/Resources/codex app-server",
            "\"/Applications/My Codex.app/Contents/Resources/codex\" app-server"
        ]
        let infos = commands.enumerated().map {
            CodexActiveSessionsModel.PSCommandInfo(pid: $0.offset, tty: nil, command: $0.element)
        }
        XCTAssertEqual(CodexActiveSessionsModel.codexDesktopPIDs(from: infos), Set(0..<4))
    }

    func testRejectsCLIHelpersAndBackendPathPassedAsAnArgument() {
        let commands = [
            "/opt/homebrew/bin/codex app-server",
            "/Applications/Codex.app/Contents/MacOS/Codex",
            "/Applications/Codex.app/Contents/Resources/codex-code-mode-host app-server",
            "/Applications/Codex.app/Contents/Resources/codex resume example",
            "/usr/bin/cat /Applications/Codex.app/Contents/Resources/codex app-server"
        ]
        let infos = commands.enumerated().map {
            CodexActiveSessionsModel.PSCommandInfo(pid: $0.offset, tty: nil, command: $0.element)
        }
        XCTAssertTrue(CodexActiveSessionsModel.codexDesktopPIDs(from: infos).isEmpty)
    }

    func testDesktopWithoutTTYProducesOnePresencePerWritableThread() throws {
        let first = "\(root)/rollout-2026-09-21T10-00-00-\(firstID).jsonl"
        let second = "\(root)/rollout-2026-09-21T10-00-01-\(secondID).jsonl"
        let blob = """
        p42
        fcwd
        tDIR
        n/tmp
        f37
        au
        tREG
        n\(first)
        f48
        aw
        tREG
        n\(second)
        f53
        ar
        tREG
        n\(root)/rollout-2026-09-21T10-00-02-00000000-0000-4000-8000-000000000003.jsonl
        f54
        au
        tREG
        n\(root)-other/rollout-2026-09-21T10-00-03-00000000-0000-4000-8000-000000000004.jsonl
        """
        XCTAssertTrue(CodexActiveSessionsModel.parseLsofMachineOutput(blob, sessionsRoots: [root]).isEmpty)
        let infos = CodexActiveSessionsModel.parseLsofMachineOutput(
            blob, sessionsRoots: [root], source: .codex, desktopEligiblePIDs: [42]
        )
        let presences = CodexActiveSessionsModel.codexDesktopPresences(from: infos, eligiblePIDs: [42], now: Date())
        XCTAssertEqual(Set(presences.compactMap(\.sessionId)), [firstID, secondID])
        XCTAssertEqual(presences.count, 2)
        for presence in presences {
            XCTAssertEqual(presence.kind, "desktop")
            XCTAssertEqual(presence.pid, 42)
            XCTAssertNil(presence.tty)
            XCTAssertNil(presence.terminal)
            XCTAssertEqual(presence.openSessionLogPaths, [try XCTUnwrap(presence.sessionLogPath)])
        }
    }

    func testDesktopWithOnlyCwdOrReadOnlyLogIsNotPresent() {
        let blob = """
        p42
        fcwd
        tDIR
        n/tmp
        f37
        ar
        tREG
        n\(root)/rollout-2026-09-21T10-00-00-\(firstID).jsonl
        """
        let infos = CodexActiveSessionsModel.parseLsofMachineOutput(
            blob, sessionsRoots: [root], source: .codex, desktopEligiblePIDs: [42]
        )
        XCTAssertTrue(infos.isEmpty)
    }
}

final class CodexDesktopTurnStateTests: XCTestCase {
    private func event(_ type: String) -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"synthetic-turn\"}}\n"
    }

    func testStartAndProgressAreWorking() {
        for type in ["task_started", "item_completed"] {
            XCTAssertEqual(CodexDesktopTurnStateReader.classifyTail(Data(event(type).utf8)), .activeWorking)
        }
    }

    func testCompleteAndAbortOverrideEarlierWorkAndLaterSettings() {
        for type in ["task_complete", "turn_aborted"] {
            let tail = event("task_started") + event(type) + event("thread_settings_applied")
            XCTAssertEqual(CodexDesktopTurnStateReader.classifyTail(Data(tail.utf8)), .openIdle)
        }
    }

    func testNewTurnOverridesEarlierCompletion() {
        let tail = event("task_complete") + event("task_started")
        XCTAssertEqual(CodexDesktopTurnStateReader.classifyTail(Data(tail.utf8)), .activeWorking)
    }

    func testIgnoresPartialWritesMalformedJSONAndNestedEventText() {
        let incomplete = event("task_complete").dropLast()
        let tail = event("task_started") + "not-json\n" + incomplete
        XCTAssertEqual(CodexDesktopTurnStateReader.classifyTail(Data(tail.utf8)), .activeWorking)
        XCTAssertNil(CodexDesktopTurnStateReader.classifyTail(Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"task_started\"}}\n".utf8)))
        XCTAssertNil(CodexDesktopTurnStateReader.classifyTail(Data(event("task_started").utf8), startsAtLineBoundary: false))
        XCTAssertNil(CodexDesktopTurnStateReader.classifyTail(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\"}}\n".utf8)))
    }

    func testCachedTurnSurvivesQuietWorkAndLargeOutputThenCompletes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(event("task_started").utf8).write(to: url)
        // A long-running tool need not modify the rollout every few seconds.
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: url.path)
        var reader = CodexDesktopTurnStateReader()
        XCTAssertEqual(reader.state(path: url.path, pid: 42), .activeWorking)
        XCTAssertEqual(reader.state(path: url.path, pid: 42), .activeWorking)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(repeating: "x", count: 1024 * 1024 + 1) + "\n").utf8))
        XCTAssertEqual(reader.state(path: url.path, pid: 42), .activeWorking)
        try handle.write(contentsOf: Data(event("task_complete").utf8))
        XCTAssertEqual(reader.state(path: url.path, pid: 42), .openIdle)
    }

    func testCacheDoesNotCarryStateAcrossTruncationNewOwnerOrRemoval() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var reader = CodexDesktopTurnStateReader()
        try Data(event("task_started").utf8).write(to: url)
        XCTAssertEqual(reader.state(path: url.path, pid: 42), .activeWorking)
        try Data("{}\n".utf8).write(to: url)
        XCTAssertNil(reader.state(path: url.path, pid: 42))
        try Data(event("task_started").utf8).write(to: url)
        XCTAssertEqual(reader.state(path: url.path, pid: 42), .activeWorking)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(repeating: "x", count: 1024 * 1024 + 1) + "\n").utf8))
        XCTAssertNil(reader.state(path: url.path, pid: 99))
        reader.retain(paths: [])
        XCTAssertNil(reader.state(path: url.path, pid: 42))
        XCTAssertNil(reader.state(path: url.path + ".missing", pid: 42))
    }
}

/// Headless agent CLI runs (`claude -p` started by launchd, a script, or another app)
/// have no controlling terminal, so the terminal-shaped presence filters used to drop
/// them entirely. These cover the discriminators that admit them without letting the
/// Claude Desktop app — whose executables share the "claude" basename — leak in.
final class HeadlessAgentPresenceTests: XCTestCase {

    // Captured from `ps axww -o pid=,tty=,command=` on a machine running both
    // Claude Desktop and a headless triage run.
    private let desktopCommand = "/Applications/Claude.app/Contents/MacOS/Claude"
    private let desktopHelperCommand = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu-process --user-data-dir=/Users/alexm/Library/Application Support/Claude"
    private let headlessCommand = "claude -p --model haiku --output-format text --strict-mcp-config --disallowedTools Bash WebFetch WebSearch Task"
    private let interactiveCommand = "claude"

    // MARK: - App bundle discrimination

    func testIsAppBundleExecutable_rejectsClaudeDesktopAndItsHelpers() {
        XCTAssertTrue(CodexActiveSessionsModel.isAppBundleExecutable(desktopCommand))
        XCTAssertTrue(CodexActiveSessionsModel.isAppBundleExecutable(desktopHelperCommand))
    }

    func testIsAppBundleExecutable_acceptsCLIInvocations() {
        XCTAssertFalse(CodexActiveSessionsModel.isAppBundleExecutable(headlessCommand))
        XCTAssertFalse(CodexActiveSessionsModel.isAppBundleExecutable(interactiveCommand))
        XCTAssertFalse(CodexActiveSessionsModel.isAppBundleExecutable("/Users/alexm/.local/bin/claude -p"))
        XCTAssertFalse(CodexActiveSessionsModel.isAppBundleExecutable("/opt/homebrew/bin/node /Users/alexm/.local/share/claude/cli.js"))
    }

    /// A bundle path appearing as an *argument* must not disqualify a real CLI run —
    /// only the resolved executable position counts.
    func testIsAppBundleExecutable_ignoresBundlePathsInArguments() {
        XCTAssertFalse(CodexActiveSessionsModel.isAppBundleExecutable(
            "claude -p --add-dir /Applications/Claude.app/Contents/Resources"
        ))
    }

    func testIsAppBundleExecutable_seesThroughShellAndWrapperIndirection() {
        XCTAssertTrue(CodexActiveSessionsModel.isAppBundleExecutable(
            "/bin/zsh -c /Applications/Claude.app/Contents/MacOS/Claude"
        ))
        XCTAssertFalse(CodexActiveSessionsModel.isAppBundleExecutable(
            "/bin/zsh -c 'claude -p --model haiku'"
        ))
    }

    // MARK: - Headless PID selection

    func testHeadlessAgentPIDs_selectsNoTTYCLIRunsOnly() {
        let infos = [
            CodexActiveSessionsModel.PSCommandInfo(pid: 7272, tty: nil, command: headlessCommand),
            CodexActiveSessionsModel.PSCommandInfo(pid: 82249, tty: "ttys004", command: interactiveCommand),
            CodexActiveSessionsModel.PSCommandInfo(pid: 34383, tty: nil, command: desktopCommand),
            CodexActiveSessionsModel.PSCommandInfo(pid: 34392, tty: nil, command: desktopHelperCommand),
            CodexActiveSessionsModel.PSCommandInfo(pid: 900, tty: nil, command: "/usr/bin/ssh git@github.com")
        ]

        let pids = CodexActiveSessionsModel.headlessAgentPIDs(from: infos, needles: ["claude", "claude-code"])

        // Only the headless CLI run. The tty-bearing session is already covered by the
        // existing terminal path; the desktop app and its helpers must never appear.
        XCTAssertEqual(pids, [7272])
    }

    func testHeadlessAgentPIDs_isEmptyWhenOnlyDesktopIsRunning() {
        let infos = [
            CodexActiveSessionsModel.PSCommandInfo(pid: 34383, tty: nil, command: desktopCommand),
            CodexActiveSessionsModel.PSCommandInfo(pid: 34392, tty: nil, command: desktopHelperCommand)
        ]
        XCTAssertTrue(CodexActiveSessionsModel.headlessAgentPIDs(from: infos, needles: ["claude"]).isEmpty)
    }

    // MARK: - lsof admission

    /// Real `lsof -w -a -p <pid> -u <user> -nP -F pftn` output for a headless run:
    /// a cwd, stdin on a pipe, stdout/stderr redirected to files, and no CHR fd at all.
    private let headlessLsof = """
    p7272
    fcwd
    tDIR
    n/private/var/folders/k7/pnh4vv9j3gz/T/tmp.kcZaX0pSmy
    ftxt
    tREG
    n/Users/alexm/.local/share/claude/versions/2.1.219
    f0
    tPIPE
    n
    f1
    tREG
    n/private/var/folders/k7/pnh4vv9j3gz/T/tmp.kcZaX0pSmy/agent-stdout.txt
    f3
    tKQUEUE
    ncount=0, state=0x10
    """

    func testParseLsof_dropsHeadlessPIDByDefault() {
        let out = CodexActiveSessionsModel.parseLsofMachineOutput(
            headlessLsof,
            sessionsRoots: [NSHomeDirectory() + "/.claude"],
            source: .claude
        )
        // Unchanged behavior when the caller has not vetted the PID.
        XCTAssertTrue(out.isEmpty)
    }

    func testParseLsof_keepsHeadlessPIDWhenVetted() throws {
        let out = CodexActiveSessionsModel.parseLsofMachineOutput(
            headlessLsof,
            sessionsRoots: [NSHomeDirectory() + "/.claude"],
            source: .claude,
            headlessEligiblePIDs: [7272]
        )

        let info = try XCTUnwrap(out[7272])
        XCTAssertNil(info.tty)
        XCTAssertEqual(info.cwd, "/private/var/folders/k7/pnh4vv9j3gz/T/tmp.kcZaX0pSmy")
        // No session log fd — Claude CLI does not hold its transcript open, so the cwd
        // is what the caller later resolves the JSONL from.
        XCTAssertNil(info.sessionLogPath)
    }

    func testParseLsof_vettingDoesNotAdmitPIDsWithoutCwdOrLog() {
        let noCwd = """
        p7272
        ftxt
        tREG
        n/Users/alexm/.local/share/claude/versions/2.1.219
        f0
        tPIPE
        n
        """
        let out = CodexActiveSessionsModel.parseLsofMachineOutput(
            noCwd,
            sessionsRoots: [NSHomeDirectory() + "/.claude"],
            source: .claude,
            headlessEligiblePIDs: [7272]
        )
        XCTAssertTrue(out.isEmpty)
    }

    func testParseLsof_ttyBearingPIDStillAdmittedWithoutVetting() throws {
        let ttyLsof = """
        p82249
        fcwd
        tDIR
        n/Users/alexm/Repository/Codex-History
        f0
        tCHR
        n/dev/ttys004
        """
        let out = CodexActiveSessionsModel.parseLsofMachineOutput(
            ttyLsof,
            sessionsRoots: [NSHomeDirectory() + "/.claude"],
            source: .claude
        )

        let info = try XCTUnwrap(out[82249])
        XCTAssertEqual(info.tty, "/dev/ttys004")
    }

    // MARK: - cwd -> transcript resolution

    /// The triage job runs in `mktemp -d`, and Claude encodes the cwd by replacing "/"
    /// with "-". This is the link that turns a headless presence into a real session row.
    func testClaudeSessionLogCandidates_resolvesTempWorkdirTranscript() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("headless-presence-\(UUID().uuidString)")
        let cwd = "/private/var/folders/k7/pnh4vv9j3gz/T/tmp.kcZaX0pSmy"
        let projectDir = root
            .appendingPathComponent("projects")
            .appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = UUID().uuidString
        let transcript = projectDir.appendingPathComponent("\(sessionID).jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let candidates = CodexActiveSessionsModel.claudeSessionLogCandidates(
            cwd: cwd,
            claudeRoot: root.path,
            recencyCutoff: Date().addingTimeInterval(-60)
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.sessionID, sessionID)
    }
}
