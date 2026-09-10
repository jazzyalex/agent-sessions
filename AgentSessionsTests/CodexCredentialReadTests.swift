import XCTest
@testable import AgentSessions

final class CodexCredentialReadTests: XCTestCase {
    override func tearDown() {
        unsetenv("AS_TEST_CODEX_AUTH_PATH")
        super.tearDown()
    }
    func testMissingFileIsAbsent() {
        setenv("AS_TEST_CODEX_AUTH_PATH", "/nonexistent/authXYZ.json", 1)
        XCTAssertEqual(CodexOAuthCredentials().resolveRead(), .absent)
    }
    func testMalformedIsMalformed() throws {
        let p = NSTemporaryDirectory() + "codex-bad-\(UUID().uuidString).json"
        try "{ not json".write(toFile: p, atomically: true, encoding: .utf8)
        setenv("AS_TEST_CODEX_AUTH_PATH", p, 1)
        XCTAssertEqual(CodexOAuthCredentials().resolveRead(), .malformed)
    }

    func testResolveObservesImmediateAccountSwitch() async throws {
        let path = NSTemporaryDirectory() + "codex-switch-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        setenv("AS_TEST_CODEX_AUTH_PATH", path, 1)
        let credentials = CodexOAuthCredentials()

        try #"{"tokens":{"access_token":"token-a","account_id":"account-a"}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let first = await credentials.resolve()
        XCTAssertEqual(first, CodexTokenSet(accessToken: "token-a", refreshToken: nil,
                                            accountId: "account-a"))

        try #"{"account_id":"account-b","tokens":{"access_token":"token-b"}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let second = await credentials.resolve()
        XCTAssertEqual(second, CodexTokenSet(accessToken: "token-b", refreshToken: nil,
                                             accountId: "account-b"))
    }
}
