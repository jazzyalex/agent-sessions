import XCTest
@testable import AgentSessions

final class ClaudeAuthClassifierTests: XCTestCase {
    private func inputs(_ cli: CLIAuthStatus, _ kc: KeychainRead = .notFound,
                       creds: Bool = false, bin: Bool = true) -> ClaudeAuthInputs {
        .init(cliStatus: cli, keychain: kc, credsFilePresentToken: creds, binaryPresent: bin)
    }
    func testAuthoritativeSignedInIsOkImmediately() {
        let c = ClaudeAuthClassifier()
        XCTAssertEqual(c.classify(inputs(.signedIn, .found("t")), now: Date()), .ok)
    }
    func testKeychainUnreadableIsUnknownNotSignedOut() {
        let c = ClaudeAuthClassifier()
        XCTAssertEqual(c.classify(inputs(.unknown, .unreadable), now: Date()), .unknown)
    }
    func testSignedOutRequiresTwoOverSixtySeconds() {
        let c = ClaudeAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0), .unknown)          // first miss
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0.addingTimeInterval(30)), .unknown) // <60s
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0.addingTimeInterval(61)), .signedOut)
    }
    func testCliMissingNoTokenIsCliNotInstalled() {
        let c = ClaudeAuthClassifier()
        XCTAssertEqual(c.classify(inputs(.cliMissing, .notFound, creds: false, bin: false), now: Date()),
                       .cliNotInstalled)
    }
    func testRecoveryResetsDebounce() {
        let c = ClaudeAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 2000)
        _ = c.classify(inputs(.signedOut, .notFound), now: t0)
        XCTAssertEqual(c.classify(inputs(.signedIn, .found("t")), now: t0.addingTimeInterval(5)), .ok)
        // A later single miss must again be .unknown, not immediately signedOut.
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0.addingTimeInterval(100)), .unknown)
    }
    func testRecoveryViaCliMissingWithTokenResetsDebounce() {
        let c = ClaudeAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 5000)
        // First absent resolution arms the debounce timer.
        XCTAssertEqual(c.classify(inputs(.unknown, .notFound, creds: false), now: t0), .unknown)
        // Recovery via a positive token signal (cliMissing but creds-file token present) must reset it.
        XCTAssertEqual(c.classify(inputs(.cliMissing, .notFound, creds: true), now: t0.addingTimeInterval(5)), .ok)
        // A later single miss must be .unknown again, NOT .signedOut from the stale t0 timer.
        XCTAssertEqual(c.classify(inputs(.unknown, .notFound, creds: false), now: t0.addingTimeInterval(65)), .unknown)
    }

    func testCliMissingStatusWithBinaryPresentDoesNotImmediatelyAlarm() {
        // Contradictory/flaky: cliStatus says cliMissing but the binary IS present, no token.
        // Must debounce (.unknown), not immediately return the alarming .cliNotInstalled.
        let c = ClaudeAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 6000)
        XCTAssertEqual(c.classify(inputs(.cliMissing, .notFound, creds: false, bin: true), now: t0), .unknown)
    }

    func testRecoveryViaUnreadableKeychainWithCredsTokenResetsDebounce() {
        let c = ClaudeAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 7000)
        // Arm the debounce with a genuine miss.
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound, creds: false), now: t0), .unknown)
        // Confirmed-good read via creds-file token while the keychain is unreadable must reset the timer.
        XCTAssertEqual(c.classify(inputs(.unknown, .unreadable, creds: true), now: t0.addingTimeInterval(10)), .ok)
        // A single later miss must be .unknown, NOT .signedOut off the stale t0 timer.
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound, creds: false), now: t0.addingTimeInterval(65)), .unknown)
    }
}
