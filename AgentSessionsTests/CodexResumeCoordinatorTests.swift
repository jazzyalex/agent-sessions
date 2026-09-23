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
        UserDefaults.standard.set(true, forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled)
        defer { UserDefaults.standard.removeObject(forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled) }

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
            XCTAssertFalse(cmd.contains("/bin/zsh "))
            XCTAssertFalse(cmd.contains("write_presence(){"))
            XCTAssertTrue(cmd.contains("'\(binaryURL.path)' resume 'abc'"))
            XCTAssertTrue(cmd.contains("'\(binaryURL.path)' -c experimental_resume='\(expectedFallback.path)'"))
            XCTAssertTrue(cmd.components(separatedBy: "||").count >= 2)
        default:
            XCTFail("Expected quick launch to succeed")
        }
    }

    func testOpenInAppDoesNotProbeCLIOrLaunchTerminal() async throws {
        let env = MockEnvironment(result: .failure(.binaryNotFound))
        let terminal = MockLauncher()
        let workspace = MockDesktopWorkspace()
        let coordinator = CodexResumeCoordinator(
            environment: env, terminalLauncher: terminal,
            desktopLauncher: CodexDesktopAppLauncher(workspace: workspace)
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let id = "00000000-0000-4000-8000-000000000001"
        let session = desktopSession(filePath: url.path, internalID: id)

        let result = await coordinator.openInApp(session: session)

        guard case .launched = result else { return XCTFail("Expected desktop launch") }
        XCTAssertEqual(workspace.openedURL?.absoluteString, "codex://threads/\(id)?hostId=local")
        XCTAssertEqual(env.probeCount, 0)
        XCTAssertFalse(terminal.didLaunch)
    }

    func testAppSessionIDUsesInternalIDBeforeFilenameAndRowID() {
        let internalID = "00000000-0000-4000-8000-000000000001"
        let filenameID = "00000000-0000-4000-8000-000000000002"
        let path = "/tmp/rollout-2026-09-20T10-00-00-\(filenameID).jsonl"
        XCTAssertEqual(CodexResumeCoordinator.appSessionID(for: desktopSession(filePath: path, internalID: internalID)), internalID)
        XCTAssertEqual(CodexResumeCoordinator.appSessionID(for: desktopSession(filePath: path)), filenameID)
        XCTAssertNil(CodexResumeCoordinator.appSessionID(for: desktopSession(filePath: "/tmp/copied.jsonl")))
        XCTAssertNil(CodexResumeCoordinator.appSessionID(for: desktopSession(filePath: path, internalID: "invalid")))
    }

    func testAppSessionIDAcceptsLocalSurfacesButRejectsSideChatsAndOtherAgents() {
        let id = "00000000-0000-4000-8000-000000000001"
        for surface in [CodexSessionSurface.cli, .desktop, .vscode] {
            let session = desktopSession(filePath: "/tmp/log.jsonl", internalID: id, surface: surface)
            XCTAssertEqual(CodexResumeCoordinator.appSessionID(for: session), id)
        }
        let sideChat = desktopSession(filePath: "/tmp/log.jsonl", internalID: id, relationship: .sideChat)
        XCTAssertNil(CodexResumeCoordinator.appSessionID(for: sideChat))
        let claude = desktopSession(filePath: "/tmp/log.jsonl", internalID: id, source: .claude)
        XCTAssertNil(CodexResumeCoordinator.appSessionID(for: claude))
    }

    func testOpenInAppRejectsMissingLogWithoutOpeningURL() async {
        let workspace = MockDesktopWorkspace()
        let coordinator = CodexResumeCoordinator(desktopLauncher: CodexDesktopAppLauncher(workspace: workspace))
        let session = desktopSession(filePath: "/tmp/\(UUID().uuidString).jsonl",
                                     internalID: "00000000-0000-4000-8000-000000000001")
        let result = await coordinator.openInApp(session: session)
        guard case .failure = result else { return XCTFail("Expected missing-log failure") }
        XCTAssertNil(workspace.openedURL)
    }

    // MARK: - Helpers

    private func desktopSession(filePath: String, internalID: String? = nil,
                                surface: CodexSessionSurface? = nil,
                                relationship: SessionRelationshipKind? = nil,
                                source: SessionSource = .codex) -> Session {
        Session(id: "row-id-is-not-a-thread-id", source: source, startTime: nil, endTime: nil,
                model: nil, filePath: filePath, eventCount: 0, events: [],
                codexInternalSessionIDHint: internalID, relationshipKind: relationship, codexSurface: surface)
    }

    private final class MockDesktopWorkspace: CodexDesktopAppOpening {
        var openedURL: URL?
        func applicationURL() -> URL? { URL(fileURLWithPath: "/Applications/Codex.app") }
        func open(_ url: URL, withApplicationAt applicationURL: URL) async throws { openedURL = url }
    }

    private func makeTemporarySessionLog() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("rollout-2025-09-22T10-11-12-abc.jsonl")
        try? "{}\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private final class MockEnvironment: CodexCLIEnvironmentProviding {
        let result: Result<CodexCLIEnvironment.ProbeResult, CodexCLIEnvironment.ProbeError>
        private(set) var probeCount = 0

        init(result: Result<CodexCLIEnvironment.ProbeResult, CodexCLIEnvironment.ProbeError>) {
            self.result = result
        }

        func probeVersion(customPath: String?) -> Result<CodexCLIEnvironment.ProbeResult, CodexCLIEnvironment.ProbeError> {
            probeCount += 1
            return result
        }
    }

    private final class MockLauncher: CodexTerminalLaunching {
        private(set) var didLaunch = false
        private(set) var lastCommand: String?

        func launchInTerminal(_ package: CodexResumeCommandBuilder.CommandPackage) throws {
            didLaunch = true
            lastCommand = package.shellCommand
        }
    }
}

