import XCTest
@testable import AgentSessions

final class GrokSessionDiscoveryTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grok-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func makeSession(in root: URL,
                             bucket: String,
                             id: String,
                             withSummary: Bool = true,
                             withTranscript: Bool = true) throws -> URL {
        let dir = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withTranscript {
            try #"{"type":"system","content":"x"}"#
                .write(to: dir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)
        }
        if withSummary {
            try #"{"info":{"id":"x"}}"#
                .write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testDiscoversTranscriptsBesideTheirSidecar() throws {
        let root = try makeRoot()
        try makeSession(in: root, bucket: "%2Ftmp%2Fa", id: "019f0000-0000-7000-8000-000000000001")
        try makeSession(in: root, bucket: "%2Ftmp%2Fb", id: "019f0000-0000-7000-8000-000000000002")

        let found = GrokSessionDiscovery(customRoot: root.path).discoverSessionFiles()
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.allSatisfy { $0.lastPathComponent == "chat_history.jsonl" })
    }

    /// A directory without `summary.json` is not a session: the sidecar is the
    /// only source of identity, cwd, model and both timestamps.
    func testSkipsSessionsMissingTheSidecar() throws {
        let root = try makeRoot()
        try makeSession(in: root, bucket: "%2Ftmp%2Fa", id: "019f0000-0000-7000-8000-000000000003", withSummary: false)

        XCTAssertTrue(GrokSessionDiscovery(customRoot: root.path).discoverSessionFiles().isEmpty)
    }

    func testSkipsSessionsMissingTheTranscript() throws {
        let root = try makeRoot()
        try makeSession(in: root, bucket: "%2Ftmp%2Fa", id: "019f0000-0000-7000-8000-000000000004", withTranscript: false)

        XCTAssertTrue(GrokSessionDiscovery(customRoot: root.path).discoverSessionFiles().isEmpty)
    }

    /// Session directories hold `subagents/`, `terminal/` and `compaction/`
    /// subtrees. A recursive scan would surface a nested transcript as if it
    /// were a top-level session, so discovery walks exactly two levels.
    func testIgnoresNestedTranscriptsInsideSessionSubdirectories() throws {
        let root = try makeRoot()
        let dir = try makeSession(in: root, bucket: "%2Ftmp%2Fa", id: "019f0000-0000-7000-8000-000000000005")
        let nested = dir.appendingPathComponent("subagents/agent-1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try #"{"type":"system","content":"x"}"#
            .write(to: nested.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)
        try #"{"info":{"id":"x"}}"#
            .write(to: nested.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)

        let found = GrokSessionDiscovery(customRoot: root.path).discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertFalse(found[0].path.contains("subagents"))
    }

    func testSessionIDIsTheDirectoryHoldingTheTranscript() {
        let url = URL(fileURLWithPath: "/tmp/sessions/%2Ftmp%2Fa/019f0000-0000-7000-8000-000000000006/chat_history.jsonl")
        XCTAssertEqual(GrokSessionDiscovery.sessionID(forTranscript: url),
                       "019f0000-0000-7000-8000-000000000006")
        XCTAssertEqual(GrokSessionDiscovery.summaryFile(forTranscript: url).lastPathComponent,
                       "summary.json")
    }

    /// A custom root may point either at `~/.grok` or straight at its
    /// `sessions/` child; both must resolve to the same scan root.
    func testCustomRootAcceptsHomeOrSessionsDirectory() throws {
        let root = try makeRoot()
        try makeSession(in: root, bucket: "%2Ftmp%2Fa", id: "019f0000-0000-7000-8000-000000000007")

        let viaHome = GrokSessionDiscovery(customRoot: root.path).discoverSessionFiles()
        let viaSessions = GrokSessionDiscovery(
            customRoot: root.appendingPathComponent("sessions").path).discoverSessionFiles()
        XCTAssertEqual(viaHome.count, 1)
        XCTAssertEqual(viaHome.map(\.path), viaSessions.map(\.path))
    }
}
