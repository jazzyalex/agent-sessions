import XCTest
@testable import AgentSessions

final class ClaudeRunwayParserTests: XCTestCase {

    // MARK: - Token activity parser

    func testTokenActivityParserExtractsIncrementalTokenRate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let t1 = t0.addingTimeInterval(30)
        let t2 = t0.addingTimeInterval(60)
        let text = """
        \(assistantLine(id: "A", at: t0, inputTokens: 1000))
        \(assistantLine(id: "B", at: t1, inputTokens: 2000))
        \(assistantLine(id: "C", at: t2, inputTokens: 3000))
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let activity = ClaudeRunwayTokenActivityParser.activity(identity: identity, now: t2.addingTimeInterval(1))

        // consumed = tokens of B + C (anchor t0 excluded) = 5000 over a 60s span.
        XCTAssertEqual(activity?.tokensPerSecond ?? 0, 5000.0 / 60.0, accuracy: 0.001)
    }

    func testTokenActivityParserDedupesByMessageID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-dedupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let t1 = t0.addingTimeInterval(30)
        let t2 = t0.addingTimeInterval(60)
        // The final turn (id C) is emitted twice — streaming duplicates.
        let text = """
        \(assistantLine(id: "A", at: t0, inputTokens: 1000))
        \(assistantLine(id: "B", at: t1, inputTokens: 2000))
        \(assistantLine(id: "C", at: t2, inputTokens: 3000))
        \(assistantLine(id: "C", at: t2, inputTokens: 3000))
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let activity = ClaudeRunwayTokenActivityParser.activity(identity: identity, now: t2.addingTimeInterval(1))

