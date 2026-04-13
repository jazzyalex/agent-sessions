import XCTest
import Darwin
@testable import AgentSessions

final class CursorCLIEnvironmentTests: XCTestCase {
    func testProbeParsesHelpForResumeAndContinueFlags() {
        let binaryPath = makeTempExecutable(name: "cursor-probe-ok")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "cursor-agent 1.2.3", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: "--resume [chatId]\n--continue", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "agent", "--help"]] = CommandResult(stdout: "", stderr: "", exitCode: 0)

        let env = CursorCLIEnvironment(executor: executor)
        let result = env.probe(customPath: binaryPath)

        switch result {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "cursor-agent 1.2.3")
            XCTAssertTrue(probe.supportsResume)
            XCTAssertTrue(probe.supportsContinue)
            XCTAssertEqual(probe.binaryURL.path, binaryPath)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testProbeReturnsFailureWhenVersionCommandFails() {
        let binaryPath = makeTempExecutable(name: "cursor-probe-fail")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "", stderr: "boom", exitCode: 1)

        let env = CursorCLIEnvironment(executor: executor)
        let result = env.probe(customPath: binaryPath)

        switch result {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "unknown")
            XCTAssertEqual(probe.binaryURL.path, binaryPath)
            XCTAssertFalse(probe.supportsResume)
            XCTAssertFalse(probe.supportsContinue)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testResolveBinaryPrefersFunctionalAgentOverCursorShim() {
        let executor = MockExecutor()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let agentBinaryPath = makeTempExecutable(name: "cursor-resolve-agent")
        executor.responses[[shell, "-lic", "command -v agent || true"]] = CommandResult(stdout: "\(agentBinaryPath)\n", stderr: "", exitCode: 0)
        executor.responses[[agentBinaryPath, "--help"]] = CommandResult(stdout: "--resume [chatId]\n--continue", stderr: "", exitCode: 0)
        executor.responses[[agentBinaryPath, "agent", "--help"]] = CommandResult(stdout: "", stderr: "", exitCode: 0)

        let cursorBinaryPath = makeTempExecutable(name: "cursor-resolve-cursor")
        executor.responses[[shell, "-lic", "command -v cursor || true"]] = CommandResult(stdout: "\(cursorBinaryPath)\n", stderr: "", exitCode: 0)
        executor.responses[[cursorBinaryPath, "--help"]] = CommandResult(stdout: "No Cursor IDE installation found", stderr: "", exitCode: 1)
        executor.responses[[cursorBinaryPath, "agent", "--help"]] = CommandResult(stdout: "", stderr: "No Cursor IDE installation found", exitCode: 1)

        let env = CursorCLIEnvironment(executor: executor)
        let resolved = env.resolveBinary(customPath: nil)

        XCTAssertEqual(resolved?.path, agentBinaryPath)
    }

    func testResolveBinaryFallsBackToCursorShimWhenAgentIsUnavailable() {
        let executor = MockExecutor()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cursorBinaryPath = makeTempExecutable(name: "cursor-resolve-cursor-only")
        executor.responses[[shell, "-lic", "command -v agent || true"]] = CommandResult(stdout: "", stderr: "", exitCode: 0)
        executor.responses[[shell, "-lic", "command -v cursor || true"]] = CommandResult(stdout: "\(cursorBinaryPath)\n", stderr: "", exitCode: 0)
        executor.responses[[cursorBinaryPath, "--help"]] = CommandResult(stdout: "--resume [chatId]\n--continue", stderr: "", exitCode: 0)
        executor.responses[[cursorBinaryPath, "agent", "--help"]] = CommandResult(stdout: "", stderr: "", exitCode: 0)

        let env = CursorCLIEnvironment(executor: executor)
        let resolved = env.resolveBinary(customPath: nil)

        XCTAssertEqual(resolved?.path, cursorBinaryPath)
    }

    func testResolveBinaryAcceptsCandidateWithContinueOnlySupport() {
        let executor = MockExecutor()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let agentBinaryPath = makeTempExecutable(name: "cursor-resolve-continue-only")
        executor.responses[[shell, "-lic", "command -v agent || true"]] = CommandResult(stdout: "\(agentBinaryPath)\n", stderr: "", exitCode: 0)
        executor.responses[[shell, "-lic", "command -v cursor || true"]] = CommandResult(stdout: "", stderr: "", exitCode: 0)
        executor.responses[[agentBinaryPath, "--help"]] = CommandResult(stdout: "--continue", stderr: "", exitCode: 0)
        executor.responses[[agentBinaryPath, "agent", "--help"]] = CommandResult(stdout: "", stderr: "", exitCode: 0)

        let env = CursorCLIEnvironment(executor: executor)
        let resolved = env.resolveBinary(customPath: nil)

        XCTAssertEqual(resolved?.path, agentBinaryPath)
    }

    func testProbeReportsUnsupportedAutoDetectedCLI() {
        let executor = MockExecutor()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let agentBinaryPath = makeTempExecutable(name: "cursor-resolve-unsupported")
        executor.responses[[shell, "-lic", "command -v agent || true"]] = CommandResult(stdout: "\(agentBinaryPath)\n", stderr: "", exitCode: 0)
        executor.responses[[shell, "-lic", "command -v cursor || true"]] = CommandResult(stdout: "", stderr: "", exitCode: 0)
        executor.responses[[agentBinaryPath, "--version"]] = CommandResult(stdout: "cursor-agent 0.1.0", stderr: "", exitCode: 0)
        executor.responses[[agentBinaryPath, "--help"]] = CommandResult(stdout: "old cursor help", stderr: "", exitCode: 0)
        executor.responses[[agentBinaryPath, "agent", "--help"]] = CommandResult(stdout: "", stderr: "", exitCode: 0)

        let env = CursorCLIEnvironment(executor: executor)
        let result = env.probe(customPath: nil)

        switch result {
        case .success(let probe):
            XCTAssertEqual(probe.binaryURL.path, agentBinaryPath)
            XCTAssertEqual(probe.versionString, "cursor-agent 0.1.0")
            XCTAssertFalse(probe.supportsResume)
            XCTAssertFalse(probe.supportsContinue)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    private final class MockExecutor: CommandExecuting {
        var responses: [[String]: CommandResult] = [:]

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            if let response = responses[command] {
                return response
            }
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
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
