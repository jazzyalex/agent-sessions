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

    func testInferGhosttyFromBundleID() {
        let kind = TerminalKind.infer(termProgram: nil, cfBundleIdentifier: "com.mitchellh.ghostty")
        XCTAssertEqual(kind, .ghostty)
    }

    func testInferGhosttyFromTermProgram() {
        let kind = TerminalKind.infer(termProgram: "ghostty", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .ghostty)
    }

    func testInferKittyFromBundleID() {
        let kind = TerminalKind.infer(termProgram: nil, cfBundleIdentifier: "net.kovidgoyal.kitty")
        XCTAssertEqual(kind, .kitty)
    }

    func testInferKittyFromTermProgram() {
        let kind = TerminalKind.infer(termProgram: "kitty", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .kitty)
    }

    func testInferWezTermFromBundleID() {
        let kind = TerminalKind.infer(termProgram: nil, cfBundleIdentifier: "com.github.wez.wezterm")
        XCTAssertEqual(kind, .wezTerm)
    }

    func testInferWezTermFromTermProgram() {
        let kind = TerminalKind.infer(termProgram: "WezTerm", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .wezTerm)
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

    func testGhosttyBundleIdentifierMatchesInstalledApp() {
        XCTAssertEqual(TerminalKind.ghostty.bundleIdentifier, "com.mitchellh.ghostty")
    }

    func testKittyBundleIdentifierMatchesInstalledApp() {
        XCTAssertEqual(TerminalKind.kitty.bundleIdentifier, "net.kovidgoyal.kitty")
    }

    func testWezTermBundleIdentifierMatchesInstalledApp() {
        XCTAssertEqual(TerminalKind.wezTerm.bundleIdentifier, "com.github.wez.wezterm")
    }

    func testInstalledTerminalKindsIncludesOnlyInstalledChoices() {
        let installed = Set(["com.apple.Terminal", "com.mitchellh.ghostty"])

        let kinds = installedTerminalKinds { installed.contains($0) }

        XCTAssertEqual(kinds, [.terminalApp, .ghostty])
    }

    func testInstalledTerminalKindsConsidersEverySupportedKind() {
        let expected = Set(TerminalKind.allCases.filter { $0.bundleIdentifier != nil })

        let kinds = installedTerminalKinds { _ in true }

        XCTAssertEqual(Set(kinds), expected)
    }

    func testInstalledTerminalKindsIncludesInstalledKitty() {
        let installed = Set(["net.kovidgoyal.kitty"])

        let names = installedTerminalKinds { installed.contains($0) }.map(\.displayName)

        XCTAssertEqual(names, ["Kitty"])
    }

    func testInstalledTerminalKindsIncludesInstalledWezTerm() {
        let installed = Set(["com.github.wez.wezterm"])

        let names = installedTerminalKinds { installed.contains($0) }.map(\.displayName)

        XCTAssertEqual(names, ["WezTerm"])
    }

    func testGhosttyColdStartSendsCompleteResumeCommandAsInitialInput() {
        let command = #"'/opt/homebrew/bin/codex' resume 'session id' && printf '%s' 'quoted value'"#

        let initialInput = AgentTerminalLauncher.ghosttyInitialInput(command)

        XCTAssertEqual(initialInput, "\(command)\n")
    }

    func testGhosttySurfaceCommandQuotesTheCompleteResumeCommand() {
        let command = #"'/opt/homebrew/bin/codex' resume 'session id' && printf '%s' 'quoted value'"#

        let surfaceCommand = AgentTerminalLauncher.ghosttySurfaceCommand(command)

        XCTAssertEqual(surfaceCommand, "/bin/zsh -lc \(ShellQuoting.quote(command))")
    }

    func testKittyArgumentsReuseAgentSessionsInstanceAndPreserveCommand() {
        let command = #"'/opt/homebrew/bin/pi' --session 'session id'"#

        let arguments = AgentTerminalLauncher.kittyArguments(
            shellCommand: command,
            cwd: "/Users/test/Project With Spaces"
        )

        XCTAssertEqual(arguments, [
            "--single-instance",
            "--instance-group=agent-sessions",
            "--directory=/Users/test/Project With Spaces",
            "/bin/zsh",
            "-lc",
            command
        ])
    }

    func testWezTermArgumentsOpenNewWindowAndPreserveCommand() {
        let command = #"'/opt/homebrew/bin/codex' resume 'session id'"#

        let arguments = AgentTerminalLauncher.wezTermArguments(
            shellCommand: command,
            cwd: "/Users/test/Project With Spaces"
        )

        XCTAssertEqual(arguments, [
            "start",
            "--cwd",
            "/Users/test/Project With Spaces",
            "--",
            "/bin/zsh",
            "-lc",
            command
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
