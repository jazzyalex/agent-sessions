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
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let binaryPath = makeTempExecutable(name: "pi-resolve-login")
        executor.responses[[shell, "-lic", "command -v pi || true"]] = CommandResult(stdout: "\(binaryPath)\n", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: "--session <path|id>\n--continue", stderr: "", exitCode: 0)

        let env = PiCLIEnvironment(executor: executor)
        XCTAssertEqual(env.resolveBinary(customPath: nil)?.path, binaryPath)
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
