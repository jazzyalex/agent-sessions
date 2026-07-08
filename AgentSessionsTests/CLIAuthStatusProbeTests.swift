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

    // MARK: - I7a: per-line anchored parsing (no false `.signedOut`)

    /// A signed-in account whose output carries a logout HINT must stay signed
    /// in. Substring matching over the whole blob risks reading the hint as a
    /// signed-out status; the per-line parser ignores the instruction.
    func testCodexSignedInWithLogoutHintNotMisclassified() {
        XCTAssertEqual(
            CLIAuthStatusProbe.parseCodexLoginStatus(
                stdout: "Logged in using ChatGPT\nRun `codex logout` to sign out",
                exitCode: 0),
            .signedIn)
    }

    /// A definitive "not logged in" status is signed-out whether it is the whole
    /// line or embedded in a sentence ("You are not logged in.").
    func testCodexNotLoggedInLine() {
        XCTAssertEqual(CLIAuthStatusProbe.parseCodexLoginStatus(stdout: "Not logged in", exitCode: 0), .signedOut)
        XCTAssertEqual(CLIAuthStatusProbe.parseCodexLoginStatus(stdout: "You are not logged in.", exitCode: 0), .signedOut)
    }

    /// Unrelated output carries no definitive signal → `.unknown` (never a
    /// guessed `.signedOut`).
    func testCodexAmbiguousUnknown() {
        XCTAssertEqual(CLIAuthStatusProbe.parseCodexLoginStatus(stdout: "some unrelated error", exitCode: 0), .unknown)
    }

    /// A contradictory mix of a definitive signed-in status AND a signed-out
    /// status is ambiguous — refuse to guess rather than false-alarm.
    func testCodexContradictoryMixIsUnknown() {
        XCTAssertEqual(
            CLIAuthStatusProbe.parseCodexLoginStatus(
                stdout: "Logged in using ChatGPT\nNot logged in",
                exitCode: 0),
            .unknown)
    }
}
