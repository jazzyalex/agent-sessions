import XCTest
import Darwin
@testable import AgentSessions

@MainActor
final class PiSettingsTests: XCTestCase {
    private func makeSettings(function: String = #function) -> PiSettings {
        let suite = "PiSettingsTests.\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PiSettings.makeForTesting(defaults: defaults)
    }

    func testCopyCommandPlanUsesCachedBinaryWhenCapabilitiesAreKnown() {
        let settings = makeSettings()
        let binaryPath = makeTempExecutable(name: "pi-settings-ok")
        settings.setResolvedBinary(binaryPath, supportsSession: true, supportsResume: true, supportsContinue: true)

        let plan = settings.copyCommandPlan(sessionID: "sess-1")
        XCTAssertEqual(plan?.binary, binaryPath)
        XCTAssertEqual(sessionID(of: plan?.strategy), "sess-1")
    }

    /// A cache written by a probe that could not execute the CLI records a real
    /// binary with every capability false. Trusting it makes Copy Resume
    /// Command return nothing at all, forever — the cache is only refreshed
    /// when the resolved path is empty. A binary that supports nothing is not a
    /// finding, it is a failed probe: drop it and fall back to plain `pi`.
    func testCopyCommandPlanDiscardsACacheThatAdvertisesNoCapabilities() {
        let settings = makeSettings()
        let binaryPath = makeTempExecutable(name: "pi-settings-poisoned")
        settings.setResolvedBinary(binaryPath, supportsSession: false, supportsResume: false, supportsContinue: false)

        let plan = settings.copyCommandPlan(sessionID: "sess-1")
        XCTAssertNotNil(plan, "a failed probe must not silently disable Copy Resume Command")
        XCTAssertEqual(plan?.binary, "pi")
        XCTAssertEqual(sessionID(of: plan?.strategy), "sess-1")
        XCTAssertTrue(settings.resolvedBinaryPath.isEmpty, "the unusable cache entry should be cleared")
    }

    /// `Strategy` is not Equatable, and making it so for a test would be tail
    /// wagging dog — the only thing these assertions care about is that the plan
    /// resumes the requested session rather than falling back to --continue.
    /// The reader discards a capability-free cache, but the writer is what stops
    /// one being stored in the first place. Without this the probe rewrites the
    /// dead entry after every discard, so each Copy Resume Command spawns a
    /// fresh login shell and the cache never settles.
    func testAProbeThatLearnedNothingIsNotStored() {
        let settings = makeSettings()
        let binaryPath = makeTempExecutable(name: "pi-settings-nothing-learned")

        settings.setResolvedBinary(binaryPath, supportsSession: false, supportsResume: false, supportsContinue: false)

        XCTAssertTrue(settings.resolvedBinaryPath.isEmpty)
        XCTAssertFalse(settings.resolvedSupportsSession)
        XCTAssertFalse(settings.resolvedSupportsResume)
        XCTAssertFalse(settings.resolvedSupportsContinue)
    }

    /// Clearing must take the capability flags with it — a yes behind an empty
    /// path is a state no probe produces.
    func testClearingAResolvedBinaryAlsoClearsItsCapabilities() {
        let settings = makeSettings()
        settings.setResolvedBinary(makeTempExecutable(name: "pi-settings-clear"),
                                   supportsSession: true, supportsResume: true, supportsContinue: true)

        settings.clearResolvedBinary()

        XCTAssertTrue(settings.resolvedBinaryPath.isEmpty)
        XCTAssertFalse(settings.resolvedSupportsSession)
        XCTAssertFalse(settings.resolvedSupportsResume)
        XCTAssertFalse(settings.resolvedSupportsContinue)
    }

    private func sessionID(of strategy: PiResumeCommandBuilder.Strategy?) -> String? {
        guard case let .sessionByID(id) = strategy else { return nil }
        return id
    }

    private func makeTempExecutable(name: String) -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let file = dir.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        _ = chmod(file.path, 0o755)
        return file.path
    }
}
