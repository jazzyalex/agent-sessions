import XCTest
@testable import AgentSessions

final class CodexStatusProbeSuppressionTests: XCTestCase {

    // MARK: - UsageAuthState-based suppression

    /// I3: `.expired` joins `.signedOut` / `.cliNotInstalled` as suppress-worthy
    /// because an expired-token re-auth prompt hangs the /status probe exactly
    /// like a signed-out login screen.
    func testSuppressesWhenSignedOutExpiredOrCliMissing() {
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(.signedOut))
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(.expired))
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(.cliNotInstalled))
    }

    func testDoesNotSuppressOtherStates() {
        for s in [UsageAuthState.ok, .unknown, .needsSetup] {
            XCTAssertFalse(CodexStatusService.shouldSuppressStatusProbe(s))
        }
    }

    // MARK: - Authoritative CLI-status suppression (I1)

    /// The authoritative `codex login status` probe never reports a false
    /// `.signedOut`, so a definitive signed-out / missing-CLI answer suppresses
    /// the /status tmux probe immediately, regardless of a stale auth state.
    func testSuppressesOnAuthoritativeSignedOutOrMissingCLI() {
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(cliStatus: .signedOut))
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(cliStatus: .cliMissing))
    }

    /// Signed-in or ambiguous (`.unknown`) CLI status must never suppress — the
    /// probe is exactly what fetches usage in the ambiguous/no-data case.
    func testDoesNotSuppressOnSignedInOrAmbiguousCLIStatus() {
        XCTAssertFalse(CodexStatusService.shouldSuppressStatusProbe(cliStatus: .signedIn))
        XCTAssertFalse(CodexStatusService.shouldSuppressStatusProbe(cliStatus: .unknown))
    }

    // MARK: - Capture script vs. Codex startup menus

    /// Codex 0.160 opens on an "Update available" menu whose default is
    /// "Update now". The probe must launch with the update check disabled so
    /// the prompt is reachable, and the reset text must not keep the closing
    /// parenthesis when the pane line has trailing padding.
    func testCaptureScriptDisablesUpdateCheckAndParsesPaddedResetLine() throws {
        let fake = try makeFakeCodex(mode: "ok")
        let result = try runCodexStatusCapture(fakeCodexDirectory: fake)

        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        let args = try String(contentsOf: fake.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertEqual(args, "-c\ncheck_for_update_on_startup=false\n")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let weekly = try XCTUnwrap(json["weekly"] as? [String: Any])
        XCTAssertEqual(weekly["pct_left"] as? Int, 95)
        XCTAssertEqual(weekly["resets"] as? String, "9:14 AM on 18 Oct")
    }

    /// If a startup menu still shows, the probe must stop without typing into
    /// it: `/status` + Enter would confirm the selected "Update now" option.
    func testCaptureScriptStopsAtUpdateMenuWithoutSendingInput() throws {
        let fake = try makeFakeCodex(mode: "menu")
        let result = try runCodexStatusCapture(fakeCodexDirectory: fake)

        XCTAssertEqual(result.status, 16, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("startup_prompt_blocked"), result.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.appendingPathComponent("input.txt").path),
                       "the fake menu received a submitted line")
    }

    private func makeFakeCodex(mode: String) throws -> URL {
        try XCTSkipUnless(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }, "tmux is not installed")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("as-fake-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let script = """
        #!/bin/bash
        dir="$(cd "$(dirname "$0")" && pwd)"
        printf '%s\\n' "$@" > "$dir/args.txt"
        if [[ "$(cat "$dir/mode")" == "menu" ]]; then
          echo "  Update available · 0.1.0 → 0.2.0"
          echo "› 1. Update now (runs \\`npm install -g @openai/codex\\`)"
          echo "  2. Skip"
          IFS= read -r line; echo "got:$line" > "$dir/input.txt"; sleep 30; exit 0
        fi
        echo ">_ OpenAI Codex (v0.0.0)"
        echo "› "
        IFS= read -r line
        echo "  Weekly limit:  [####] 95% left (resets 9:14 AM on 18 Oct)   "
        sleep 30
        """
        let binary = directory.appendingPathComponent("codex")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        return directory
    }

    private func runCodexStatusCapture(fakeCodexDirectory: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentSessions")
            .appendingPathComponent("Resources")
            .appendingPathComponent("codex_status_capture.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_BIN"] = fakeCodexDirectory.appendingPathComponent("codex").path
        environment["WORKDIR"] = fakeCodexDirectory.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
