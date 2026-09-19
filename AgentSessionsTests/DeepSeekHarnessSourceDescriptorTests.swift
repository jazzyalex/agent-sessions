import XCTest
@testable import AgentSessions

/// Mechanical contract coverage for the DeepSeek Harness descriptor and registry entry.
///
@MainActor
final class DeepSeekHarnessSourceDescriptorTests: XCTestCase {
    private let source: SessionSource = .deepseekHarness

    func testSourceIdentityAndRegistryAdapterIdentity() {
        XCTAssertEqual(source.rawValue, "deepseek-harness")
        XCTAssertEqual(source.displayName, "DeepSeek Harness")
        XCTAssertEqual(source.iconName, "d.circle")

        let adapter = SessionSourceRegistry.adapter(for: source)
        XCTAssertEqual(adapter.descriptor.source, source)
        XCTAssertEqual(SessionSourceRegistry.bySource[source]?.descriptor.source, source)
        XCTAssertEqual(source.descriptor.source, source)
        XCTAssertTrue(SessionSourceRegistry.ordered.contains { $0.descriptor.source == source })
    }

    func testDescriptorKeysBinaryAndParsingIdentity() {
        let descriptor = source.descriptor

        XCTAssertEqual(descriptor.shortLabel, "DeepSeek Harness")
        XCTAssertEqual(descriptor.badgeInitials, "DS")
        XCTAssertEqual(descriptor.enablementKey, "AgentEnabledDeepSeekHarness")
        XCTAssertEqual(descriptor.cliAvailableKey, "DeepSeekHarnessCLIAvailable")
        XCTAssertEqual(descriptor.rootOverrideKeys, ["DeepSeekHarnessSessionsRootOverride"])
        XCTAssertEqual(descriptor.includeKey, "IncludeDeepSeekHarnessSessions")
        XCTAssertEqual(descriptor.binaryNames, ["dsh"])
        XCTAssertEqual(descriptor.defaultEnabled, .whenAvailable)

        XCTAssertNotNil(descriptor.parseFullByPath)
        XCTAssertNil(descriptor.parseFullByIdentity)
        XCTAssertNil(descriptor.searchUsesIdentityAtURL)
    }

    func testTelemetryUsesTheExactUnauditedReason() {
        let telemetry = source.descriptor.telemetry
        let reason = "DeepSeek Harness telemetry not yet audited"

        XCTAssertEqual(telemetry.configuration, .unavailable(reason))
        XCTAssertEqual(telemetry.tokens, .unavailable(reason))
        XCTAssertEqual(telemetry.cost, .unavailable(reason))
        XCTAssertEqual(telemetry.weeklyQuota, .unavailable("no account-level quota feed"))
    }

    func testBrandInkUsesResolvedAdaptiveColor() {
        guard case let .calibrated(red, green, blue) = source.descriptor.brandHue else {
            return XCTFail("DSH brand ink must use the calibrated adaptive-color path")
        }
        XCTAssertEqual(red, 77.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(green, 107.0 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(blue, 254.0 / 255.0, accuracy: 0.000_001)
    }

    func testResumeIsDisabledAndAgentSessionsArchiveIsFiltered() {
        let descriptor = source.descriptor

        XCTAssertFalse(descriptor.supportsResume)
        XCTAssertNil(descriptor.resumeAgentLabel)

        // This is Agent Sessions' own filtered snapshot capability. It does not
        // read or mirror DSH's workspace archive flag.
        let archive = descriptor.archive
        XCTAssertNotNil(archive)
        XCTAssertNotNil(archive?.archiveUnit)
        XCTAssertNotNil(archive?.manifestEntries)
    }

    func testAvailabilityUsesTheDefaultRootAndRootOverride() {
        let suiteName = "DeepSeekHarnessSourceDescriptorTests-Availability-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let home = URL(fileURLWithPath: "/virtual/home", isDirectory: true)
        let empty = AvailabilityContext(defaults: defaults,
                                        fileProbe: FakeFileProbe(),
                                        homeDirectory: home,
                                        environment: [:],
                                        detectBinary: { _ in false })
        XCTAssertFalse(source.descriptor.isAvailable(empty))

        let defaultRoot = "/virtual/home/.dsh/sessions"
        let defaultRootContext = AvailabilityContext(
            defaults: defaults,
            fileProbe: FakeFileProbe(directories: [defaultRoot]),
            homeDirectory: home,
            environment: [:],
            detectBinary: { _ in false }
        )
        XCTAssertTrue(source.descriptor.isAvailable(defaultRootContext))

        defaults.set("/virtual/custom-dsh/sessions", forKey: DeepSeekHarnessSettings.Keys.rootOverride)
        let overrideContext = AvailabilityContext(
            defaults: defaults,
            fileProbe: FakeFileProbe(directories: ["/virtual/custom-dsh/sessions"]),
            homeDirectory: home,
            environment: [:],
            detectBinary: { _ in false }
        )
        XCTAssertTrue(source.descriptor.isAvailable(overrideContext))
    }

    func testAvailabilityAndEnablementAcceptTheDshBinary() {
        let suiteName = "DeepSeekHarnessSourceDescriptorTests-Binary-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let context = AvailabilityContext(
            defaults: defaults,
            fileProbe: FakeFileProbe(),
            homeDirectory: URL(fileURLWithPath: "/virtual/home", isDirectory: true),
            environment: [:],
            detectBinary: { $0 == "dsh" }
        )
        XCTAssertTrue(source.descriptor.isBinaryInstalled(context))
        XCTAssertTrue(source.descriptor.isAvailable(context))

        defaults.set(false, forKey: source.descriptor.enablementKey)
        XCTAssertFalse(AgentEnablement.isEnabled(source, defaults: defaults))
        defaults.set(true, forKey: source.descriptor.enablementKey)
        XCTAssertTrue(AgentEnablement.isEnabled(source, defaults: defaults))
    }

    func testArchiveRequiresStableSnapshotWhileOtherSourcesKeepBestEffort() {
        XCTAssertTrue(source.descriptor.archive?.requiresStableSnapshot == true)
        XCTAssertFalse(SessionSource.codex.descriptor.archive?.requiresStableSnapshot == true)
        XCTAssertFalse(SessionSource.claude.descriptor.archive?.requiresStableSnapshot == true)
    }

    func testVersionIntroducedIs55() {
        XCTAssertEqual(source.versionIntroduced, "5.5")
    }
}
