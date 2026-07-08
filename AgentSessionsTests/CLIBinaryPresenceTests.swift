import XCTest
@testable import AgentSessions

final class CLIBinaryPresenceTests: XCTestCase {
    func testOverridePathPresentWins() {
        let present = CLIBinaryPresence.isPresent(
            overridePath: "/custom/claude", candidates: ["/opt/homebrew/bin/claude"],
            fileExists: { $0 == "/custom/claude" })
        XCTAssertTrue(present)
    }

    func testCandidatePresent() {
        let present = CLIBinaryPresence.isPresent(
            overridePath: nil, candidates: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"],
            fileExists: { $0 == "/usr/local/bin/codex" })
        XCTAssertTrue(present)
    }

    func testAbsentEverywhere() {
        let present = CLIBinaryPresence.isPresent(
            overridePath: "/custom/claude", candidates: ["/opt/homebrew/bin/claude"],
            fileExists: { _ in false })
        XCTAssertFalse(present)
    }

    func testEmptyOverrideIgnored() {
        // Empty override must not count as "present"; falls through to candidates.
        let present = CLIBinaryPresence.isPresent(
            overridePath: "", candidates: ["/opt/homebrew/bin/claude"],
            fileExists: { $0 == "/opt/homebrew/bin/claude" })
        XCTAssertTrue(present)
        let absent = CLIBinaryPresence.isPresent(
            overridePath: "", candidates: ["/opt/homebrew/bin/claude"],
            fileExists: { _ in false })
        XCTAssertFalse(absent)
    }

    func testCandidateListsAreProviderSpecificAndNonEmpty() {
        XCTAssertTrue(CLIBinaryPresence.claudeCandidates(home: "/Users/x").allSatisfy { $0.contains("claude") })
        XCTAssertTrue(CLIBinaryPresence.codexCandidates(home: "/Users/x").allSatisfy { $0.contains("codex") })
        XCTAssertFalse(CLIBinaryPresence.claudeCandidates(home: "/Users/x").isEmpty)
        XCTAssertFalse(CLIBinaryPresence.codexCandidates(home: "/Users/x").isEmpty)
    }
}
