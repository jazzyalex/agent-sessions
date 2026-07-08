import XCTest
@testable import AgentSessions

final class ClaudeAuthClassifierTests: XCTestCase {
    private func inputs(_ cli: CLIAuthStatus, _ kc: KeychainRead = .notFound,
                       creds: Bool = false, bin: Bool = true, envToken: Bool = false) -> ClaudeAuthInputs {
        .init(cliStatus: cli, keychain: kc, credsFilePresentToken: creds, binaryPresent: bin,
              envTokenPresent: envToken)
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

    // Fix I6: an env-provided token (CLAUDE_CODE_OAUTH_TOKEN) is authoritative
    // token evidence — a working-runway env-token user must never be misread as
    // tokenless and driven to .signedOut, nor as .cliNotInstalled if the binary
    // happens to be absent from the candidate list.
    func testEnvTokenPreventsSignedOut() {
        let c = ClaudeAuthClassifier()
        // Keychain notFound, no creds file, authoritative .signedOut — but env token present.
        XCTAssertEqual(
            c.classify(inputs(.signedOut, .notFound, creds: false, envToken: true), now: Date()),
            .ok
        )
        // Even a repeated miss over the debounce window stays .ok, never .signedOut.
        let t0 = Date(timeIntervalSince1970: 8000)
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound, envToken: true), now: t0), .ok)
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound, envToken: true), now: t0.addingTimeInterval(120)), .ok)
        // And .cliNotInstalled must not fire when env token present even if the binary is absent.
        XCTAssertEqual(
            c.classify(inputs(.cliMissing, .notFound, creds: false, bin: false, envToken: true), now: Date()),
            .ok
        )
    }

    // Fix I5: reset() clears the debounce clock so a fast-path .ok/.expired verdict
    // that bypasses classify() cannot leave a stale firstMissAt behind. Two isolated
    // misses with a reset (healthy poll) between them must not accumulate to .signedOut.
    func testResetClearsDebounce() {
        let c = ClaudeAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 9000)
        // Arm the debounce with a genuine miss.
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0), .unknown)
        // A healthy fast-path poll resets the clock outside classify().
        c.reset()
        // A single later miss (≥60s after the original) must be .unknown again, NOT .signedOut.
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0.addingTimeInterval(120)), .unknown)
    }
}
