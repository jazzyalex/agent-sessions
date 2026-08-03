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
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let binaryPath = makeTempExecutable(name: "kimi-resolve-login")
        executor.responses[[shell, "-lic", "command -v kimi || true"]] = CommandResult(stdout: "\(binaryPath)\n", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        XCTAssertEqual(KimiCLIEnvironment(executor: executor).resolveBinary(customPath: nil)?.path, binaryPath)
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

    private final class MockExecutor: CommandExecuting {
        var responses: [[String]: CommandResult] = [:]

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            responses[command] ?? CommandResult(stdout: "", stderr: "", exitCode: 0)
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
