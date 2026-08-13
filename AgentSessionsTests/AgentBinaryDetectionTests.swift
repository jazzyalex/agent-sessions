import XCTest
@testable import AgentSessions

final class AgentBinaryDetectionTests: XCTestCase {
    func testFindsExecutableInPATHOverride() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("mybin", isDirectory: false)
        let created = fileManager.createFile(
            atPath: binURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        XCTAssertTrue(created)

        XCTAssertTrue(AgentEnablement.binaryDetectedInPATH("mybin", pathOverride: dir.path))
    }

    func testDoesNotFindNonExecutableInPATHOverride() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("mybin", isDirectory: false)
        let created = fileManager.createFile(
            atPath: binURL.path,
            contents: Data("echo hello\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o644)]
        )
        XCTAssertTrue(created)

        XCTAssertFalse(AgentEnablement.binaryDetectedInPATH("mybin", pathOverride: dir.path))
    }

    func testUnderstandsDirectPath() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("mybin", isDirectory: false)
        let created = fileManager.createFile(
            atPath: binURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        XCTAssertTrue(created)

        XCTAssertTrue(AgentEnablement.binaryDetectedInPATH(binURL.path, pathOverride: nil))
    }

    /// `.claude` is installed when *either* `claude` or `claude-code` is on PATH.
    ///
    /// This goes through `binaryInstalled(for:pathOverride:)` rather than the
    /// no-argument form on purpose. `AppRuntime.isHostedByTooling` is true
    /// whenever `isRunningTests` is, so `binaryInstalled(for:)` returns a
    /// `UserDefaults` lookup under XCTest and never reaches the name matching
    /// this test is named for — it would pass or fail on whatever
    /// `ClaudeCLIAvailable` happens to hold in the runner's defaults domain,
    /// and the staged binary below would be dead weight.
    func testBinaryInstalledForClaude_acceptsClaudeCodeBinaryName() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("claude-code", isDirectory: false)
        let created = fileManager.createFile(
            atPath: binURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        XCTAssertTrue(created)

        XCTAssertTrue(AgentEnablement.binaryInstalled(for: .claude, pathOverride: dir.path))
    }

    /// The negative half: a directory holding neither accepted name must not
    /// report `.claude` as installed. Without this, the assertion above would
    /// still pass if `binaryInstalled` ever started returning a blanket `true`.
    func testBinaryInstalledForClaude_rejectsUnrelatedBinaryName() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("not-claude", isDirectory: false)
        XCTAssertTrue(fileManager.createFile(
            atPath: binURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        ))

        XCTAssertFalse(AgentEnablement.binaryInstalled(for: .claude, pathOverride: dir.path))
    }
}

final class FocusedSessionRefreshIntervalsTests: XCTestCase {
    func testCodexIntervalMatrix() {
        XCTAssertEqual(
            UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(for: .codex, appIsActive: true, onAC: true),
            4
        )
        XCTAssertEqual(
            UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(for: .codex, appIsActive: true, onAC: false),
            8
        )
        XCTAssertEqual(
            UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(for: .codex, appIsActive: false, onAC: true),
            20
        )
        XCTAssertEqual(
            UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(for: .codex, appIsActive: false, onAC: false),
            60
        )
    }

    func testClaudeIntervalMatrix() {
        XCTAssertEqual(
            UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(for: .claude, appIsActive: true, onAC: true),
            6
        )
        XCTAssertEqual(
            UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(for: .claude, appIsActive: true, onAC: false),
            10
        )
        XCTAssertEqual(
            UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(for: .claude, appIsActive: false, onAC: true),
            25
        )
        XCTAssertEqual(
            UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(for: .claude, appIsActive: false, onAC: false),
            60
        )
    }

    func testEveryAgentSourceHasResolvableIntervalsForFutureFocusedMonitoring() {
        for source in SessionSource.allCases {
            let activeAC = UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(
                for: source,
                appIsActive: true,
                onAC: true
            )
            let inactiveBattery = UnifiedSessionIndexer.focusedSessionRefreshIntervalSeconds(
                for: source,
                appIsActive: false,
                onAC: false
            )
            XCTAssertGreaterThan(activeAC, 0, "Expected active AC interval for \(source.rawValue)")
            XCTAssertGreaterThan(inactiveBattery, 0, "Expected inactive battery interval for \(source.rawValue)")
        }
    }

    func testFocusedMonitoringCapabilityEnabledForAllSources() {
        for source in SessionSource.allCases {
            XCTAssertTrue(
                UnifiedSessionIndexer.focusedSessionMonitoringSupported(for: source),
                "Expected focused monitor capability for \(source.rawValue)"
            )
        }
    }
}

final class ClaudeIndexerRefreshPolicyTests: XCTestCase {
    func testShouldEscalateRecentDeltaToFullReconcile_incrementalNeverEscalates() {
        XCTAssertFalse(ClaudeSessionIndexer.shouldEscalateRecentDeltaToFullReconcile(mode: .incremental))
    }

    func testShouldEscalateRecentDeltaToFullReconcile_fullReconcileNeverEscalates() {
        XCTAssertFalse(ClaudeSessionIndexer.shouldEscalateRecentDeltaToFullReconcile(mode: .fullReconcile))
    }
}
