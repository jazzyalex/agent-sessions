import XCTest
@testable import AgentSessions

/// Settings / resume-eligibility surface for fx, mirroring
/// `DevinIntegrationSurfaceTests`' copy-command and preferences coverage.
final class FxIntegrationSurfaceTests: XCTestCase {

    // MARK: - Resume command builder

    /// `Session.id` is the on-disk session directory name; `--resume <id>` was
    /// confirmed against `fx --help` at fx 0.0.4.
    func testSessionByIDResumeCommand() throws {
        let command = try FxResumeCommandBuilder().makeCoreCommand(
            strategy: .sessionByID(id: "1787261000000-1787261000000000000-0001"),
            binaryCommand: "fx")

        XCTAssertEqual(command, "fx --resume 1787261000000-1787261000000000000-0001")
    }

    func testContinueMostRecentUsesContinueFlag() throws {
        let command = try FxResumeCommandBuilder().makeCoreCommand(
            strategy: .continueMostRecent,
            binaryCommand: "fx")

        XCTAssertEqual(command, "fx --continue")
    }

    func testStrategyFallsBackToContinueWhenSessionIDIsBlank() {
        guard case .continueMostRecent = FxResumeCommandBuilder().strategy(forSessionID: "   ") else {
            return XCTFail("blank id must fall back to --continue")
        }
    }

    func testStrategyPrefersSessionByIDWhenIDPresent() {
        guard case .sessionByID(let id) = FxResumeCommandBuilder().strategy(forSessionID: "abc-001") else {
            return XCTFail("non-empty id must resolve to --resume")
        }
        XCTAssertEqual(id, "abc-001")
    }

    func testBlankSessionIDIsRejectedRatherThanEmittingBareFlag() {
        XCTAssertThrowsError(try FxResumeCommandBuilder().makeCoreCommand(
            strategy: .sessionByID(id: "  "),
            binaryCommand: "fx")) { error in
            XCTAssertEqual(error as? FxResumeCommandBuilder.BuildError, .missingSessionID)
        }
    }

    func testResolvedBinaryPathWithSpacesIsQuoted() throws {
        let package = try FxResumeCommandBuilder().makeCommand(
            strategy: .continueMostRecent,
            binaryURL: URL(fileURLWithPath: "/opt/my tools/fx"),
            workingDirectory: nil)

        XCTAssertEqual(package.displayCommand, "'/opt/my tools/fx' --continue")
    }

    func testMakeCommandPrependsWorkingDirectory() throws {
        let package = try FxResumeCommandBuilder().makeCommand(
            strategy: .continueMostRecent,
            binaryURL: URL(fileURLWithPath: "/opt/fx"),
            workingDirectory: URL(fileURLWithPath: "/tmp/wd"))

        XCTAssertEqual(package.shellCommand, "cd '/tmp/wd' && '/opt/fx' --continue")
        XCTAssertEqual(package.displayCommand, "'/opt/fx' --continue")
    }

    // MARK: - Copy-resume command plan

    @MainActor
    private func makeSettings(function: String = #function) -> FxSettings {
        let suite = "FxIntegrationSurfaceTests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return FxSettings.makeForTesting(defaults: defaults)
    }

