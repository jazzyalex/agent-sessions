import XCTest
@testable import AgentSessions

/// Settings / resume-eligibility surface for Devin, mirroring
/// `KimiIntegrationSurfaceTests`' copy-command and preferences coverage.
final class DevinIntegrationSurfaceTests: XCTestCase {

    // MARK: - Resume command builder

    /// `Session.id` is the `sessions.id` primary key, a slug such as
    /// `bald-ketch`; `--resume <id>` was confirmed against `devin --help`
    /// at CLI 3000.3.27.
    func testSessionByIDResumeCommand() throws {
        let command = try DevinResumeCommandBuilder().makeCoreCommand(
            strategy: .sessionByID(id: "bald-ketch"),
            binaryCommand: "devin")

        XCTAssertEqual(command, "devin --resume bald-ketch")
    }

    func testContinueMostRecentUsesContinueFlag() throws {
        let command = try DevinResumeCommandBuilder().makeCoreCommand(
            strategy: .continueMostRecent,
            binaryCommand: "devin")

        XCTAssertEqual(command, "devin --continue")
    }

    func testStrategyFallsBackToContinueWhenSessionIDIsBlank() {
        guard case .continueMostRecent = DevinResumeCommandBuilder().strategy(forSessionID: "   ") else {
            return XCTFail("blank id must fall back to --continue")
        }
    }

    func testStrategyPrefersSessionByIDWhenIDPresent() {
        guard case .sessionByID(let id) = DevinResumeCommandBuilder().strategy(forSessionID: "bald-ketch") else {
            return XCTFail("non-empty id must resolve to --resume")
        }
        XCTAssertEqual(id, "bald-ketch")
    }

    func testBlankSessionIDIsRejectedRatherThanEmittingBareFlag() {
        XCTAssertThrowsError(try DevinResumeCommandBuilder().makeCoreCommand(
            strategy: .sessionByID(id: "  "),
            binaryCommand: "devin")) { error in
            XCTAssertEqual(error as? DevinResumeCommandBuilder.BuildError, .missingSessionID)
        }
    }

    func testResolvedBinaryPathWithSpacesIsQuoted() throws {
        let package = try DevinResumeCommandBuilder().makeCommand(
            strategy: .continueMostRecent,
            binaryURL: URL(fileURLWithPath: "/opt/my tools/devin"),
            workingDirectory: nil)

        XCTAssertEqual(package.displayCommand, "'/opt/my tools/devin' --continue")
    }

    func testMakeCommandPrependsWorkingDirectory() throws {
        let package = try DevinResumeCommandBuilder().makeCommand(
            strategy: .continueMostRecent,
            binaryURL: URL(fileURLWithPath: "/opt/devin"),
            workingDirectory: URL(fileURLWithPath: "/tmp/wd"))

        XCTAssertEqual(package.shellCommand, "cd '/tmp/wd' && '/opt/devin' --continue")
        XCTAssertEqual(package.displayCommand, "'/opt/devin' --continue")
    }

    // MARK: - Copy-resume command plan

    @MainActor
    private func makeSettings(function: String = #function) -> DevinSettings {
        let suite = "DevinIntegrationSurfaceTests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return DevinSettings.makeForTesting(defaults: defaults)
    }

    /// With nothing configured or probed, copy-resume falls back to a bare
    /// `devin` on PATH.
    @MainActor
    func testCopyCommandPlanFallsBackToBareBinary() throws {
        let plan = try XCTUnwrap(makeSettings().copyCommandPlan(sessionID: "bald-ketch"))

        XCTAssertEqual(plan.binary, "devin")
        let command = try DevinResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                      binaryCommand: plan.binary)
        XCTAssertEqual(command, "devin --resume bald-ketch")
    }

    /// The custom binary set in Preferences must reach the copied command.
    @MainActor
    func testCopyCommandPlanUsesCustomBinary() throws {
        let settings = makeSettings()
        settings.setBinaryPath("/opt/custom/devin")

        let plan = try XCTUnwrap(settings.copyCommandPlan(sessionID: "bald-ketch"))

        XCTAssertEqual(plan.binary, "/opt/custom/devin")
        let command = try DevinResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                      binaryCommand: plan.binary)
        XCTAssertEqual(command, "/opt/custom/devin --resume bald-ketch")
    }

    /// A blank session id (e.g. an unparsed transcript before discovery runs)
    /// must fall back to `--continue`, never a bare `--resume`.
    @MainActor
    func testCopyCommandPlanFallsBackToContinueWithoutSessionID() throws {
        let plan = try XCTUnwrap(makeSettings().copyCommandPlan(sessionID: "   "))

        let command = try DevinResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                      binaryCommand: plan.binary)
        XCTAssertEqual(command, "devin --continue")
    }

    /// A probed binary that advertises only `--continue` must never emit
    /// `--resume`, even when an id is present.
    @MainActor
    func testProbedBinaryAdvertisingOnlyContinueNeverEmitsResume() throws {
        let binaryURL = makeExecutableBinary()
        let settings = makeSettings()
        settings.setResolvedBinary(binaryURL.path, supportsResume: false, supportsContinue: true)

        let plan = try XCTUnwrap(settings.copyCommandPlan(sessionID: "bald-ketch"))

        XCTAssertEqual(plan.binary, binaryURL.path)
        let command = try DevinResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                      binaryCommand: plan.binary)
        XCTAssertEqual(command, "'\(binaryURL.path)' --continue")
    }

    /// A probed binary that advertises neither flag must yield no plan, so the
    /// UI can disable copy-resume rather than emit an unsupported command.
    @MainActor
    func testProbedBinaryAdvertisingNeitherFlagYieldsNoPlan() throws {
        let settings = makeSettings()
        settings.setResolvedBinary(makeExecutableBinary().path,
                                   supportsResume: false,
                                   supportsContinue: false)

        XCTAssertNil(settings.copyCommandPlan(sessionID: "bald-ketch"))
    }

    /// `copyCommandPlan` re-validates the cached resolved path against the
    /// filesystem, so probe-backed tests need a real executable file.
    @MainActor
    private func makeExecutableBinary(function: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevinIntegrationSurfaceTests.\(function)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("devin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Preferences surface

    /// The Devin pane must be reachable from the sidebar; without it the
    /// DevinSessionsRootOverride preference had no writer anywhere in the app.
    func testDevinPreferencesTabExists() {
        XCTAssertEqual(PreferencesTab.devin.title, "Devin CLI")
        XCTAssertFalse(PreferencesTab.devin.iconName.isEmpty)
        XCTAssertTrue(PreferencesTab.allCases.contains(.devin))
    }
}

extension DevinResumeCommandBuilder.BuildError: Equatable {}
