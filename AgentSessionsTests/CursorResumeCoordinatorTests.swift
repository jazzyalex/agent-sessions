import XCTest
@testable import AgentSessions

@MainActor
final class CursorResumeCoordinatorTests: XCTestCase {
    func testResumeUsesSessionIDWhenSupported() async {
        let env = MockEnvironment(result: .success(.init(versionString: "1.0.0",
                                                         binaryURL: URL(fileURLWithPath: "/usr/local/bin/agent"),
                                                         supportsResume: true,
                                                         supportsContinue: true)))
        let launcher = MockLauncher()
        let coordinator = CursorResumeCoordinator(env: env,
                                                  builder: CursorResumeCommandBuilder(),
                                                  launcher: launcher)

        let result = await coordinator.resumeInTerminal(input: CursorResumeInput(sessionID: "chat-id", workingDirectory: nil, binaryOverride: nil),
                                                        policy: .resumeThenContinue,
                                                        dryRun: false)

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.strategy, .resumeByID)
        XCTAssertEqual(launcher.commands.first, "'/usr/local/bin/agent' --resume 'chat-id'")
    }

    func testResumeFallsBackToContinueWhenResumeUnsupported() async {
        let env = MockEnvironment(result: .success(.init(versionString: "1.0.0",
                                                         binaryURL: URL(fileURLWithPath: "/usr/local/bin/agent"),
                                                         supportsResume: false,
                                                         supportsContinue: true)))
        let launcher = MockLauncher()
        let coordinator = CursorResumeCoordinator(env: env,
                                                  builder: CursorResumeCommandBuilder(),
                                                  launcher: launcher)

        let result = await coordinator.resumeInTerminal(input: CursorResumeInput(sessionID: "chat-id", workingDirectory: nil, binaryOverride: nil),
                                                        policy: .resumeThenContinue,
                                                        dryRun: false)

        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.strategy, .continueMostRecent)
        XCTAssertEqual(launcher.commands.first, "'/usr/local/bin/agent' --continue")
    }

    func testResumeOnlyReturnsFailureWithoutSessionID() async {
        let env = MockEnvironment(result: .success(.init(versionString: "1.0.0",
                                                         binaryURL: URL(fileURLWithPath: "/usr/local/bin/agent"),
                                                         supportsResume: true,
                                                         supportsContinue: true)))
        let launcher = MockLauncher()
        let coordinator = CursorResumeCoordinator(env: env,
                                                  builder: CursorResumeCommandBuilder(),
                                                  launcher: launcher)

        let result = await coordinator.resumeInTerminal(input: CursorResumeInput(sessionID: nil, workingDirectory: nil, binaryOverride: nil),
                                                        policy: .resumeOnly,
                                                        dryRun: false)

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.strategy, .none)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(launcher.commands.isEmpty)
    }

    private final class MockEnvironment: CursorCLIEnvironmentProviding {
        let result: Result<CursorCLIEnvironment.ProbeResult, CursorCLIEnvironment.ProbeError>

        init(result: Result<CursorCLIEnvironment.ProbeResult, CursorCLIEnvironment.ProbeError>) {
            self.result = result
        }

        func probe(customPath: String?) -> Result<CursorCLIEnvironment.ProbeResult, CursorCLIEnvironment.ProbeError> {
            result
        }
    }

    private final class MockLauncher: CursorTerminalLaunching {
        private(set) var commands: [String] = []

        func launchInTerminal(_ package: CursorResumeCommandBuilder.CommandPackage) throws {
            commands.append(package.shellCommand)
        }
    }
}