@MainActor
final class CodexDesktopAppLauncherTests: XCTestCase {
    private let sessionID = "00000000-0000-4000-8000-000000000001"

    func testSessionLinkTargetsExactLocalThread() throws {
        let url = try CodexDesktopAppLauncher.sessionURL(sessionID: sessionID)
        XCTAssertEqual(url.scheme, "codex")
        XCTAssertEqual(url.host, "threads")
        XCTAssertEqual(url.path, "/\(sessionID)")
        XCTAssertEqual(url.query, "hostId=local")
    }

    func testSessionLinkRejectsMissingIDsAndRouteInjection() {
        for id in ["", "new", "row-id", " ../settings", sessionID + "/extra", sessionID + "?hostId=remote", sessionID + "#fragment"] {
            XCTAssertThrowsError(try CodexDesktopAppLauncher.sessionURL(sessionID: id))
        }
    }

    func testLaunchUsesResolvedApplicationRatherThanDisplayName() async throws {
        let workspace = MockWorkspace()
        workspace.installedApplication = URL(fileURLWithPath: "/Applications/Renamed Codex.app")
        try await CodexDesktopAppLauncher(workspace: workspace).openSession(sessionID: sessionID)
        XCTAssertEqual(workspace.openedURL?.absoluteString, "codex://threads/\(sessionID)?hostId=local")
        XCTAssertEqual(workspace.openedApplication, workspace.installedApplication)
    }

    func testMissingApplicationDoesNotAttemptToOpen() async {
        let workspace = MockWorkspace()
        workspace.installedApplication = nil
        do {
            try await CodexDesktopAppLauncher(workspace: workspace).openSession(sessionID: sessionID)
            XCTFail("Expected app-not-installed error")
        } catch CodexDesktopAppLauncher.LaunchError.appNotInstalled {
            XCTAssertNil(workspace.openedURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWorkspaceLaunchFailureIsPropagated() async {
        let workspace = MockWorkspace()
        workspace.launchError = NSError(domain: "CodexDesktopAppLauncherTests", code: 42)
        do {
            try await CodexDesktopAppLauncher(workspace: workspace).openSession(sessionID: sessionID)
            XCTFail("Expected Launch Services failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "CodexDesktopAppLauncherTests")
            XCTAssertEqual((error as NSError).code, 42)
        }
    }

    private final class MockWorkspace: CodexDesktopAppOpening {
        var installedApplication: URL? = URL(fileURLWithPath: "/Applications/Codex.app")
        var openedURL: URL?
        var openedApplication: URL?
        var launchError: Error?

        func applicationURL() -> URL? { installedApplication }
        func open(_ url: URL, withApplicationAt applicationURL: URL) async throws {
            if let launchError { throw launchError }
            openedURL = url
            openedApplication = applicationURL
        }
    }
}