        // Dedupe collapses the duplicate C, so the rate matches the 3-turn case.
        XCTAssertEqual(activity?.tokensPerSecond ?? 0, 5000.0 / 60.0, accuracy: 0.001)
    }

    func testTokenActivityParserIgnoresStaleActivity() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("session.jsonl")
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let t1 = t0.addingTimeInterval(30)
        let text = """
        \(assistantLine(id: "A", at: t0, inputTokens: 1000))
        \(assistantLine(id: "B", at: t1, inputTokens: 2000))
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identity = RunwaySessionIdentity(id: "session", displayName: "session", isGoal: false, logPaths: [log.path])
        let staleNow = t1.addingTimeInterval(ClaudeRunwayTokenActivityParser.maximumSampleAge + 1)
        XCTAssertNil(ClaudeRunwayTokenActivityParser.activity(identity: identity, now: staleNow))
    }

    // MARK: - Recent session scanner

    func testRecentSessionScannerDiscoversActiveLogAndSkipsStale() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-scan-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()

        let activeLog = projectDir.appendingPathComponent("active.jsonl")
        let activeText = """
        \(userLine(sessionID: "sess-active", cwd: "/tmp/proj", text: "build the thing", at: now.addingTimeInterval(-40)))
        \(assistantLine(id: "x1", at: now.addingTimeInterval(-5), inputTokens: 1200, sessionID: "sess-active", cwd: "/tmp/proj"))
        """
        try activeText.write(to: activeLog, atomically: true, encoding: .utf8)

        let staleLog = projectDir.appendingPathComponent("stale.jsonl")
        let staleText = """
        \(userLine(sessionID: "sess-stale", cwd: "/tmp/proj", text: "older task", at: now.addingTimeInterval(-400)))
        \(assistantLine(id: "y1", at: now.addingTimeInterval(-300), inputTokens: 800, sessionID: "sess-stale", cwd: "/tmp/proj"))
        """
        try staleText.write(to: staleLog, atomically: true, encoding: .utf8)

        let identities = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.id, "sess-active")
        XCTAssertEqual(identities.first?.displayName, "build the thing")
        let resolvedPaths = (identities.first?.logPaths ?? []).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        XCTAssertEqual(resolvedPaths, [activeLog.resolvingSymlinksInPath().path])
    }

    func testRecentSessionScannerPrefersAITitleOverFirstPrompt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-aititle-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let log = projectDir.appendingPathComponent("session.jsonl")
        let text = """
        \(userLine(sessionID: "sess-1", cwd: "/tmp/proj", text: "do Now — 1.0 release blockers — the long detailed prompt", at: now.addingTimeInterval(-30)))
        {"type":"ai-title","aiTitle":"1.0 release blockers","sessionId":"sess-1"}
        \(assistantLine(id: "z1", at: now.addingTimeInterval(-5), inputTokens: 900, sessionID: "sess-1", cwd: "/tmp/proj"))
        """
        try text.write(to: log, atomically: true, encoding: .utf8)

        let identities = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now)
        XCTAssertEqual(identities.first?.displayName, "1.0 release blockers")
    }

    func testRecentSessionScannerFoldsSubagentsIntoParentSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-subagent-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        let subagentDir = projectDir.appendingPathComponent("sess-parent/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        // Parent main transcript carries the session title.
        let parentLog = projectDir.appendingPathComponent("sess-parent.jsonl")
        try """
        {"type":"ai-title","aiTitle":"ship the release","sessionId":"sess-parent"}
        \(assistantLine(id: "p1", at: now.addingTimeInterval(-8), inputTokens: 1000, sessionID: "sess-parent", cwd: "/tmp/proj"))
        """.write(to: parentLog, atomically: true, encoding: .utf8)

        // Subagent transcript shares the parent sessionId; its first prompt is an
        // internal task that must NOT become the row name.
        let subagentLog = subagentDir.appendingPathComponent("agent-abc.jsonl")
        try """
        \(userLine(sessionID: "sess-parent", cwd: "/tmp/proj", text: "You are a subagent: grep the repo", at: now.addingTimeInterval(-6)))
        \(assistantLine(id: "s1", at: now.addingTimeInterval(-3), inputTokens: 2000, sessionID: "sess-parent", cwd: "/tmp/proj"))
        """.write(to: subagentLog, atomically: true, encoding: .utf8)

        let identities = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.count, 1, "parent + subagent should collapse to one session")
        XCTAssertEqual(identities.first?.id, "sess-parent")
        XCTAssertEqual(identities.first?.displayName, "ship the release", "parent title wins, never the subagent task")
        XCTAssertEqual(identities.first?.logPaths.count, 2, "both transcripts contribute to cumulative burn")
    }

    func testRecentSessionScannerCapsDistinctSessionsNotSubagentFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-runway-subagent-cap-\(UUID().uuidString)")
        let projectDir = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        let subagentDir = projectDir.appendingPathComponent("sess-parent/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let parentLog = projectDir.appendingPathComponent("sess-parent.jsonl")
        try """
        {"type":"ai-title","aiTitle":"parent work","sessionId":"sess-parent"}
        \(assistantLine(id: "parent", at: now.addingTimeInterval(-8), inputTokens: 1000, sessionID: "sess-parent", cwd: "/tmp/proj"))
        """.write(to: parentLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: parentLog.path)

        for index in 0..<85 {
            let log = subagentDir.appendingPathComponent("agent-\(index).jsonl")
            try """
            \(assistantLine(id: "sub-\(index)", at: now.addingTimeInterval(-4), inputTokens: 1000, sessionID: "sess-parent", cwd: "/tmp/proj"))
            """.write(to: log, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(TimeInterval(-index))], ofItemAtPath: log.path)
        }

        let otherLog = projectDir.appendingPathComponent("sess-other.jsonl")
        try """
        \(userLine(sessionID: "sess-other", cwd: "/tmp/proj", text: "other active work", at: now.addingTimeInterval(-12)))
        \(assistantLine(id: "other", at: now.addingTimeInterval(-5), inputTokens: 900, sessionID: "sess-other", cwd: "/tmp/proj"))
        """.write(to: otherLog, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90)], ofItemAtPath: otherLog.path)

        let identities = ClaudeRunwayRecentSessionScanner.identities(root: root, now: now)

        XCTAssertEqual(identities.map(\.id), ["sess-parent", "sess-other"])
        XCTAssertEqual(identities.first?.logPaths.count, 86)
    }

    func testDesktopSessionTitlesMapKeysByCliSessionId() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-titles-\(UUID().uuidString)")
        let convoDir = root.appendingPathComponent("convoA/sessionB", isDirectory: true)
        try FileManager.default.createDirectory(at: convoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"sessionId":"local_abc","cliSessionId":"f1d39390-aaaa","title":"Quota meter and runway polish","titleSource":"auto"}
        """.write(to: convoDir.appendingPathComponent("local_abc.json"), atomically: true, encoding: .utf8)
        // A record with an empty title is ignored.
        try """
        {"sessionId":"local_def","cliSessionId":"99999999-bbbb","title":""}
        """.write(to: convoDir.appendingPathComponent("local_def.json"), atomically: true, encoding: .utf8)
        // A non-local file is ignored.
        try "{\"cliSessionId\":\"zzz\",\"title\":\"nope\"}"
            .write(to: convoDir.appendingPathComponent("other.json"), atomically: true, encoding: .utf8)

        let map = ClaudeDesktopSessionTitles.map(root: root)
        XCTAssertEqual(map["f1d39390-aaaa"], "Quota meter and runway polish")
        XCTAssertNil(map["99999999-bbbb"])
        XCTAssertNil(map["zzz"])
    }

    // MARK: - Helpers

    private func assistantLine(id: String,
                               at date: Date,
                               inputTokens: Int,
                               sessionID: String = "session",
                               cwd: String? = nil) -> String {
        let cwdField = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"sessionId\":\"\(sessionID)\",\(cwdField)\"timestamp\":\"\(iso(date))\",\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":\(inputTokens),\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func userLine(sessionID: String, cwd: String, text: String, at date: Date) -> String {
        return "{\"type\":\"user\",\"sessionId\":\"\(sessionID)\",\"cwd\":\"\(cwd)\",\"timestamp\":\"\(iso(date))\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
