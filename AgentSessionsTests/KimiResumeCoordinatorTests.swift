import XCTest
@testable import AgentSessions

@MainActor
final class KimiResumeCoordinatorTests: XCTestCase {
    private let binary = URL(fileURLWithPath: "/usr/local/bin/kimi")

    private func probe(supportsSession: Bool = true,
                       supportsContinue: Bool = true) -> KimiCLIEnvironment.ProbeResult {
        .init(versionString: "0.29.1",
              binaryURL: binary,
              supportsSession: supportsSession,
              supportsContinue: supportsContinue)
    }

    private func coordinator(_ env: MockEnvironment, _ launcher: MockLauncher) -> KimiResumeCoordinator {
        KimiResumeCoordinator(env: env, builder: KimiResumeCommandBuilder(), launcher: launcher)
    }

    func testResumeUsesSessionIDWhenSupported() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .success(probe())), launcher)
            .resumeInTerminal(input: KimiResumeInput(sessionID: "session_9eb1bf57",
                                                     workingDirectory: nil,
                                                     binaryOverride: nil))

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.strategy, .sessionByID)
        XCTAssertEqual(launcher.commands.first, "'/usr/local/bin/kimi' --session 'session_9eb1bf57'")
    }

    /// The working directory is what makes `--continue` resolve to the right
    /// session, so it must be prepended for both strategies.
    func testResumeChangesToWorkingDirectoryFirst() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .success(probe())), launcher)
            .resumeInTerminal(input: KimiResumeInput(sessionID: "session_1",
                                                     workingDirectory: URL(fileURLWithPath: "/tmp/my project"),
                                                     binaryOverride: nil))

        XCTAssertTrue(result.launched)
        XCTAssertEqual(launcher.commands.first,
                       "cd '/tmp/my project' && '/usr/local/bin/kimi' --session 'session_1'")
    }

    func testResumeFallsBackToContinueWithoutSessionID() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .success(probe())), launcher)
            .resumeInTerminal(input: KimiResumeInput(sessionID: nil,
                                                     workingDirectory: nil,
                                                     binaryOverride: nil))

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.strategy, .continueMostRecent)
        XCTAssertEqual(launcher.commands.first, "'/usr/local/bin/kimi' --continue")
    }

    /// An older CLI that does not advertise `--session` still resumes, just
    /// less precisely.
    func testResumeFallsBackToContinueWhenSessionUnsupported() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .success(probe(supportsSession: false))), launcher)
            .resumeInTerminal(input: KimiResumeInput(sessionID: "session_1",
                                                     workingDirectory: nil,
                                                     binaryOverride: nil))

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.strategy, .continueMostRecent)
        XCTAssertEqual(launcher.commands.first, "'/usr/local/bin/kimi' --continue")
    }

    func testSessionOnlyPolicyReturnsFailureWithoutSessionID() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .success(probe())), launcher)
            .resumeInTerminal(input: KimiResumeInput(sessionID: nil, workingDirectory: nil, binaryOverride: nil),
                              policy: .sessionOnly)

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.strategy, .none)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(launcher.commands.isEmpty)
    }

    func testMissingBinarySurfacesProbeError() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .failure(.binaryNotFound)), launcher)
            .resumeInTerminal(input: KimiResumeInput(sessionID: "session_1",
                                                     workingDirectory: nil,
                                                     binaryOverride: nil))

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.strategy, .none)
        XCTAssertEqual(result.error, "Kimi Code CLI executable not found.")
        XCTAssertTrue(launcher.commands.isEmpty)
    }

    func testDryRunReturnsCommandWithoutLaunching() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .success(probe())), launcher)
            .resumeInTerminal(input: KimiResumeInput(sessionID: "session_1",
                                                     workingDirectory: nil,
                                                     binaryOverride: nil),
                              dryRun: true)

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.command, "'/usr/local/bin/kimi' --session 'session_1'")
        XCTAssertTrue(launcher.commands.isEmpty)
    }

    /// When the terminal itself refuses the `--session` launch, retry with
    /// `--continue` rather than leaving the user with nothing.
    func testLaunchFailureFallsBackToContinue() async {
        let launcher = MockLauncher(failFirstLaunch: true)
        let result = await coordinator(MockEnvironment(result: .success(probe())), launcher)
            .resumeInTerminal(input: KimiResumeInput(sessionID: "session_1",
                                                     workingDirectory: nil,
                                                     binaryOverride: nil))

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.strategy, .continueMostRecent)
        XCTAssertEqual(launcher.commands, ["'/usr/local/bin/kimi' --continue"])
    }

    private final class MockEnvironment: KimiCLIEnvironmentProviding {
        let result: Result<KimiCLIEnvironment.ProbeResult, KimiCLIEnvironment.ProbeError>

        init(result: Result<KimiCLIEnvironment.ProbeResult, KimiCLIEnvironment.ProbeError>) {
            self.result = result
        }

        func probe(customPath: String?) -> Result<KimiCLIEnvironment.ProbeResult, KimiCLIEnvironment.ProbeError> {
            result
        }
    }

    private final class MockLauncher: KimiTerminalLaunching {
        private(set) var commands: [String] = []
        private var failFirstLaunch: Bool

        init(failFirstLaunch: Bool = false) {
            self.failFirstLaunch = failFirstLaunch
        }

        struct LaunchFailure: Error {}

        func launchInTerminal(_ package: KimiResumeCommandBuilder.CommandPackage) throws {
            if failFirstLaunch {
                failFirstLaunch = false
                throw LaunchFailure()
            }
            commands.append(package.shellCommand)
        }
    }
}
