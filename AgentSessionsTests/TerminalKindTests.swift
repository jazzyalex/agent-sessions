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
