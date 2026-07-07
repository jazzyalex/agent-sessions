import XCTest
@testable import AgentSessions

final class CodexCredentialReadTests: XCTestCase {
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
}
