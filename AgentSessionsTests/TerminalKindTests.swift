import XCTest
@testable import AgentSessions

final class TerminalKindTests: XCTestCase {

    // MARK: - TerminalKind.infer

    func testInferWarpPreviewFromBundleID() {
        let kind = TerminalKind.infer(termProgram: "WarpTerminal", cfBundleIdentifier: "dev.warp.Warp-Preview")
        XCTAssertEqual(kind, .warpPreview)
    }

    func testInferWarpStableFromBundleID() {
        let kind = TerminalKind.infer(termProgram: "WarpTerminal", cfBundleIdentifier: "dev.warp.Warp-Stable")
        XCTAssertEqual(kind, .warp)
    }

    func testInferWarpLegacyBundleID() {
        let kind = TerminalKind.infer(termProgram: "WarpTerminal", cfBundleIdentifier: "dev.warp.Warp")
        XCTAssertEqual(kind, .warp)
    }

    func testInferWarpPreviewFallbackFromTermProgram() {
        let kind = TerminalKind.infer(termProgram: "WarpTerminal", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .warpPreview)
    }

    func testInferITerm2() {
        let kind = TerminalKind.infer(termProgram: "iTerm.app", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .iterm2)
    }

    func testInferTerminalApp() {
        let kind = TerminalKind.infer(termProgram: "Apple_Terminal", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .terminalApp)
    }

    func testInferUnknownWhenBothNil() {
        let kind = TerminalKind.infer(termProgram: nil, cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .unknown)
    }

    func testBundleIDTakesPriorityOverTermProgram() {
        // TERM_PROGRAM says iTerm but bundle says Warp — bundle wins
        let kind = TerminalKind.infer(termProgram: "iTerm.app", cfBundleIdentifier: "dev.warp.Warp-Preview")
        XCTAssertEqual(kind, .warpPreview)
    }

    func testWarpStableBundleIdentifierMatchesInstalledApp() {
        XCTAssertEqual(TerminalKind.warp.bundleIdentifier, "dev.warp.Warp-Stable")
    }

    func testInferGhosttyFromBundleID() {
        let kind = TerminalKind.infer(termProgram: "ghostty", cfBundleIdentifier: "com.mitchellh.ghostty")
        XCTAssertEqual(kind, .ghostty)
    }

    func testInferGhosttyFromTermProgram() {
        let kind = TerminalKind.infer(termProgram: "ghostty", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .ghostty)
    }

    func testMactermBundleIdentityWinsOverGhosttyTermProgram() {
        XCTAssertEqual(TerminalKind.infer(termProgram: "ghostty", cfBundleIdentifier: "com.thdxg.macterm"), .macterm)
        XCTAssertEqual(TerminalKind.macterm.bundleIdentifier, "com.thdxg.macterm")
        XCTAssertEqual(TerminalKind.macterm.displayName, "Macterm")
        XCTAssertEqual(CodexLaunchMode.macterm.title, "Macterm")
    }

    func testGhosttyBundleIdentifierAndDisplayName() {
        XCTAssertEqual(TerminalKind.ghostty.bundleIdentifier, "com.mitchellh.ghostty")
        XCTAssertEqual(TerminalKind.ghostty.displayName, "Ghostty")
        XCTAssertEqual(CodexLaunchMode.ghostty.title, "Ghostty")
    }

    // MARK: - Ghostty AppleScript

    func testGhosttyScriptOpensWindowInWorkingDirectoryAndTypesCommand() {
        let script = AgentTerminalLauncher.ghosttyScriptLines()

        XCTAssertEqual(script.first, "on run argv")
        XCTAssertEqual(script.last, "end run")
        XCTAssertTrue(script.contains("tell application \"Ghostty\""))
        XCTAssertTrue(script.contains("set initial working directory of surfaceConfig to workingDirectory"))
        XCTAssertTrue(script.contains("set initial input of surfaceConfig to shellCommand & linefeed"))
        XCTAssertTrue(script.contains("new window with configuration surfaceConfig"))
    }

