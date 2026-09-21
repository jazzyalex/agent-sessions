import XCTest
import SwiftUI
import Darwin
@testable import AgentSessions

/// Registry, catalog, key-stability, view-derivation and golden coverage for Cline.
@MainActor
final class ClineIntegrationTests: XCTestCase {
    // MARK: - Source identity

    func testSourceIdentity() {
        XCTAssertEqual(SessionSource.cline.rawValue, "cline")
        XCTAssertEqual(SessionSource.cline.displayName, "Cline")
        XCTAssertEqual(SessionSource.cline.iconName, "c.circle")
        XCTAssertEqual(SessionSource.cline.versionIntroduced, "5.4")
        let description = String(localized: SessionSource.cline.featureDescription)
        XCTAssertTrue(description.contains("CLI") && description.contains("Desktop"),
                      "feature description must name both CLI and Desktop sessions: \(description)")
    }

    // MARK: - Descriptor

    func testDescriptor() {
        let d = SessionSourceRegistry.descriptor(for: .cline)
        XCTAssertEqual(d.source, .cline)
        XCTAssertEqual(d.shortLabel, "Cline")
        XCTAssertEqual(d.badgeInitials, "CN")
        XCTAssertEqual(d.enablementKey, "AgentEnabledCline")
        XCTAssertEqual(d.cliAvailableKey, "ClineCLIAvailable")
        XCTAssertEqual(d.rootOverrideKeys, ["ClineSessionsRootOverride"])
        XCTAssertEqual(d.includeKey, "IncludeClineSessions")
        XCTAssertEqual(d.binaryNames, ["cline"])
        XCTAssertEqual(d.defaultEnabled, .whenAvailable)
        XCTAssertFalse(d.supportsResume)
        XCTAssertNil(d.resumeAgentLabel)
        XCTAssertNotNil(d.parseFullByPath)
        XCTAssertNil(d.parseFullByIdentity)
        XCTAssertNil(d.searchUsesIdentityAtURL)
        XCTAssertNotNil(d.archive)
        XCTAssertNotNil(d.otherAgentPill)
        XCTAssertNil(d.otherAgentPill?.shortcut)
        // Telemetry is declared unavailable until the format is fully audited.
        let t = d.telemetry
        for cap in [t.configuration, t.tokens, t.cost, t.weeklyQuota] {
            guard case .unavailable = cap else {
                return XCTFail("cline telemetry must be unavailable until fully implemented")
            }
        }
    }

    func testAvailabilityUsesInjectedFilesystem() {
        let suiteName = "ClineIntegrationTests-Availability-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let home = URL(fileURLWithPath: "/virtual/home", isDirectory: true)

        let empty = AvailabilityContext(defaults: defaults,
                                        fileProbe: FakeFileProbe(),
                                        homeDirectory: home,
                                        detectBinary: { _ in false })
        XCTAssertFalse(SessionSource.cline.descriptor.isAvailable(empty))

        let sessionsProbe = FakeFileProbe(
            files: ["/virtual/home/.cline/data/sessions/abc/abc.json"],
            directories: ["/virtual/home/.cline/data/sessions",
                          "/virtual/home/.cline/data/sessions/abc"]
        )
        let sessionsContext = AvailabilityContext(defaults: defaults,
                                                  fileProbe: sessionsProbe,
                                                  homeDirectory: home,
                                                  detectBinary: { _ in false })
        XCTAssertTrue(SessionSource.cline.descriptor.isAvailable(sessionsContext))

        let binaryContext = AvailabilityContext(defaults: defaults,
                                                fileProbe: FakeFileProbe(),
                                                homeDirectory: home,
                                                detectBinary: { $0 == "cline" })
        XCTAssertTrue(SessionSource.cline.descriptor.isAvailable(binaryContext))
        XCTAssertTrue(SessionSource.cline.descriptor.isBinaryInstalled(binaryContext))
    }

    func testAvailabilityAcceptsOnlyTheSuccessfullyResolvedCustomBinary() {
        let suiteName = "ClineIntegrationTests-CustomBinary-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let home = URL(fileURLWithPath: "/virtual/home", isDirectory: true)
        defaults.set("~/bin/cline", forKey: ClinePreferencesKey.binaryPath)
        defaults.set("/virtual/home/bin/cline", forKey: ClinePreferencesKey.resolvedBinaryPath)

        let installed = AvailabilityContext(
            defaults: defaults,
            fileProbe: FakeFileProbe(executables: ["/virtual/home/bin/cline"]),
            homeDirectory: home,
            detectBinary: { _ in false }
        )
        XCTAssertTrue(SessionSource.cline.descriptor.isBinaryInstalled(installed))
        XCTAssertTrue(SessionSource.cline.descriptor.isAvailable(installed))

        defaults.set("/virtual/home/bin/other-cline", forKey: ClinePreferencesKey.binaryPath)
        XCTAssertFalse(SessionSource.cline.descriptor.isBinaryInstalled(installed),
                       "a successful probe must not carry over to a different configured path")

        defaults.set("~/bin/cline", forKey: ClinePreferencesKey.binaryPath)
        let deleted = AvailabilityContext(
            defaults: defaults,
            fileProbe: FakeFileProbe(),
            homeDirectory: home,
            detectBinary: { _ in false }
        )
        XCTAssertFalse(SessionSource.cline.descriptor.isBinaryInstalled(deleted),
                       "a stale stored success must not survive deletion of the executable")
    }

