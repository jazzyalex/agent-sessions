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
