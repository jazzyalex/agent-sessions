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

    /// A cached path whose binary is gone is equally stale, and this case is the
    /// one that used to survive a relaunch: init only dropped capability-free
    /// entries, and `warmResolvedBinaryPathIfNeeded` only rebuilds an *empty*
    /// path. It was repaired lazily from a ViewBuilder instead, which is exactly
    /// what `canBuildCopyCommandPlan` stopped doing.
    @MainActor
    func testInitHealsCacheEntryWhoseBinaryNoLongerExists() {
        let suite = "DevinIntegrationSurfaceTests.healMissing"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/nonexistent/devin", forKey: DevinSettings.Keys.resolvedBinaryPath)
        defaults.set(true, forKey: DevinSettings.Keys.resolvedSupportsResume)
        defaults.set(true, forKey: DevinSettings.Keys.resolvedSupportsContinue)

        let settings = DevinSettings.makeForTesting(defaults: defaults)

        XCTAssertEqual(settings.resolvedBinaryPath, "", "a vanished binary must not stay cached")
        XCTAssertFalse(settings.resolvedSupportsResume)
    }

    // MARK: - Copy-resume predicate

    /// `canCopyResumeCommand` is evaluated inside a ViewBuilder, so it must not
    /// call `copyCommandPlan` — that heals stale caches by writing published
    /// state and spawning a probe. The predicate has to give the same answer
    /// without doing either, so pin the agreement across the states that matter.
    @MainActor
    func testPredicateAgreesWithPlanAcrossBinaryStates() {
        let binaryURL = makeExecutableBinary()

        // 1. Nothing probed yet — the bare-binary fallback always yields a plan.
        let fresh = makeSettings()
        XCTAssertEqual(fresh.canBuildCopyCommandPlan(sessionID: "bald-ketch"),
                       fresh.copyCommandPlan(sessionID: "bald-ketch") != nil)
        XCTAssertTrue(fresh.canBuildCopyCommandPlan(sessionID: "bald-ketch"))

        // 2. Probed custom binary advertising both flags.
        let probed = makeSettings()
        probed.setBinaryPath(binaryURL.path)
        probed.setResolvedBinary(binaryURL.path, supportsResume: true, supportsContinue: true)
        XCTAssertEqual(probed.canBuildCopyCommandPlan(sessionID: "bald-ketch"),
                       probed.copyCommandPlan(sessionID: "bald-ketch") != nil)
        XCTAssertTrue(probed.canBuildCopyCommandPlan(sessionID: "bald-ketch"))

        // 3. Custom binary advertising neither flag — no plan, and no fallback.
        let dead = makeSettings()
        dead.setBinaryPath(binaryURL.path)
        dead.setResolvedBinary(binaryURL.path, supportsResume: false, supportsContinue: false)
        XCTAssertFalse(dead.canBuildCopyCommandPlan(sessionID: "bald-ketch"))
        XCTAssertNil(dead.copyCommandPlan(sessionID: "bald-ketch"))

        // 4. Only --continue advertised and no session id: `--resume` is
        //    unavailable, so the plan falls through to continue.
        let continueOnly = makeSettings()
        continueOnly.setBinaryPath(binaryURL.path)
        continueOnly.setResolvedBinary(binaryURL.path, supportsResume: false, supportsContinue: true)
        XCTAssertEqual(continueOnly.canBuildCopyCommandPlan(sessionID: ""),
                       continueOnly.copyCommandPlan(sessionID: "") != nil)
    }

    /// The point of the predicate: asking must change nothing.
    @MainActor
    func testPredicateDoesNotMutatePublishedState() {
        let binaryURL = makeExecutableBinary()
        let settings = makeSettings()
        settings.setBinaryPath(binaryURL.path)
        settings.setResolvedBinary(binaryURL.path, supportsResume: true, supportsContinue: true)
        try? FileManager.default.removeItem(at: binaryURL)   // now a stale entry

        let pathBefore = settings.resolvedBinaryPath
        let resumeBefore = settings.resolvedSupportsResume
        let continueBefore = settings.resolvedSupportsContinue

        for _ in 0..<5 { _ = settings.canBuildCopyCommandPlan(sessionID: "bald-ketch") }

        XCTAssertEqual(settings.resolvedBinaryPath, pathBefore)
        XCTAssertEqual(settings.resolvedSupportsResume, resumeBefore)
        XCTAssertEqual(settings.resolvedSupportsContinue, continueBefore)
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
