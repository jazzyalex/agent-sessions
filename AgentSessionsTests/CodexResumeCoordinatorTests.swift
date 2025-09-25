import XCTest
@testable import AgentSessions

@MainActor
final class CodexResumeCoordinatorTests: XCTestCase {
    func testQuickLaunchFailsWhenLogIsMissing() async {
        let env = MockEnvironment(result: .success(.init(version: .semantic(major: 0, minor: 40, patch: 0),
                                                          binaryURL: URL(fileURLWithPath: "/usr/local/bin/codex"))))
        let launcher = MockLauncher()
        let defaults = UserDefaults(suiteName: "CodexResumeCoordinatorTests.missing")!
        defaults.removePersistentDomain(forName: "CodexResumeCoordinatorTests.missing")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)

        let coordinator = CodexResumeCoordinator(settings: settings,
                                                 environment: env,
                                                 commandBuilder: CodexResumeCommandBuilder(),
                                                 terminalLauncher: launcher)

        let session = Session(id: "abc",
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: "/tmp/rollout-2025-09-22T10-11-12-abc.jsonl",
                              eventCount: 0,
                              events: [])

        let result = await coordinator.quickLaunchInTerminal(session: session)
        switch result {
        case .failure:
            XCTAssertFalse(launcher.didLaunch)
        default:
            XCTFail("Expected failure when log is missing")
        }
    }

    func testQuickLaunchNeedsConfigurationWhenProbeFails() async {
        let env = MockEnvironment(result: .failure(.binaryNotFound))
        let launcher = MockLauncher()
        let defaults = UserDefaults(suiteName: "CodexResumeCoordinatorTests.probe")!
        defaults.removePersistentDomain(forName: "CodexResumeCoordinatorTests.probe")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)

        let coordinator = CodexResumeCoordinator(settings: settings,
                                                 environment: env,
                                                 commandBuilder: CodexResumeCommandBuilder(),
                                                 terminalLauncher: launcher)

        let url = makeTemporarySessionLog()
        let session = Session(id: "abc",
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: url.path,
                              eventCount: 0,
                              events: [])

        let result = await coordinator.quickLaunchInTerminal(session: session)
        switch result {
        case .needsConfiguration:
            XCTAssertFalse(launcher.didLaunch)
        default:
            XCTFail("Expected configuration notice when probe fails")
        }
    }

    func testQuickLaunchLaunchesWhenProbeSucceeds() async throws {
        let binaryURL = URL(fileURLWithPath: "/usr/local/bin/codex")
        let env = MockEnvironment(result: .success(.init(version: .semantic(major: 0, minor: 40, patch: 1),
                                                          binaryURL: binaryURL)))
        let launcher = MockLauncher()
        let defaults = UserDefaults(suiteName: "CodexResumeCoordinatorTests.success")!
        defaults.removePersistentDomain(forName: "CodexResumeCoordinatorTests.success")
        let settings = CodexResumeSettings.makeForTesting(defaults: defaults)

        let coordinator = CodexResumeCoordinator(settings: settings,
                                                 environment: env,
                                                 commandBuilder: CodexResumeCommandBuilder(),
                                                 terminalLauncher: launcher)

        let url = makeTemporarySessionLog()
        let session = Session(id: "abc",
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: url.path,
                              eventCount: 0,
                              events: [])

        let result = await coordinator.quickLaunchInTerminal(session: session)
        switch result {
        case .launched:
            XCTAssertTrue(launcher.didLaunch)
            let expectedFallback = URL(fileURLWithPath: url.path)
            let cmd = launcher.lastCommand ?? ""
            XCTAssertTrue(cmd.contains("'\(binaryURL.path)' resume 'abc'"))
            XCTAssertTrue(cmd.contains("'\(binaryURL.path)' -c experimental_resume='\(expectedFallback.path)'"))
            // Optional third attempt may be present; ensure at least 2 attempts
            XCTAssertTrue(cmd.components(separatedBy: "||").count >= 2)
        default:
            XCTFail("Expected quick launch to succeed")
        }
    }

    // MARK: - Helpers

    private func makeTemporarySessionLog() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("rollout-2025-09-22T10-11-12-abc.jsonl")
        try? "{}\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private final class MockEnvironment: CodexCLIEnvironmentProviding {
        let result: Result<CodexCLIEnvironment.ProbeResult, CodexCLIEnvironment.ProbeError>

        init(result: Result<CodexCLIEnvironment.ProbeResult, CodexCLIEnvironment.ProbeError>) {
            self.result = result
        }

        func probeVersion(customPath: String?) -> Result<CodexCLIEnvironment.ProbeResult, CodexCLIEnvironment.ProbeError> {
            result
        }
    }

    private final class MockLauncher: CodexTerminalLaunching {
        private(set) var didLaunch = false
        private(set) var lastCommand: String?

        func launchInTerminal(_ package: CodexResumeCommandBuilder.CommandPackage) throws {
            didLaunch = true
            lastCommand = package.displayCommand
        }
    }
}
