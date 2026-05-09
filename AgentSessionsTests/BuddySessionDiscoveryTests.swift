import XCTest
@testable import AgentSessions

final class BuddySessionDiscoveryTests: XCTestCase {

    func testDiscoverSessionFiles_findsJsonlUnderArbitraryTree() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("buddy-disc-\(UUID().uuidString)", isDirectory: true)
        let codeRoot = base.appendingPathComponent("codebuddy-root", isDirectory: true)
        let sessionDir = codeRoot.appendingPathComponent("encoded-path", isDirectory: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionURL = sessionDir.appendingPathComponent("session-a.jsonl")
        try Data(#"{"type":"message","timestamp":1,"role":"user","content":"x"}"#.utf8).write(to: sessionURL)

        let discovery = BuddySessionDiscovery(
            codebuddyProjectsRoot: codeRoot.path,
            workbuddyProjectsRoot: base.appendingPathComponent("empty-work").path
        )
        try fm.createDirectory(at: base.appendingPathComponent("empty-work"), withIntermediateDirectories: true)

        let found = discovery.discoverSessionFiles()
        defer { try? fm.removeItem(at: base) }

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "session-a.jsonl")
    }

    func testDiscoverSessionFiles_skipsToolResultsDirectory() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("buddy-disc-tr-\(UUID().uuidString)", isDirectory: true)
        let codeRoot = base.appendingPathComponent("cb", isDirectory: true)
        let toolResults = codeRoot.appendingPathComponent("proj/tool-results", isDirectory: true)
        let goodDir = codeRoot.appendingPathComponent("proj/sessions", isDirectory: true)
        try fm.createDirectory(at: toolResults, withIntermediateDirectories: true)
        try fm.createDirectory(at: goodDir, withIntermediateDirectories: true)
        try Data(#"{"type":"message","timestamp":1,"role":"user","content":"keep"}"#.utf8).write(to: goodDir.appendingPathComponent("good.jsonl"))
        try Data(#"{"type":"message","timestamp":1,"role":"user","content":"skip"}"#.utf8).write(to: toolResults.appendingPathComponent("noise.jsonl"))

        let discovery = BuddySessionDiscovery(
            codebuddyProjectsRoot: codeRoot.path,
            workbuddyProjectsRoot: base.appendingPathComponent("wb").path
        )
        try fm.createDirectory(at: base.appendingPathComponent("wb"), withIntermediateDirectories: true)

        let found = discovery.discoverSessionFiles()
        defer { try? fm.removeItem(at: base) }

        XCTAssertEqual(found.count, 1)
        let p = found.first?.path ?? ""
        XCTAssertFalse(p.contains("tool-results"), "tool-results JSONL must be skipped: \(p)")
    }

    func testProjectRoots_withOverrides_returnsBothURLs() {
        let d = BuddySessionDiscovery(codebuddyProjectsRoot: "/tmp/cb", workbuddyProjectsRoot: "/tmp/wb")
        let roots = d.projectRoots()
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots[0].path, "/tmp/cb")
        XCTAssertEqual(roots[1].path, "/tmp/wb")
    }
}