    @MainActor
    func testGhosttyScriptWaitKeepsMainActorResponsive() async throws {
        var started = false
        var finished = false
        let launch = Task {
            started = true
            try await AgentTerminalLauncher.runGhosttyAppleScript(["delay 2"])
            finished = true
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(started)
        XCTAssertFalse(finished, "The UI actor must run before osascript finishes")
        try await launch.value
    }

    func testGhosttyScriptPassesArgumentsWithoutInterpolation() async throws {
        let value = "a path with 'quotes' and \"double quotes\"; $(touch nope)"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        try await AgentTerminalLauncher.runGhosttyAppleScript([
            "on run argv",
            "do shell script \"printf '%s' \" & quoted form of (item 1 of argv) & \" > \" & quoted form of (item 2 of argv)",
            "end run"
        ], arguments: [value, output.path])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), value)
    }

    func testGhosttyScriptReportsCompatibilityAndUnderlyingError() async {
        do {
            try await AgentTerminalLauncher.runGhosttyAppleScript(["error \"permission denied fixture\""])
            XCTFail("Expected a launch error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AppleScript support"))
            XCTAssertTrue(error.localizedDescription.contains("permission denied fixture"))
        }
    }

    func testGhosttyScriptTimesOut() async {
        let start = Date()
        do {
            try await AgentTerminalLauncher.runGhosttyAppleScript(["delay 30"], timeout: 0.1)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        }
    }

    func testGhosttyScriptLargeOutputCannotFillPipes() async throws {
        try await AgentTerminalLauncher.runGhosttyAppleScript([
            "repeat 10000 times",
            "log \"stderr fixture\"",
            "end repeat",
            "do shell script \"/usr/bin/awk 'BEGIN { for (i=0; i<10000; i++) print \\\"output fixture\\\" }'\""
        ])
    }

    // MARK: - Warp tab config TOML

    func testWarpTabConfigUsesTerminalPane() {
        let toml = AgentTerminalLauncher.warpTabConfigTOML(
            configName: "agent-sessions-test",
            command: "'/usr/local/bin/codex' resume 'abc123'",
            directory: "/Users/test/project"
        )

        XCTAssertTrue(toml.contains(#"name = "agent-sessions-test""#))
        XCTAssertTrue(toml.contains(#"type = "terminal""#))
        XCTAssertTrue(toml.contains(#"directory = "/Users/test/project""#))
        XCTAssertTrue(toml.contains(#"commands = ["'/usr/local/bin/codex' resume 'abc123'"]"#))
    }

    func testWarpTabConfigEscapesTomlStrings() {
        let toml = AgentTerminalLauncher.warpTabConfigTOML(
            configName: "agent-sessions-escape",
            command: "echo \"hi\" && printf 'a\\b\nc\td\r'",
            directory: #"/tmp/dir "quote"\slash"#
        )

        XCTAssertTrue(toml.contains(#"directory = "/tmp/dir \"quote\"\\slash""#))
        XCTAssertTrue(toml.contains(#"commands = ["echo \"hi\" && printf 'a\\b\nc\td\r'"]"#))
    }
}

final class MactermLauncherTests: XCTestCase {
    private func fixture(script: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macterm test ' \" \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("control cli")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    func testClosestLocalProjectWinsAndRemoteProjectIsIgnored() throws {
        let data = Data(#"{"projects":[{"id":"parent","path":"/Users/test"},{"id":"repo","path":"/Users/test/repo"},{"id":"remote","path":"host:/Users/test/repo/sub"}]}"#.utf8)
        XCTAssertEqual(try AgentTerminalLauncher.mactermProjectID(in: data, workingDirectory: "/Users/test/repo/sub"), "repo")
        XCTAssertEqual(try AgentTerminalLauncher.mactermProjectID(in: data, workingDirectory: "/Users/test/repo"), "repo")
    }

    func testProjectPathMustMatchDirectoryBoundary() throws {
        let data = Data(#"{"projects":[{"id":"wrong","path":"/Users/test/repo"}]}"#.utf8)
        XCTAssertNil(try AgentTerminalLauncher.mactermProjectID(in: data, workingDirectory: "/Users/test/repository"))
    }

    func testDuplicateProjectFoldersFailInsteadOfPickingOne() {
        let data = Data(#"{"projects":[{"id":"one","path":"/Users/test/repo"},{"id":"two","path":"/Users/test/repo"}]}"#.utf8)
        XCTAssertThrowsError(try AgentTerminalLauncher.mactermProjectID(in: data, workingDirectory: "/Users/test/repo"))
    }

    func testMalformedProjectListFails() {
        XCTAssertThrowsError(try AgentTerminalLauncher.mactermProjectID(in: Data("{}".utf8), workingDirectory: "/tmp"))
    }

    func testCLIArgumentsAreNotEvaluatedByAShell() async throws {
        let (_, executable) = try fixture(script: "printf '%s\\0' \"$@\"\n")
        let arguments = ["tab", "new", "--run", "cd '/a folder' && agent --resume 'id'; $(touch should-not-run)"]
        let data = try await AgentTerminalLauncher.runMactermCLI(executable, arguments: arguments)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init), arguments)
    }

    func testCLIReportsUnderlyingFailure() async throws {
        let (_, executable) = try fixture(script: "printf 'control socket unavailable' >&2\nexit 2\n")
        do {
            _ = try await AgentTerminalLauncher.runMactermCLI(executable, arguments: [])
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("control socket unavailable"))
        }
    }

    func testCLIHasBoundedWaiting() async throws {
        let (_, executable) = try fixture(script: "exec /bin/sleep 30\n")
        let start = Date()
        do {
            _ = try await AgentTerminalLauncher.runMactermCLI(executable, arguments: [], timeout: 0.1)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not respond in time"))
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        }
    }

    @MainActor
    func testCLIWaitingDoesNotBlockTheUIActor() async throws {
        let (_, executable) = try fixture(script: "exec /bin/sleep 1\n")
        var finished = false
        let task = Task {
            _ = try await AgentTerminalLauncher.runMactermCLI(executable, arguments: [])
            finished = true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(finished)
        try await task.value
    }

    func testOpenTabPreservesNativeCommandAndProjectID() async throws {
        let (root, executable) = try fixture(script: "")
        let record = root.appendingPathComponent("arguments")
        let selected = root.appendingPathComponent("project-selected")
        let listing = String(decoding: try JSONSerialization.data(withJSONObject: ["projects": [["id": "local-project", "path": root.path]]]), as: UTF8.self)
        let script = """
        #!/bin/sh
        if [ "$1 $2" = "project list" ]; then
          printf '%s' \(ShellQuoting.quote(listing))
        elif [ "$1 $2" = "project select" ]; then
          printf '%s' "$3" > \(ShellQuoting.quote(selected.path))
          printf '{}'
        elif [ "$1 $2" = "tab new" ]; then
          if [ ! -f \(ShellQuoting.quote(selected.path)) ]; then
            printf 'project must be selected before its tab can run' >&2
            exit 4
          fi
          printf '%s\\0' "$@" > \(ShellQuoting.quote(record.path))
          printf '{}'
        else
          exit 3
        fi
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        let command = "cd \(ShellQuoting.quote(root.path)) && '/a binary' --session 'native-id'"
        try await AgentTerminalLauncher.openMactermTab(executable, shellCommand: command, workingDirectory: root.path)
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "local-project")
        let data = try Data(contentsOf: record)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init), ["tab", "new", "--project", "local-project", "--run", command, "--json"])
    }
}
