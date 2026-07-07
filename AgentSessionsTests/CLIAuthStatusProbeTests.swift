import XCTest
@testable import AgentSessions

final class CLIAuthStatusProbeTests: XCTestCase {
    func testClaudeSignedIn() {
        XCTAssertEqual(CLIAuthStatusProbe.parseClaudeAuthStatus(stdout: "{\"loggedIn\": true, \"email\": \"x\"}", exitCode: 0), .signedIn)
    }
    func testClaudeSignedOut() {
        XCTAssertEqual(CLIAuthStatusProbe.parseClaudeAuthStatus(stdout: "{\"loggedIn\": false}", exitCode: 1), .signedOut)
    }
    func testClaudeGarbageIsUnknown() {
        XCTAssertEqual(CLIAuthStatusProbe.parseClaudeAuthStatus(stdout: "not json", exitCode: 0), .unknown)
        XCTAssertEqual(CLIAuthStatusProbe.parseClaudeAuthStatus(stdout: "", exitCode: 0), .unknown)
    }
    func testCodexSignedIn() {
        XCTAssertEqual(CLIAuthStatusProbe.parseCodexLoginStatus(stdout: "Logged in using ChatGPT", exitCode: 0), .signedIn)
    }
    func testCodexSignedOut() {
        XCTAssertEqual(CLIAuthStatusProbe.parseCodexLoginStatus(stdout: "Not logged in", exitCode: 1), .signedOut)
        XCTAssertEqual(CLIAuthStatusProbe.parseCodexLoginStatus(stdout: "You are logged out", exitCode: 1), .signedOut)
    }
    func testCodexUnrecognizedIsUnknown() {
        XCTAssertEqual(CLIAuthStatusProbe.parseCodexLoginStatus(stdout: "some error", exitCode: 2), .unknown)
    }
}
