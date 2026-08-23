import XCTest
import Darwin
@testable import AgentSessions

/// Probe coverage for the Devin CLI, mirroring `GrokCLIEnvironmentTests`.
///
/// `DevinCLIEnvironment` was rebuilt on the shared `CLIProbeEnvironment` in
/// `4365d721` because the version merged in #56 had no reference to it and
/// reinherited the whole #58 class: a probe that could not execute returned
/// success with every capability false, there was no PATH widening, and the
/// login shell was asked first rather than last. Nothing pinned any of that,
/// which is why the regression was possible in the first place.
final class DevinCLIEnvironmentTests: XCTestCase {
    /// Transcribed from `devin --help` at CLI 3000.3.27 (0becb483). Note what it
    /// does *not* say: `--continue` continues the most recent conversation, with
    /// no directory qualifier — unlike Kimi's and Grok's, where the
    /// "directory-scoped" reading this project once carried is true.
    private let realHelp = """
    -c, --continue       Continue the most recent conversation.
    -r, --resume [<SESSION_ID>]
                         Resume a conversation. With an ID, resume that
                         session; without one, pick interactively.
    """

    func testProbeParsesResumeAndContinueFlags() {
        let binaryPath = makeTempExecutable(name: "devin-probe-ok")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "3000.3.27", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        switch DevinCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "3000.3.27")
            XCTAssertTrue(probe.supportsResume)
            XCTAssertTrue(probe.supportsContinue)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    /// The #60 blocker, pinned: a probe that never ran is not evidence that
    /// Devin lacks resume flags. Reporting success with both capabilities false
    /// is what let one failed probe disable resume for good, because the cache
    /// only refreshes while the resolved path is empty.
    func testProbeFailsLoudlyWhenTheCLICouldNotExecute() {
        let binaryPath = makeTempExecutable(name: "devin-probe-broken")
        let executor = MockExecutor()
        let failure = CommandResult(stdout: "", stderr: "dyld: Library not loaded\n", exitCode: 127)
        executor.responses[[binaryPath, "--version"]] = failure
        executor.responses[[binaryPath, "--help"]] = failure

        switch DevinCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTFail("expected failure, got success with resume=\(probe.supportsResume)")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("dyld"),
                          "error should surface the real reason: \(error.localizedDescription)")
        }
    }

    func testResolveBinaryUsesLoginShellCandidate() {
        let executor = MockExecutor()
        let binaryPath = makeTempExecutable(name: "devin-resolve-login")
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        executor.loginShellExecutable = binaryPath
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        XCTAssertEqual(DevinCLIEnvironment(executor: executor).resolveBinary(customPath: nil)?.path, binaryPath)
    }

    /// A Finder-launched app inherits a PATH with no Homebrew or npm prefix on
    /// it. Whatever Devin shells out to inherits that PATH, so a probe that
    /// fails under it has to be retried with the login shell's.
    func testProbeRetriesUnderTheLoginShellPathWhenTheInheritedOneFails() {
        let binaryPath = makeTempExecutable(name: "devin-probe-path")
        let executor = MockExecutor()
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        let envFailure = CommandResult(stdout: "", stderr: "env: node: No such file or directory\n", exitCode: 127)
        executor.responses[[binaryPath, "--version"]] = envFailure
        executor.responses[[binaryPath, "--help"]] = envFailure

        _ = DevinCLIEnvironment(executor: executor).probe(customPath: binaryPath)

        let retried = executor.environments(forCommandContaining: "--help").compactMap { $0?["PATH"] }
        XCTAssertFalse(retried.isEmpty, "a failed probe must be retried with a widened PATH")
        XCTAssertTrue(retried.allSatisfy { $0.contains("/opt/homebrew/bin") },
                      "retry PATH lost the login-shell entries: \(retried)")
    }

    /// The two halves joined up: a CLI that cannot start under the inherited
    /// PATH and does start once the probe widens it. The tests above pin "a
    /// retry happened" and "a good probe parses" separately; this is the one
    /// that fails if they do not meet.
    func testProbeRecoversUnderTheWidenedPath() {
        let binaryPath = makeTempExecutable(name: "devin-probe-recovers")
        let executor = MockExecutor()
        executor.needsHomebrewOnPath = true
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "3000.3.27", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        switch DevinCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "3000.3.27")
            XCTAssertTrue(probe.supportsResume)
        case .failure(let error):
            XCTFail("Finder-launched probe never recovered: \(error)")
        }
    }

    /// A help text advertising only the safe fallback must not be read as
    /// supporting `--resume`. The guide calls this one out by name: a nonempty
    /// session id is not evidence that the installed binary takes an id.
    func testHelpAdvertisingOnlyContinueDoesNotClaimResume() {
        let binaryPath = makeTempExecutable(name: "devin-probe-continue-only")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "3000.0.1", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(
            stdout: "-c, --continue       Continue the most recent conversation.\n", stderr: "", exitCode: 0)

        switch DevinCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertFalse(probe.supportsResume, "help never mentioned --resume")
            XCTAssertTrue(probe.supportsContinue)
        case .failure(let error):
            XCTFail("a binary advertising one real flag is a usable probe: \(error)")
        }
    }

    private final class MockExecutor: CommandExecuting {
        var responses: [[String]: CommandResult] = [:]
        var loginShellPATH = "/usr/bin:/bin"
        var loginShellExecutable: String?
        private(set) var calls: [(command: [String], environment: [String: String]?)] = []
        /// Models a CLI that cannot start unless the environment it is given can
        /// find its interpreter.
        var needsHomebrewOnPath = false

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            try run(command, cwd: cwd, environment: nil)
        }

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
