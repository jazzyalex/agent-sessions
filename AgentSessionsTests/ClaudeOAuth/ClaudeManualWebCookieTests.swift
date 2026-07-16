import XCTest
@testable import AgentSessions

/// Tests for the user-pasted claude.ai session-cookie path (the safe, durable web
/// source: no WKWebView, no FDA, no Safari scraping). The pure extractor is tested
/// directly; the persistence layer is tested through an in-memory `ClaudeSecretStore`
/// so the suite never touches the real login Keychain.
final class ClaudeManualWebCookieTests: XCTestCase {

    // MARK: - extractSessionKey

    func testBareToken_returnedAsIs() {
        XCTAssertEqual(ClaudeManualWebCookie.extractSessionKey(fromPasted: "sk-ant-sid01-FAKEtoken"),
                       "sk-ant-sid01-FAKEtoken")
    }

    func testKeyEqualsValuePair_extractsValue() {
        XCTAssertEqual(ClaudeManualWebCookie.extractSessionKey(fromPasted: "sessionKey=sk-ant-sid01-FAKE"),
                       "sk-ant-sid01-FAKE")
    }

    func testFullCookieHeader_extractsSessionKeyOnly() {
        let header = "intercom-device-id=abc; sessionKey=sk-ant-sid01-FAKE; lastActiveOrg=xyz"
        XCTAssertEqual(ClaudeManualWebCookie.extractSessionKey(fromPasted: header), "sk-ant-sid01-FAKE")
    }

    func testCookieNameEndingInSessionKey_isNotMistakenForIt() {
        // A different cookie whose name ends in "sessionKey" must not be matched
        // as the sessionKey pair — the match has to be name-anchored.
        let header = "anon_sessionKey=WRONG; sessionKey=sk-ant-sid01-RIGHT; lastActiveOrg=xyz"
        XCTAssertEqual(ClaudeManualWebCookie.extractSessionKey(fromPasted: header), "sk-ant-sid01-RIGHT")
    }

    func testSessionKeyNotFirst_afterAnotherPairWithEqualsInValue() {
        let header = "redirect=/foo?sessionKey=DECOY; sessionKey=sk-ant-sid01-RIGHT"
        XCTAssertEqual(ClaudeManualWebCookie.extractSessionKey(fromPasted: header), "sk-ant-sid01-RIGHT")
    }

    func testCookieHeaderLabelPrefix_isStripped() {
        XCTAssertEqual(ClaudeManualWebCookie.extractSessionKey(fromPasted: "Cookie: sessionKey=sk-ant-sid01-FAKE"),
                       "sk-ant-sid01-FAKE")
    }

    func testValueStopsAtSemicolonAndWhitespace() {
        XCTAssertEqual(ClaudeManualWebCookie.extractSessionKey(fromPasted: "sessionKey=sk-ant-FAKE ; next=1"),
                       "sk-ant-FAKE")
    }

    func testSurroundingWhitespaceAndNewlines_trimmed() {
        XCTAssertEqual(ClaudeManualWebCookie.extractSessionKey(fromPasted: "\n  sk-ant-sid01-FAKE \t\n"),
                       "sk-ant-sid01-FAKE")
    }

    func testEmpty_isNil() {
        XCTAssertNil(ClaudeManualWebCookie.extractSessionKey(fromPasted: "   \n "))
    }

    func testHeaderWithoutSessionKey_isNil() {
        XCTAssertNil(ClaudeManualWebCookie.extractSessionKey(fromPasted: "lastActiveOrg=xyz; foo=bar"))
    }

    func testSessionKeyEmptyValue_isNil() {
        XCTAssertNil(ClaudeManualWebCookie.extractSessionKey(fromPasted: "sessionKey=; foo=bar"))
    }

    // MARK: - store round-trip (in-memory)

    func testSaveThenRead_roundTrips() {
        let store = ClaudeManualWebCookieStore(secretStore: InMemorySecretStore())
        XCTAssertFalse(store.hasStoredCookie)
        XCTAssertTrue(store.save(pasted: "sessionKey=sk-ant-sid01-FAKE; other=1"))
        XCTAssertEqual(store.currentSessionKey(), "sk-ant-sid01-FAKE")
        XCTAssertTrue(store.hasStoredCookie)
    }

    func testSaveInvalid_returnsFalse_andStoresNothing() {
        let store = ClaudeManualWebCookieStore(secretStore: InMemorySecretStore())
        XCTAssertFalse(store.save(pasted: "lastActiveOrg=xyz; foo=bar"))
        XCTAssertNil(store.currentSessionKey())
        XCTAssertFalse(store.hasStoredCookie)
    }

    func testClear_removesStoredCookie() {
        let store = ClaudeManualWebCookieStore(secretStore: InMemorySecretStore())
        XCTAssertTrue(store.save(pasted: "sk-ant-sid01-FAKE"))
        store.clear()
        XCTAssertNil(store.currentSessionKey())
        XCTAssertFalse(store.hasStoredCookie)
    }
}

/// In-memory `ClaudeSecretStore` for tests — never touches the real Keychain.
private final class InMemorySecretStore: ClaudeSecretStore {
    private var value: String?
    func read() -> String? { value }
    @discardableResult func write(_ value: String) -> Bool { self.value = value; return true }
    func delete() { value = nil }
}
