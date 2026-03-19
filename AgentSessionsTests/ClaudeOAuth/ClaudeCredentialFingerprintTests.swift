import XCTest
@testable import AgentSessions

final class ClaudeCredentialFingerprintTests: XCTestCase {

    func testCapture_returnsFingerprint() async {
        let watcher = ClaudeCredentialFingerprint()
        let fp = await watcher.capture()
        // capturedAt should be recent
        XCTAssertLessThan(Date().timeIntervalSince(fp.capturedAt), 5)
    }

    func testHasChanged_identicalFingerprint_returnsFalse() async {
        let watcher = ClaudeCredentialFingerprint()
        let fp = await watcher.capture()
        // Capturing again immediately should produce no change
        let changed = await watcher.hasChanged(since: fp)
        XCTAssertFalse(changed, "Back-to-back captures should not report a change")
    }

    func testHasChanged_differentHash_returnsTrue() async {
        let watcher = ClaudeCredentialFingerprint()
        // Build a synthetic "prior" fingerprint with a fake hash
        let fakePrior = ClaudeCredentialFingerprint.Fingerprint(
            keychainModDate: Date.distantPast,
            credFileHash: "deadbeef",
            capturedAt: Date.distantPast
        )
        // Current fingerprint will differ (either hash or mtime)
        let changed = await watcher.hasChanged(since: fakePrior)
        XCTAssertTrue(changed, "Fingerprint with distantPast mtime should always report change")
    }
}
