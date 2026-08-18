import XCTest
import Darwin
@testable import AgentSessions

/// Grok's shipping CLI is a native binary, so it does not hit the
/// `#!/usr/bin/env node` shebang failure that #58 reported for Pi. It still runs
/// under whatever PATH a Finder-launched app inherits, and it still caches
/// whatever the probe concluded — so both halves of the #58 fix apply.
final class GrokCLIEnvironmentTests: XCTestCase {
    private let realHelp = """
    -r, --resume [<SESSION_ID_OR_TITLE>]  Resume a session by ID or title
    -c, --continue                        Continue the most recent session
    """

    func testProbeParsesResumeAndContinueFlags() {
        let binaryPath = makeTempExecutable(name: "grok-probe-ok")
        let executor = MockExecutor()
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "1.0.0", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        switch GrokCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "1.0.0")
            XCTAssertTrue(probe.supportsResume)
            XCTAssertTrue(probe.supportsContinue)
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testResolveBinaryUsesLoginShellCandidate() {
        let executor = MockExecutor()
        let binaryPath = makeTempExecutable(name: "grok-resolve-login")
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        executor.loginShellExecutable = binaryPath
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        XCTAssertEqual(GrokCLIEnvironment(executor: executor).resolveBinary(customPath: nil)?.path, binaryPath)
    }

    /// A Finder-launched app inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`.
    /// Homebrew is not on it, and a Grok packaged as a Node script could not run
    /// its interpreter at all.
    func testProbeRunsCLIWithTheLoginShellPath() {
        let binaryPath = makeTempExecutable(name: "grok-probe-path")
        let executor = MockExecutor()
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        executor.responses[[binaryPath, "--version"]] = CommandResult(stdout: "1.0.0", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = CommandResult(stdout: realHelp, stderr: "", exitCode: 0)

        _ = GrokCLIEnvironment(executor: executor).probe(customPath: binaryPath)

        let probeEnvs = executor.environments(forCommandContaining: "--help")
        XCTAssertFalse(probeEnvs.isEmpty, "expected --help to run with an explicit environment")
        for path in probeEnvs.map({ $0?["PATH"] ?? "" }) {
            XCTAssertTrue(path.contains("/opt/homebrew/bin"), "probe PATH lost the login-shell entries: \(path)")
        }
    }

    /// A probe that never executed is not evidence that Grok lacks resume flags.
    /// Recording it as "supports nothing" is what makes the resume actions go
    /// quiet, and the verdict is cached.
    func testProbeFailsLoudlyWhenTheCLICouldNotExecute() {
        let binaryPath = makeTempExecutable(name: "grok-probe-broken")
        let executor = MockExecutor()
        let failure = CommandResult(stdout: "", stderr: "dyld: Library not loaded\n", exitCode: 127)
        executor.responses[[binaryPath, "--version"]] = failure
        executor.responses[[binaryPath, "--help"]] = failure

        switch GrokCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTFail("expected failure, got success with resume=\(probe.supportsResume)")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("dyld"),
                          "error should surface the real reason: \(error.localizedDescription)")
        }
    }

    /// A cache written by a probe that could not execute Grok names a real
    /// binary with every capability false. Trusting it disables Copy Resume
    /// Command forever, since the cache is only refreshed while the resolved
    /// path is empty.
    @MainActor
    func testCopyCommandPlanDiscardsACacheThatAdvertisesNoCapabilities() throws {
        let suite = "GrokCLIEnvironmentTests.poisonedCache"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = GrokSettings.makeForTesting(defaults: defaults)

        settings.setResolvedBinary(makeTempExecutable(name: "grok-poisoned"),
                                   supportsResume: false,
                                   supportsContinue: false)

        let plan = try XCTUnwrap(settings.copyCommandPlan(sessionID: "session_abc"),
                                 "a failed probe must not silently disable Copy Resume Command")
        XCTAssertEqual(plan.binary, GrokCLIEnvironment.binaryName)
        XCTAssertTrue(settings.resolvedBinaryPath.isEmpty, "the unusable cache entry should be cleared")
    }

    private final class MockExecutor: CommandExecuting {
        var responses: [[String]: CommandResult] = [:]
        var loginShellPATH = "/usr/bin:/bin"
        var loginShellExecutable: String?
        private(set) var calls: [(command: [String], environment: [String: String]?)] = []

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
