import XCTest
@testable import AgentSessions

@MainActor
final class PiResumeCoordinatorTests: XCTestCase {
    private let binary = URL(fileURLWithPath: "/usr/local/bin/pi")

    private func probe(supportsSession: Bool = true,
                       supportsResume: Bool = true,
                       supportsContinue: Bool = true) -> PiCLIEnvironment.ProbeResult {
        .init(versionString: "0.74.0",
              binaryURL: binary,
              supportsSession: supportsSession,
              supportsResume: supportsResume,
              supportsContinue: supportsContinue)
    }

    private func coordinator(_ env: MockEnvironment, _ launcher: MockLauncher) -> PiResumeCoordinator {
        PiResumeCoordinator(env: env, builder: PiResumeCommandBuilder(), launcher: launcher)
    }

    func testResumeUsesSessionIDWhenSupported() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .success(probe())), launcher)
            .resumeInTerminal(input: PiResumeInput(sessionID: "sess-1",
                                                   workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                                                   binaryOverride: nil,
                                                   sessionDirectory: nil))

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.strategy, .sessionByID)
        XCTAssertEqual(launcher.commands.first, "cd '/tmp/project' && '/usr/local/bin/pi' --session 'sess-1'")
    }

    /// A launch failure means the terminal refused, which a different command
    /// cannot fix — the command reaches osascript as an opaque argv item, and
    /// the Warp path fails only on filesystem or routing errors. Retrying with
    /// `--continue` would, on the rare success, resume an unrelated session
    /// while reporting success.
    func testLaunchFailureReportsTheErrorInsteadOfResumingSomethingElse() async {
        let launcher = MockLauncher(failFirstLaunch: true)
        let result = await coordinator(MockEnvironment(result: .success(probe())), launcher)
            .resumeInTerminal(input: PiResumeInput(sessionID: "sess-1",
                                                   workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                                                   binaryOverride: nil,
                                                   sessionDirectory: nil))

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.strategy, .sessionByID)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(launcher.commands.isEmpty, "must not have launched a second, different command")
    }

    /// The same must hold for the `--resume` strategy, which Pi reaches when the
    /// CLI advertises `--resume` but not `--session`. Pi's removed fallback
    /// covered both, so both need pinning.
    func testLaunchFailureAfterResumeByIDAlsoReportsRatherThanRetrying() async {
        let launcher = MockLauncher(failFirstLaunch: true)
        let result = await coordinator(MockEnvironment(result: .success(probe(supportsSession: false))), launcher)
            .resumeInTerminal(input: PiResumeInput(sessionID: "sess-1",
                                                   workingDirectory: nil,
                                                   binaryOverride: nil,
                                                   sessionDirectory: nil))

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.strategy, .resumeByID)
        XCTAssertTrue(launcher.commands.isEmpty, "must not have launched a second, different command")
    }

    func testMissingBinarySurfacesProbeError() async {
        let launcher = MockLauncher()
        let result = await coordinator(MockEnvironment(result: .failure(.binaryNotFound)), launcher)
            .resumeInTerminal(input: PiResumeInput(sessionID: "sess-1",
                                                   workingDirectory: nil,
                                                   binaryOverride: nil,
                                                   sessionDirectory: nil))

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.strategy, .none)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(launcher.commands.isEmpty)
    }

    private final class MockEnvironment: PiCLIEnvironmentProviding {
        let result: Result<PiCLIEnvironment.ProbeResult, PiCLIEnvironment.ProbeError>

        init(result: Result<PiCLIEnvironment.ProbeResult, PiCLIEnvironment.ProbeError>) {
            self.result = result
        }

        func probe(customPath: String?) -> Result<PiCLIEnvironment.ProbeResult, PiCLIEnvironment.ProbeError> {
            result
        }
    }

    private final class MockLauncher: PiTerminalLaunching {
        private(set) var commands: [String] = []
        private var failFirstLaunch: Bool

        init(failFirstLaunch: Bool = false) {
            self.failFirstLaunch = failFirstLaunch
        }

        struct LaunchFailure: Error {}

        func launchInTerminal(_ package: PiResumeCommandBuilder.CommandPackage) throws {
            if failFirstLaunch {
                failFirstLaunch = false
                throw LaunchFailure()
            }
            commands.append(package.shellCommand)
        }
    }
}