    /// With nothing configured or probed, copy-resume falls back to a bare
    /// `fx` on PATH.
    @MainActor
    func testCopyCommandPlanFallsBackToBareBinary() throws {
        let plan = try XCTUnwrap(makeSettings().copyCommandPlan(sessionID: "abc-001"))

        XCTAssertEqual(plan.binary, "fx")
        let command = try FxResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                   binaryCommand: plan.binary)
        XCTAssertEqual(command, "fx --resume abc-001")
    }

    /// The custom binary set in Preferences must reach the copied command —
    /// but only once a probe has resolved *that* binary and advertised a flag.
    @MainActor
    func testCopyCommandPlanUsesProbedCustomBinary() throws {
        let binaryURL = makeExecutableBinary()
        let settings = makeSettings()
        settings.setBinaryPath(binaryURL.path)
        settings.setResolvedBinary(binaryURL.path, supportsResume: true, supportsContinue: true)

        let plan = try XCTUnwrap(settings.copyCommandPlan(sessionID: "abc-001"))

        XCTAssertEqual(plan.binary, binaryURL.path)
        let command = try FxResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                   binaryCommand: plan.binary)
        XCTAssertEqual(command, "'\(binaryURL.path)' --resume abc-001")
    }

    /// A custom binary the probe resolved but which advertised neither flag
    /// yields no plan — same refusal as the auto-detected branch, so the UI
    /// disables copy-resume instead of emitting an unsupported command.
    @MainActor
    func testCustomBinaryAdvertisingNeitherFlagYieldsNoPlan() {
        let binaryURL = makeExecutableBinary()
        let settings = makeSettings()
        settings.setBinaryPath(binaryURL.path)
        settings.setResolvedBinary(binaryURL.path, supportsResume: false, supportsContinue: false)

        XCTAssertNil(settings.copyCommandPlan(sessionID: "abc-001"))
    }

    /// A probe that could not execute the CLI reports a real binary with both
    /// capabilities false. That verdict is "nothing learned": storing it would
    /// let one failed probe disable resume for good, because the cache only
    /// refreshes while the resolved path is empty.
    @MainActor
    func testSetResolvedBinaryWithNeitherFlagStoresNothingLearned() {
        let settings = makeSettings()
        settings.setResolvedBinary("/opt/fx", supportsResume: false, supportsContinue: false)

        XCTAssertEqual(settings.resolvedBinaryPath, "")
        XCTAssertFalse(settings.resolvedSupportsResume)
        XCTAssertFalse(settings.resolvedSupportsContinue)
    }

    /// A cache entry naming a binary that advertises neither flag came from a
    /// pre-guard probe. Init drops it so the warm path can rebuild it.
    @MainActor
    func testInitHealsCacheEntryThatAdvertisesNothing() {
        let suite = "FxIntegrationSurfaceTests.heal"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/stale/fx", forKey: FxSettings.Keys.resolvedBinaryPath)

        let settings = FxSettings.makeForTesting(defaults: defaults)

        XCTAssertEqual(settings.resolvedBinaryPath, "")
        XCTAssertFalse(settings.resolvedSupportsResume)
        XCTAssertFalse(settings.resolvedSupportsContinue)
    }

    /// K1: these strings freeze at release. Asserted literally so a rename
    /// fails here instead of silently resetting stored capabilities on upgrade.
    @MainActor
    func testPersistedKeysKeepTheirLiteralStrings() {
        XCTAssertEqual(FxSettings.Keys.binaryPath, "FxBinaryPath")
        XCTAssertEqual(FxSettings.Keys.resolvedBinaryPath, "FxResolvedBinaryPath")
        XCTAssertEqual(FxSettings.Keys.resolvedSupportsResume, "FxResolvedSupportsResume")
        XCTAssertEqual(FxSettings.Keys.resolvedSupportsContinue, "FxResolvedSupportsContinue")
    }

    // MARK: - Preferences surface

    /// The fx pane must be reachable from the sidebar; without it the
    /// FxSessionsRootOverride preference had no writer anywhere in the app.
    func testFxPreferencesTabExists() {
        XCTAssertEqual(PreferencesTab.fx.title, "fx")
        XCTAssertFalse(PreferencesTab.fx.iconName.isEmpty)
        XCTAssertTrue(PreferencesTab.allCases.contains(.fx))
    }

    /// `copyCommandPlan` re-validates the cached resolved path against the
    /// filesystem, so probe-backed tests need a real executable file.
    @MainActor
    private func makeExecutableBinary(function: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FxIntegrationSurfaceTests.\(function)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fx")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
