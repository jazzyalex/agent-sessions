import XCTest
import Darwin
@testable import AgentSessions

final class PiCLIEnvironmentTests: XCTestCase {
    func testProbeParsesPiSessionAndContinueFlags() {
        let binaryPath = makeTempExecutable(name: "pi-probe-ok")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "0.74.0", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: "--session <path|id>\n--resume\n--continue", stderr: "", exitCode: 0)

        let env = PiCLIEnvironment(executor: executor)
        let result = env.probe(customPath: binaryPath)

        switch result {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "0.74.0")
            XCTAssertTrue(probe.supportsSession)
            XCTAssertTrue(probe.supportsResume)
            XCTAssertTrue(probe.supportsContinue)
            XCTAssertEqual(probe.binaryURL.path, binaryPath)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testProbeDoesNotTreatSessionDirAsSessionResumeSupport() {
        let binaryPath = makeTempExecutable(name: "pi-probe-session-dir")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "0.74.0", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: "--session-dir <path>\n--continue", stderr: "", exitCode: 0)

        let env = PiCLIEnvironment(executor: executor)
        let result = env.probe(customPath: binaryPath)

        switch result {
        case .success(let probe):
            XCTAssertFalse(probe.supportsSession)
            XCTAssertFalse(probe.supportsResume)
            XCTAssertTrue(probe.supportsContinue)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testResolveBinaryUsesLoginShellCandidate() {
        let executor = MockExecutor()
        let binaryPath = makeTempExecutable(name: "pi-resolve-login")
        executor.loginShellResponse = CommandResult(
            stdout: """
            \(CLIProbeEnvironment.pathMarker.begin)/opt/homebrew/bin:/usr/bin:/bin\(CLIProbeEnvironment.pathMarker.end)
            \(CLIProbeEnvironment.whichMarker.begin)\(binaryPath)\(CLIProbeEnvironment.whichMarker.end)
            """,
            stderr: "",
            exitCode: 0
        )
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: "--session <path|id>\n--continue", stderr: "", exitCode: 0)

        let env = PiCLIEnvironment(executor: executor)
        XCTAssertEqual(env.resolveBinary(customPath: nil)?.path, binaryPath)
    }

    private final class MockExecutor: CommandExecuting {
        var responses: [[String]: CommandResult] = [:]
        /// Answers the login-shell discovery call whatever script the probe sends.
        var loginShellResponse: CommandResult?

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            if command.count == 3, command[1] == "-lic", let loginShellResponse {
                return loginShellResponse
            }
            return responses[command] ?? CommandResult(stdout: "", stderr: "", exitCode: 0)
        }
    }

    private func makeTempExecutable(name: String) -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let file = dir.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        _ = chmod(file.path, 0o755)
        return file.path
    }
}

// MARK: - Finder-launch environment (issue #58)

extension PiCLIEnvironmentTests {
    /// Finder-launched apps inherit `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`.
    /// Pi ships as a `#!/usr/bin/env node` script, so probing it with that PATH
    /// dies with `env: node: No such file or directory` before Pi ever runs.
    /// The probe must therefore hand the child a PATH that can find node.
    func testProbeRunsCLIWithAPathThatCanResolveNode() {
        let binaryPath = makeTempExecutable(name: "pi-probe-path")
        let executor = RecordingExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "0.84.2", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: "--session <path|id>", stderr: "", exitCode: 0)
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"

        let env = PiCLIEnvironment(executor: executor)
        _ = env.probe(customPath: binaryPath)

        let probeEnvs = executor.environments(forCommandContaining: "--help")
        XCTAssertFalse(probeEnvs.isEmpty, "expected --help to run with an explicit environment")
        for path in probeEnvs.map({ $0?["PATH"] ?? "" }) {
            XCTAssertTrue(path.contains("/opt/homebrew/bin"),
                          "probe PATH lost the login-shell entries: \(path)")
        }
    }

    /// A probe that never executed is not evidence that Pi lacks resume flags.
    /// Reporting it as success-with-no-capabilities is what made the resume
    /// coordinator answer "Pi CLI does not advertise required flags".
    func testProbeFailsLoudlyWhenTheCLICouldNotExecute() {
        let binaryPath = makeTempExecutable(name: "pi-probe-broken")
        let executor = RecordingExecutor()
        let envFailure = CommandResult(stdout: "",
                                       stderr: "env: node: No such file or directory\n",
                                       exitCode: 127)
        executor.responses[[binaryPath, "--version"]] = envFailure
        executor.responses[[binaryPath, "--help"]] = envFailure

        let env = PiCLIEnvironment(executor: executor)

        switch env.probe(customPath: binaryPath) {
        case let .success(probe):
            XCTFail("expected failure, got success with session=\(probe.supportsSession)")
        case let .failure(error):
            XCTAssertTrue(error.localizedDescription.contains("node"),
                          "error should surface the real reason: \(error.localizedDescription)")
        }
    }

    /// `command -v` answers on stdout. Login shells print banners, MOTDs and
    /// version-manager chatter on stderr; merging the two lets a banner line
    /// become the "resolved binary path".
    func testLoginShellDiscoveryIgnoresShellBanners() {
        let executor = RecordingExecutor()
        let binaryPath = makeTempExecutable(name: "pi-resolve-banner")
        executor.loginShellStdout = "\(binaryPath)\n"
        executor.loginShellStderr = "Welcome to zsh!\nnvm: using node v22\n"
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: "--session <path|id>", stderr: "", exitCode: 0)

        let env = PiCLIEnvironment(executor: executor)
        XCTAssertEqual(env.resolveBinary(customPath: nil)?.path, binaryPath)
    }

    /// Records the environment each command was given, and answers the
    /// login-shell discovery call whatever exact script the probe sends.
    private final class RecordingExecutor: CommandExecuting {
        var responses: [[String]: CommandResult] = [:]
        var loginShellPATH = "/usr/bin:/bin"
        var loginShellStdout: String?
        var loginShellStderr: String = ""
        private(set) var calls: [(command: [String], environment: [String: String]?)] = []

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            try run(command, cwd: cwd, environment: nil)
        }

        func run(_ command: [String], cwd: URL?, environment: [String: String]?) throws -> CommandResult {
            calls.append((command, environment))
            if command.count == 3, command[1] == "-lic" {
                return CommandResult(stdout: loginShellScriptOutput(), stderr: loginShellStderr, exitCode: 0)
            }
            return responses[command] ?? CommandResult(stdout: "", stderr: "", exitCode: 0)
        }

        func environments(forCommandContaining argument: String) -> [[String: String]?] {
            calls.filter { $0.command.contains(argument) }.map(\.environment)
        }

        private func loginShellScriptOutput() -> String {
            var out = "\(CLIProbeEnvironment.pathMarker.begin)\(loginShellPATH)\(CLIProbeEnvironment.pathMarker.end)\n"
            if let loginShellStdout {
                out += "\(CLIProbeEnvironment.whichMarker.begin)\(loginShellStdout.trimmingCharacters(in: .whitespacesAndNewlines))\(CLIProbeEnvironment.whichMarker.end)\n"
            }
            return out
        }
    }
}
