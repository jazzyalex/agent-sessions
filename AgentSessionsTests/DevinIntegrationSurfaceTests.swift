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

    /// The custom binary set in Preferences must reach the copied command —
    /// but only once a probe has resolved *that* binary and advertised a flag.
    @MainActor
    func testCopyCommandPlanUsesProbedCustomBinary() throws {
        let binaryURL = makeExecutableBinary()
        let settings = makeSettings()
        settings.setBinaryPath(binaryURL.path)
        settings.setResolvedBinary(binaryURL.path, supportsResume: true, supportsContinue: true)

        let plan = try XCTUnwrap(settings.copyCommandPlan(sessionID: "bald-ketch"))

        XCTAssertEqual(plan.binary, binaryURL.path)
        let command = try DevinResumeCommandBuilder().makeCoreCommand(strategy: plan.strategy,
                                                                      binaryCommand: plan.binary)
        XCTAssertEqual(command, "'\(binaryURL.path)' --resume bald-ketch")
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

        XCTAssertNil(settings.copyCommandPlan(sessionID: "bald-ketch"))
    }

    /// A probe that could not execute the CLI reports a real binary with both
    /// capabilities false. That verdict is "nothing learned": storing it would
    /// let one failed probe disable resume for good, because the cache only
    /// refreshes while the resolved path is empty.
    @MainActor
    func testSetResolvedBinaryWithNeitherFlagStoresNothingLearned() {
        let settings = makeSettings()
        settings.setResolvedBinary("/opt/devin", supportsResume: false, supportsContinue: false)

        XCTAssertEqual(settings.resolvedBinaryPath, "")
        XCTAssertFalse(settings.resolvedSupportsResume)
        XCTAssertFalse(settings.resolvedSupportsContinue)
    }

    /// A cache entry naming a binary that advertises neither flag came from a
    /// pre-guard probe. Init drops it so the warm path can rebuild it.
    @MainActor
    func testInitHealsCacheEntryThatAdvertisesNothing() {
        let suite = "DevinIntegrationSurfaceTests.heal"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/stale/devin", forKey: DevinSettings.Keys.resolvedBinaryPath)

        let settings = DevinSettings.makeForTesting(defaults: defaults)

        XCTAssertEqual(settings.resolvedBinaryPath, "")
        XCTAssertFalse(settings.resolvedSupportsResume)
        XCTAssertFalse(settings.resolvedSupportsContinue)
    }

    /// K1: these strings freeze at release. `resolvedSupportsResume` was
    /// briefly mapped onto Kimi's `...SupportsSession` suffix before launch;
    /// Devin's flag is `--resume`, and the literal below is the shipped form.
    @MainActor
    func testPersistedKeysKeepTheirLiteralStrings() {
        XCTAssertEqual(DevinSettings.Keys.binaryPath, "DevinBinaryPath")
        XCTAssertEqual(DevinSettings.Keys.resolvedBinaryPath, "DevinResolvedBinaryPath")
        XCTAssertEqual(DevinSettings.Keys.resolvedSupportsResume, "DevinResolvedSupportsResume")
        XCTAssertEqual(DevinSettings.Keys.resolvedSupportsContinue, "DevinResolvedSupportsContinue")
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

    /// A probed binary that advertises neither flag is "nothing learned": the
    /// dead verdict is discarded, and copy-resume falls back to a bare `devin`
    /// on PATH rather than emitting an unsupported command.
    @MainActor
    func testAutoProbedBinaryAdvertisingNeitherFlagFallsBackToBareBinary() throws {
        let binaryURL = makeExecutableBinary()
        let settings = makeSettings()
        settings.setResolvedBinary(binaryURL.path, supportsResume: false, supportsContinue: false)

        XCTAssertEqual(settings.resolvedBinaryPath, "")
        let plan = try XCTUnwrap(settings.copyCommandPlan(sessionID: "bald-ketch"))
        XCTAssertEqual(plan.binary, DevinCLIEnvironment.binaryName)
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
