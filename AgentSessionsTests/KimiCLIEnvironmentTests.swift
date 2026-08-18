import XCTest
import Darwin
@testable import AgentSessions

final class KimiCLIEnvironmentTests: XCTestCase {
    /// The literal help text emitted by kimi 0.31.1. The capability gate is a
    /// token scan over this, so the exact punctuation matters: `-S, --session
    /// [id]` must yield `--session`, and the optional-value brackets must not
    /// swallow it.
    private let realHelp = """
      -V, --version                 output the version number
      -S, --session [id]            Resume a session. With ID: resume that session. Without ID:
      -c, --continue                Continue the previous session for the working directory. (default:
      -y, --yolo                    Auto-approve regular tool calls; the agent may still ask questions.
      -m, --model <model>           LLM model alias to use for this invocation. Defaults to
      -p, --prompt <prompt>         Run one prompt non-interactively and print the response.
      --add-dir <dir>               Add an additional workspace directory for this session. Can be
      -h, --help                    Show help.
    """

    func testProbeParsesRealKimiSessionAndContinueFlags() {
        let binaryPath = makeTempExecutable(name: "kimi-probe-ok")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "0.31.1", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        switch KimiCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "0.31.1")
            XCTAssertTrue(probe.supportsSession, "-S, --session [id] must register as --session")
            XCTAssertTrue(probe.supportsContinue)
            XCTAssertEqual(probe.binaryURL.path, binaryPath)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    /// `--add-dir` also contains "dir" in angle brackets and `--session-dir`
    /// exists on other agents; neither may be mistaken for `--session`.
    func testProbeDoesNotTreatSessionDirAsSessionSupport() {
        let binaryPath = makeTempExecutable(name: "kimi-probe-session-dir")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "0.31.1", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: "--session-dir <path>\n--continue", stderr: "", exitCode: 0)

        switch KimiCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertFalse(probe.supportsSession)
            XCTAssertTrue(probe.supportsContinue)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testProbeFailsWhenBinaryIsMissing() {
        let env = KimiCLIEnvironment(executor: MockExecutor())

        switch env.probe(customPath: "/nonexistent/path/to/kimi") {
        case .success(let probe):
            XCTFail("expected failure, got \(probe)")
        case .failure(let error):
            XCTAssertEqual(error.localizedDescription, "Kimi Code CLI executable not found.")
        }
    }

    func testResolveBinaryUsesLoginShellCandidate() {
        let executor = MockExecutor()
        let binaryPath = makeTempExecutable(name: "kimi-resolve-login")
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        executor.loginShellExecutable = binaryPath
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        XCTAssertEqual(KimiCLIEnvironment(executor: executor).resolveBinary(customPath: nil)?.path, binaryPath)
    }

    /// Kimi is a `#!/usr/bin/env node` script, so a Finder-launched app — whose
    /// PATH has no Homebrew in it — cannot run the probe at all. See #58, which
    /// reported this for Pi.
    func testProbeRetriesUnderTheLoginShellPathWhenTheInheritedOneFails() {
        let binaryPath = makeTempExecutable(name: "kimi-probe-path")
        let executor = MockExecutor()
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        let envFailure = CommandResult(stdout: "", stderr: "env: node: No such file or directory\n", exitCode: 127)
        executor.responses[[binaryPath, "--version"]] = envFailure
        executor.responses[[binaryPath, "--help"]] = envFailure

        _ = KimiCLIEnvironment(executor: executor).probe(customPath: binaryPath)

        let retried = executor.environments(forCommandContaining: "--help").compactMap { $0?["PATH"] }
        XCTAssertFalse(retried.isEmpty, "a failed probe must be retried with a widened PATH")
        XCTAssertTrue(retried.allSatisfy { $0.contains("/opt/homebrew/bin") },
                      "retry PATH lost the login-shell entries: \(retried)")
    }

    /// A probe that never executed is not evidence that Kimi lacks resume flags.
    /// Recording it as "supports nothing" is what makes the resume actions go
    /// quiet, and the verdict is cached.
    func testProbeFailsLoudlyWhenTheCLICouldNotExecute() {
        let binaryPath = makeTempExecutable(name: "kimi-probe-broken")
        let executor = MockExecutor()
        let envFailure = CommandResult(stdout: "", stderr: "env: node: No such file or directory\n", exitCode: 127)
        executor.responses[[binaryPath, "--version"]] = envFailure
        executor.responses[[binaryPath, "--help"]] = envFailure

        switch KimiCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTFail("expected failure, got success with session=\(probe.supportsSession)")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("node"),
                          "error should surface the real reason: \(error.localizedDescription)")
        }
    }

    /// A binary whose help cannot be read still probes, but advertises nothing —
    /// the coordinator then refuses rather than emitting a flag the CLI may not
    /// accept.
    func testProbeSurvivesUnreadableHelp() {
        let binaryPath = makeTempExecutable(name: "kimi-probe-no-help")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "0.31.1", stderr: "", exitCode: 0)

        switch KimiCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertFalse(probe.supportsSession)
            XCTAssertFalse(probe.supportsContinue)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    /// The #58 case end to end: a Node CLI that cannot start under the PATH a
    /// Finder-launched app inherits, and does start once the probe widens it.
    /// The other tests pin "a retry happened" and "a retry can succeed"
    /// separately — this is the one that fails if the two do not join up.
    func testKimiProbeRecoversUnderTheWidenedPath() {
        let binaryPath = makeTempExecutable(name: "kimi-probe-recovers")
        let executor = MockExecutor()
        executor.needsHomebrewOnPath = true
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "0.31.1", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        switch KimiCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "0.31.1")
            XCTAssertTrue(probe.supportsSession)
            XCTAssertTrue(probe.supportsContinue)
        case .failure(let error):
            XCTFail("Finder-launched probe never recovered: \(error)")
        }
    }

    private final class MockExecutor: CommandExecuting {
        var responses: [[String]: CommandResult] = [:]
        var loginShellPATH = "/usr/bin:/bin"
        var loginShellExecutable: String?
        private(set) var calls: [(command: [String], environment: [String: String]?)] = []
        /// Models a `#!/usr/bin/env node` CLI: it cannot start unless the
        /// environment it is given can find its interpreter.
        var needsHomebrewOnPath = false

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            try run(command, cwd: cwd, environment: nil)
        }

        /// Answers the login-shell discovery call whatever exact script the
        /// probe sends, and records the environment each command was given.
        func run(_ command: [String], cwd: URL?, environment: [String: String]?) throws -> CommandResult {
            calls.append((command, environment))
            if command.count == 3, command[1] == "-lic" {
                var out = "\(CLIProbeEnvironment.pathMarker.begin)\(loginShellPATH)\(CLIProbeEnvironment.pathMarker.end)\n"
                if let loginShellExecutable {
                    out += "\(CLIProbeEnvironment.whichMarker.begin)\(loginShellExecutable)\(CLIProbeEnvironment.whichMarker.end)\n"
                }
                return CommandResult(stdout: out, stderr: "", exitCode: 0)
            }
            if needsHomebrewOnPath, environment?["PATH"]?.contains("/opt/homebrew/bin") != true {
                return CommandResult(stdout: "", stderr: "env: node: No such file or directory\n", exitCode: 127)
            }
            return responses[command] ?? CommandResult(stdout: "", stderr: "", exitCode: 0)
        }

        func environments(forCommandContaining argument: String) -> [[String: String]?] {
            calls.filter { $0.command.contains(argument) }.map(\.environment)
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
