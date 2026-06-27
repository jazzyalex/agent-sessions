import XCTest

final class ClaudeArchivedFilterTests: XCTestCase {
    private func session(_ id: String, source: SessionSource, hint: String?) -> Session {
        Session(id: id, source: source, startTime: nil, endTime: nil, model: nil,
                filePath: "/tmp/\(id).jsonl", eventCount: 0, events: [],
                codexInternalSessionIDHint: hint)
    }

    func testArchivedClaudeOnlyHidesNonArchivedClaudeButKeepsOthers() {
        var f = Filters()
        f.archivedClaudeDesktopOnly = true
        f.archivedClaudeSessionIDs = ["cli-arch"]

        let archived = session("a", source: .claude, hint: "cli-arch")
        let normal = session("b", source: .claude, hint: "cli-norm")
        let codex = session("c", source: .codex, hint: nil)

        XCTAssertTrue(FilterEngine.sessionMatches(archived, filters: f))
        XCTAssertFalse(FilterEngine.sessionMatches(normal, filters: f))
        XCTAssertTrue(FilterEngine.sessionMatches(codex, filters: f))
    }

    func testOffByDefaultShowsAllClaude() {
        let f = Filters()
        let normal = session("b", source: .claude, hint: "cli-norm")
        XCTAssertTrue(FilterEngine.sessionMatches(normal, filters: f))
    }
}