    func testStaleBinaryProbeCannotOverwriteANewerSelection() {
        let suiteName = "ClineIntegrationTests-StaleProbe-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ClineSettings.makeForTesting(defaults: defaults)

        settings.setBinaryPath("/tmp/cline-old")
        let oldRequest = settings.currentProbeRequest()
        settings.setBinaryPath("/tmp/cline-new")
        let oldResult: Result<ClineCLIEnvironment.ProbeResult, ClineCLIEnvironment.ProbeError> = .success(
            .init(versionString: "old", binaryURL: URL(fileURLWithPath: "/tmp/cline-old"))
        )

        guard case .stale(let newRequest) = settings.acceptProbeCompletion(oldResult, for: oldRequest) else {
            return XCTFail("an old probe must be rejected after the configured path changes")
        }
        XCTAssertEqual(newRequest, settings.currentProbeRequest())
        XCTAssertEqual(newRequest.binaryOverride, "/tmp/cline-new")
        XCTAssertTrue(settings.resolvedBinaryPath.isEmpty)
        XCTAssertNil(defaults.string(forKey: ClinePreferencesKey.resolvedBinaryPath))

        let newResult: Result<ClineCLIEnvironment.ProbeResult, ClineCLIEnvironment.ProbeError> = .success(
            .init(versionString: "new", binaryURL: URL(fileURLWithPath: "/tmp/cline-new"))
        )
        XCTAssertEqual(settings.acceptProbeCompletion(newResult, for: newRequest), .accepted)
        XCTAssertEqual(settings.resolvedBinaryPath, "/tmp/cline-new")
        XCTAssertEqual(defaults.string(forKey: ClinePreferencesKey.resolvedBinaryPath), "/tmp/cline-new")
    }

    func testSessionsRootPreferenceDoesNotPersistInvalidDraft() {
        let suiteName = "ClineIntegrationTests-RootPreference-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let home = URL(fileURLWithPath: "/virtual/home", isDirectory: true)
        defaults.set("/previous/sessions", forKey: ClinePreferencesKey.sessionsRootOverride)

        XCTAssertFalse(ClineSessionsRootPreference.commit(
            "/missing/sessions",
            defaults: defaults,
            fileProbe: FakeFileProbe(),
            homeDirectory: home
        ))
        XCTAssertEqual(defaults.string(forKey: ClinePreferencesKey.sessionsRootOverride), "/previous/sessions")

        XCTAssertTrue(ClineSessionsRootPreference.commit(
            "  ~/sessions  ",
            defaults: defaults,
            fileProbe: FakeFileProbe(directories: ["/virtual/home/sessions"]),
            homeDirectory: home
        ))
        XCTAssertEqual(defaults.string(forKey: ClinePreferencesKey.sessionsRootOverride), "~/sessions")

        XCTAssertTrue(ClineSessionsRootPreference.commit(
            "",
            defaults: defaults,
            fileProbe: FakeFileProbe(),
            homeDirectory: home
        ))
        XCTAssertNil(defaults.string(forKey: ClinePreferencesKey.sessionsRootOverride))
    }

    func testBinaryDetectionLooksForCline() {
        let home = URL(fileURLWithPath: "/virtual/home", isDirectory: true)
        let defaults = UserDefaults.standard
        let ctx = AvailabilityContext(defaults: defaults,
                                      fileProbe: FakeFileProbe(),
                                      homeDirectory: home,
                                      detectBinary: { $0 == "cline" })
        XCTAssertTrue(SessionSource.cline.descriptor.isBinaryInstalled(ctx))
        let missing = AvailabilityContext(defaults: defaults,
                                          fileProbe: FakeFileProbe(),
                                          homeDirectory: home,
                                          detectBinary: { _ in false })
        XCTAssertFalse(SessionSource.cline.descriptor.isBinaryInstalled(missing))
    }

