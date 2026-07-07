import XCTest
@testable import AgentSessions

final class KeychainResultTests: XCTestCase {
    func testExit44IsNotFound() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: 44, timedOut: false, stdout: ""), .notFound)
    }
    func testTimeoutIsUnreadable() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: nil, timedOut: true, stdout: nil), .unreadable)
    }
    func testOtherNonZeroIsUnreadable() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: 51, timedOut: false, stdout: nil), .unreadable)
    }
    func testZeroWithTokenIsFound() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: 0, timedOut: false, stdout: "sk-ant-oat01-x"),
                       .found("sk-ant-oat01-x"))
    }
    func testZeroEmptyIsNotFound() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: 0, timedOut: false, stdout: "  "), .notFound)
    }
}
