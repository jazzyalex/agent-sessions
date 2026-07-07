import XCTest
@testable import AgentSessions

final class CodexAuthClassifierTests: XCTestCase {
    private func tok() -> CodexTokenSet { .init(accessToken: "t", refreshToken: nil, accountId: nil) }

    func testUnauthorizedFetchIsExpired() {
        let c = CodexAuthClassifier()
        XCTAssertEqual(c.classify(cliStatus: .unknown, creds: .present(tok()),
                                  lastFetch: .unauthorized, binaryPresent: true, now: Date()), .expired)
    }
    func testAbsentCredsCliMissingIsCliNotInstalled() {
        let c = CodexAuthClassifier()
        XCTAssertEqual(c.classify(cliStatus: .cliMissing, creds: .absent, lastFetch: nil,
                                  binaryPresent: false, now: Date()), .cliNotInstalled)
    }
    func testAbsentCredsDebouncesSignedOut() {
        let c = CodexAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 3000)
        XCTAssertEqual(c.classify(cliStatus: .signedOut, creds: .absent, lastFetch: nil, binaryPresent: true, now: t0), .unknown)
        XCTAssertEqual(c.classify(cliStatus: .signedOut, creds: .absent, lastFetch: nil, binaryPresent: true, now: t0.addingTimeInterval(61)), .signedOut)
    }
    func testTransientFetchWithTokenStaysOk() {
        let c = CodexAuthClassifier()
        XCTAssertEqual(c.classify(cliStatus: .signedIn, creds: .present(tok()),
                                  lastFetch: .transient, binaryPresent: true, now: Date()), .ok)
    }
    // Regression: flaky cliStatus=.cliMissing but binary IS present + no creds must debounce, not immediately alarm.
    func testCliMissingWithBinaryPresentDoesNotImmediatelyAlarm() {
        let c = CodexAuthClassifier()
        XCTAssertEqual(c.classify(cliStatus: .cliMissing, creds: .absent, lastFetch: nil,
                                  binaryPresent: true, now: Date(timeIntervalSince1970: 100)), .unknown)
    }
    // Regression: a positive signal must reset the debounce so a later single miss can't false-alarm.
    func testRecoveryResetsDebounce() {
        let c = CodexAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(c.classify(cliStatus: .signedOut, creds: .absent, lastFetch: nil, binaryPresent: true, now: t0), .unknown)
        XCTAssertEqual(c.classify(cliStatus: .signedIn, creds: .present(tok()), lastFetch: nil, binaryPresent: true, now: t0.addingTimeInterval(5)), .ok)
        XCTAssertEqual(c.classify(cliStatus: .signedOut, creds: .absent, lastFetch: nil, binaryPresent: true, now: t0.addingTimeInterval(65)), .unknown)
    }
    func testSuccessfulFetchOverridesAbsentCreds() {
        // auth.json deleted without logout: disk .absent, but a cached fetch still succeeds.
        let c = CodexAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 400)
        XCTAssertEqual(c.classify(cliStatus: .unknown, creds: .absent,
                                  lastFetch: .ok(CodexUsageSnapshot()), binaryPresent: true, now: t0), .ok)
        XCTAssertEqual(c.classify(cliStatus: .unknown, creds: .absent,
                                  lastFetch: .ok(CodexUsageSnapshot()), binaryPresent: true, now: t0.addingTimeInterval(120)), .ok)
    }
}