    func testCLIProbeReturnsVersionFromExecutable() {
        let binaryPath = makeTempExecutable()
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }
        let executor = MockExecutor(result: CommandResult(stdout: "3.0.62\n", stderr: "", exitCode: 0))

        switch ClineCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTAssertEqual(probe.versionString, "3.0.62")
            XCTAssertEqual(probe.binaryURL.path, binaryPath)
        case .failure(let error):
            XCTFail("unexpected probe failure: \(error)")
        }
    }

    func testCLIProbeRejectsNonzeroVersionExit() {
        let binaryPath = makeTempExecutable()
        defer { try? FileManager.default.removeItem(atPath: binaryPath) }
        let executor = MockExecutor(result: CommandResult(stdout: "", stderr: "broken runtime", exitCode: 127))

        switch ClineCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let probe):
            XCTFail("expected failure, got \(probe.versionString)")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("broken runtime"))
        }
    }

    // MARK: - Catalog

    func testCatalogBuildsClineRuntime() {
        let catalog = SessionProviderCatalog()
        XCTAssertEqual(catalog[.cline].source, .cline)
        XCTAssertTrue(catalog[.cline].indexerObject is ClineSessionIndexer)
        XCTAssertTrue(catalog.indexer(.cline, as: ClineSessionIndexer.self) === (catalog[.cline].indexerObject as AnyObject))
        XCTAssertEqual(SessionSourceRegistry.ordered.map(\.descriptor.source), SessionSource.allCases)
    }

    // MARK: - Keys

    func testPersistedKeysKeepLiteralStrings() {
        XCTAssertEqual(ClinePreferencesKey.enabled, "AgentEnabledCline")
        XCTAssertEqual(ClinePreferencesKey.cliAvailable, "ClineCLIAvailable")
        XCTAssertEqual(ClinePreferencesKey.binaryPath, "ClineBinaryPath")
        XCTAssertEqual(ClinePreferencesKey.resolvedBinaryPath, "ClineResolvedBinaryPath")
        XCTAssertEqual(ClinePreferencesKey.sessionsRootOverride, "ClineSessionsRootOverride")
        XCTAssertEqual(ClinePreferencesKey.includeSessions, "IncludeClineSessions")
        XCTAssertEqual(ClineSettings.Keys.binaryPath, "ClineBinaryPath")
        XCTAssertEqual(ClineSettings.Keys.resolvedBinaryPath, "ClineResolvedBinaryPath")
    }

    // MARK: - View derivation

    func testPreferencesTabRoundTrips() {
        XCTAssertEqual(PreferencesTab(source: .cline), .cline)
        XCTAssertEqual(PreferencesTab.cline.configuredSource, .cline)
        XCTAssertFalse(String(localized: PreferencesTab.cline.title).isEmpty)
        XCTAssertFalse(PreferencesTab.cline.iconName.isEmpty)
        XCTAssertTrue(PreferencesTab.sidebarAgentSources.contains(.cline))
        XCTAssertTrue(PreferencesTab.sidebarAgentTabs.contains(.cline))
    }

    func testToolbarPillSequenceKeepsClineBeforeDeepSeekHarness() {
        let derived = SessionSourceRegistry.ordered.compactMap { adapter -> (SessionSource, String, String?)? in
            guard let pill = adapter.descriptor.otherAgentPill else { return nil }
            return (adapter.descriptor.source, adapter.descriptor.shortLabel, pill.shortcut)
        }
        guard derived.count >= 2 else { return XCTFail("expected Cline and DSH pills") }
        XCTAssertEqual(derived[derived.count - 2].0, .cline)
        XCTAssertEqual(derived[derived.count - 2].1, "Cline")
        XCTAssertNil(derived[derived.count - 2].2)
        XCTAssertEqual(derived.last?.0, .deepseekHarness)
        XCTAssertEqual(derived.last?.1, "DeepSeek")
        XCTAssertNil(derived.last?.2)
    }

    // MARK: - Golden fixtures

    func testGoldenCliFixture() throws {
        let url = FixturePaths.stage0FixtureURL("agents/cline/cli_tool/cline-cli-tool.json")
        guard let preview = ClineSessionParser.parseFile(at: url) else { return XCTFail("preview nil") }
        XCTAssertEqual(preview.source, .cline)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertEqual(preview.eventCount, 4)
        XCTAssertEqual(preview.lightweightCommands, 1)
        XCTAssertEqual(preview.surface, .cli)

        guard let full = ClineSessionParser.parseFileFull(at: url) else { return XCTFail("full nil") }
        XCTAssertEqual(full.source, .cline)
        XCTAssertFalse(full.events.isEmpty)
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .error }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .meta }))
    }

    func testGoldenDesktopFixture() throws {
        let url = FixturePaths.stage0FixtureURL("agents/cline/desktop_continued/cline-desktop-continued.json")
        guard let preview = ClineSessionParser.parseFile(at: url) else { return XCTFail("preview nil") }
        XCTAssertEqual(preview.source, .cline)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertEqual(preview.eventCount, 5)
        XCTAssertEqual(preview.surface, .desktop)

        guard let full = ClineSessionParser.parseFileFull(at: url) else { return XCTFail("full nil") }
        XCTAssertEqual(full.source, .cline)
        XCTAssertFalse(full.events.isEmpty)
        // Order is preserved across the continued conversation.
        XCTAssertEqual(full.events.compactMap(\.text), [
            "Review the fixture project.",
            "Focus on the parser contract.",
            "The parser contract is consistent.",
            "Check the follow-up path too.",
            "The continued conversation remains ordered."
        ])
    }

    // MARK: - Paired storage integration

    func testMessagesOnlyChangeInvalidatesFocusedMonitorAndSearch() throws {
        let pair = try makeSessionPair(id: "freshness")
        defer { try? FileManager.default.removeItem(at: pair.cleanupRoot) }
        let session = try XCTUnwrap(ClineSessionParser.parseFile(at: pair.manifest))

        let focusedBefore = try XCTUnwrap(
            UnifiedSessionIndexer.logicalFocusedSignature(source: .cline,
                                                           path: pair.manifest.path)
        )
        let searchBefore = try XCTUnwrap(
            UnifiedSessionIndexer.searchFileRefs(for: [session]).first
        )

        var messages = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: pair.messages)) as? [String: Any]
        )
        messages["messages"] = [
            ["role": "user", "ts": 1_789_507_317_131, "id": "u1",
             "content": [["type": "text", "text": "A longer replacement message"]]]
        ]
        try JSONSerialization.data(withJSONObject: messages).write(to: pair.messages, options: .atomic)

        let focusedAfter = try XCTUnwrap(
            UnifiedSessionIndexer.logicalFocusedSignature(source: .cline,
                                                           path: pair.manifest.path)
        )
        let searchAfter = try XCTUnwrap(
            UnifiedSessionIndexer.searchFileRefs(for: [session]).first
        )

        XCTAssertNotEqual(focusedBefore, focusedAfter)
        XCTAssertNotEqual(searchBefore.size, searchAfter.size)
    }

    func testArchiveCopiesManifestAndMessagesAsOneUnit() throws {
        let pair = try makeSessionPair(id: "archive-pair")
        defer { try? FileManager.default.removeItem(at: pair.cleanupRoot) }
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClineArchiveSupport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let session = try XCTUnwrap(ClineSessionParser.parseFile(at: pair.manifest))
        let unit = SessionArchiveManager.archiveUnit(for: session)
        XCTAssertEqual(unit.root, pair.directory)
        XCTAssertTrue(unit.isDirectory)
        XCTAssertEqual(unit.primaryRelativePath, "archive-pair.json")

        let previousProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer { SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousProvider }

        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(session)
        let archiveInfo = try XCTUnwrap(manager.archiveInfoForTesting(source: .cline, id: session.id))
        XCTAssertNil(archiveInfo.lastError, archiveInfo.lastError ?? "")
        let archiveRoot = try XCTUnwrap(manager.archiveFolderURL(source: .cline, id: session.id))
        let archivedManifest = archiveRoot
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("archive-pair.json")
        let archivedMessages = archiveRoot
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("archive-pair.messages.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedMessages.path))
        XCTAssertEqual(ClineSessionParser.parseFileFull(at: archivedManifest)?.id, "archive-pair")
    }

    private func makeSessionPair(id: String) throws -> (cleanupRoot: URL, directory: URL, manifest: URL, messages: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClinePair-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("\(id).json")
        let messages = directory.appendingPathComponent("\(id).messages.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "session_id": id,
            "source": "cli",
            "started_at": "2026-09-15T21:21:57.131Z",
            "prompt": "paired storage"
        ]).write(to: manifest)
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessionId": id,
            "messages": [
                ["role": "user", "ts": 1_789_507_317_131, "id": "u1",
                 "content": [["type": "text", "text": "Initial message"]]]
            ]
        ]).write(to: messages)
        return (parent, directory, manifest, messages)
    }

    private final class MockExecutor: CommandExecuting {
        let result: CommandResult

        init(result: CommandResult) {
            self.result = result
        }

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            result
        }

        func run(_ command: [String], cwd: URL?, environment: [String: String]?) throws -> CommandResult {
            result
        }
    }

    private func makeTempExecutable() -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cline-probe-\(UUID().uuidString)")
        try? "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        _ = chmod(file.path, 0o755)
        return file.path
    }
}
