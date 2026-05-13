import XCTest
@testable import AgentSessions

final class PiSessionParserTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/Fixtures/stage0/agents/pi/small.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    func testParseFileReadsPiSessionHeader() throws {
        let session = try XCTUnwrap(PiSessionParser.parseFile(at: fixtureURL()))

        XCTAssertEqual(session.id, "019e19b4-eb48-746a-aa6b-8dfcfa37954b")
        XCTAssertEqual(session.source, .pi)
        XCTAssertEqual(session.model, "pi-fixture-model")
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-agent-fixture/project")
        XCTAssertEqual(session.lightweightTitle, "Read hello.py and summarize what it prints without editing files.")
        XCTAssertEqual(session.surface, .cli)
        XCTAssertEqual(session.reasoningEffort, "off")
        XCTAssertTrue(session.events.isEmpty)
    }

    func testParseFileFullBuildsUserAssistantAndMetaEvents() throws {
        let session = try XCTUnwrap(PiSessionParser.parseFileFull(at: fixtureURL()))

        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 2)
        XCTAssertEqual(session.events.filter { $0.kind == .assistant }.count, 2)
        XCTAssertGreaterThanOrEqual(session.events.filter { $0.kind == .meta }.count, 3)
        XCTAssertTrue(session.events.contains { $0.text?.contains("hello.py prints a fixture greeting.") == true })
    }

    func testParseFileFullSkipsOversizedPiFileUnlessExplicitlyAllowed() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-oversized-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let url = temp.appendingPathComponent("oversized.jsonl")
        let lines = [
            #"{"type":"session","version":3,"id":"oversized-root","timestamp":"2026-05-12T01:00:00.000Z","cwd":"/tmp/as-agent-fixture/project"}"#,
            #"{"type":"message","id":"m1","parentId":"oversized-root","timestamp":"2026-05-12T01:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Keep this lightweight unless explicitly requested."}]}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(PiSessionParser.defaultFullParseMaxBytes + 1))
        try handle.close()

        XCTAssertNil(PiSessionParser.parseFileFull(at: url))
        XCTAssertEqual(PiSessionParser.parseFileFull(at: url, allowLargeFile: true)?.id, "oversized-root")
    }

    func testUnindexedLargePiSessionRequiresDeepScanForSearchFallback() {
        let smallPi = makeSearchCandidate(id: "small-pi", source: .pi, fileSizeBytes: FeatureFlags.searchSmallSizeBytes - 1)
        let largePi = makeSearchCandidate(id: "large-pi", source: .pi, fileSizeBytes: FeatureFlags.searchSmallSizeBytes)
        let largeCursor = makeSearchCandidate(id: "large-cursor", source: .cursor, fileSizeBytes: FeatureFlags.searchSmallSizeBytes * 2)

        XCTAssertTrue(SearchCoordinator.shouldIncludeUnindexedCandidate(smallPi,
                                                                        indexedIDs: [],
                                                                        seenIDs: [],
                                                                        enableDeepScan: false,
                                                                        smallSearchThreshold: FeatureFlags.searchSmallSizeBytes))
        XCTAssertFalse(SearchCoordinator.shouldIncludeUnindexedCandidate(largePi,
                                                                         indexedIDs: [],
                                                                         seenIDs: [],
                                                                         enableDeepScan: false,
                                                                         smallSearchThreshold: FeatureFlags.searchSmallSizeBytes))
        XCTAssertTrue(SearchCoordinator.shouldIncludeUnindexedCandidate(largePi,
                                                                        indexedIDs: [],
                                                                        seenIDs: [],
                                                                        enableDeepScan: true,
                                                                        smallSearchThreshold: FeatureFlags.searchSmallSizeBytes))
        XCTAssertTrue(SearchCoordinator.shouldIncludeUnindexedCandidate(largeCursor,
                                                                        indexedIDs: [],
                                                                        seenIDs: [],
                                                                        enableDeepScan: false,
                                                                        smallSearchThreshold: FeatureFlags.searchSmallSizeBytes))
    }

    func testDiscoveryFindsPiJsonlSessionsOnly() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-discovery-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = temp.appendingPathComponent("agent/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let valid = sessionsDir.appendingPathComponent("valid.jsonl")
        let invalid = sessionsDir.appendingPathComponent("invalid.jsonl")
        try #"{"type":"session","version":3,"id":"pi-test","timestamp":"2026-05-12T01:02:27.657Z"}"#
            .write(to: valid, atomically: true, encoding: .utf8)
        try #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"not a header"}]}}"#
            .write(to: invalid, atomically: true, encoding: .utf8)

        let discovery = PiSessionDiscovery(customRoot: temp.path)
        XCTAssertEqual(discovery.discoverSessionFiles().map(\.lastPathComponent), ["valid.jsonl"])
    }

    func testParseFileFullUsesCurrentTreePathOnly() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let url = temp.appendingPathComponent("branched.jsonl")
        let lines = [
            #"{"type":"session","version":3,"id":"root","timestamp":"2026-05-12T01:00:00.000Z","cwd":"/tmp/as-agent-fixture/project"}"#,
            #"{"type":"message","id":"m1","parentId":"root","timestamp":"2026-05-12T01:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Start from the shared prompt."}]}}"#,
            #"{"type":"message","id":"abandoned","parentId":"m1","timestamp":"2026-05-12T01:00:02.000Z","message":{"role":"assistant","model":"abandoned-model","content":[{"type":"text","text":"abandoned branch answer"}]}}"#,
            #"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-05-12T01:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"Use the current branch."}]}}"#,
            #"{"type":"message","id":"m3","parentId":"m2","timestamp":"2026-05-12T01:00:04.000Z","message":{"role":"assistant","model":"current-model","content":[{"type":"text","text":"current branch answer"}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(PiSessionParser.parseFileFull(at: url))
        let transcriptText = session.events.compactMap(\.text).joined(separator: "\n")

        XCTAssertEqual(session.model, "current-model")
        XCTAssertEqual(session.events.filter { $0.kind != .meta }.count, 3)
        XCTAssertTrue(transcriptText.contains("current branch answer"))
        XCTAssertFalse(transcriptText.contains("abandoned branch answer"))
    }

    func testParseFileFullPreservesBashExecutionAsCommandEvent() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-bash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let url = temp.appendingPathComponent("bash.jsonl")
        let lines = [
            #"{"type":"session","version":3,"id":"bash-root","timestamp":"2026-05-12T01:00:00.000Z","cwd":"/tmp/as-agent-fixture/project"}"#,
            #"{"type":"message","id":"m1","parentId":"bash-root","timestamp":"2026-05-12T01:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Run pwd."}]}}"#,
            #"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-05-12T01:00:02.000Z","message":{"role":"bashExecution","command":"pwd","output":"/tmp/as-agent-fixture/project\n","exitCode":0}}"#
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(PiSessionParser.parseFileFull(at: url))
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.count, 1)
        XCTAssertEqual(session.lightweightCommands, 1)
        XCTAssertTrue(session.events.contains { $0.kind == .tool_call && $0.toolInput == "pwd" })
    }

    func testParseFileToleratesUnterminatedTrailingLiveRecord() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-partial-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let url = temp.appendingPathComponent("live.jsonl")
        let content = [
            #"{"type":"session","version":3,"id":"live-root","timestamp":"2026-05-12T01:00:00.000Z","cwd":"/tmp/as-agent-fixture/project"}"#,
            #"{"type":"message","id":"m1","parentId":"live-root","timestamp":"2026-05-12T01:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Keep this line."}]}}"#,
            #"{"type":"message","id":"partial","parentId":"m1","timestamp":"2026-05-12T01:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"unfinished"#
        ].joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)

        let preview = try XCTUnwrap(PiSessionParser.parseFile(at: url))
        XCTAssertEqual(preview.id, "live-root")

        let session = try XCTUnwrap(PiSessionParser.parseFileFull(at: url))
        let transcriptText = session.events.compactMap(\.text).joined(separator: "\n")

        XCTAssertEqual(session.id, "live-root")
        XCTAssertTrue(transcriptText.contains("Keep this line."))
        XCTAssertFalse(transcriptText.contains("unfinished"))
    }

    func testParseFileRejectsMalformedMiddleRecord() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-bad-middle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let url = temp.appendingPathComponent("corrupt.jsonl")
        let lines = [
            #"{"type":"session","version":3,"id":"bad-middle","timestamp":"2026-05-12T01:00:00.000Z","cwd":"/tmp/as-agent-fixture/project"}"#,
            #"{"type":"message","id":"broken","parentId":"bad-middle","timestamp":"2026-05-12T01:00:01.000Z","message":{"role":"assistant""#,
            #"{"type":"message","id":"m2","parentId":"bad-middle","timestamp":"2026-05-12T01:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"This should not be accepted."}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(PiSessionParser.parseFile(at: url))
        XCTAssertNil(PiSessionParser.parseFileFull(at: url))
    }

    private func makeSearchCandidate(id: String, source: SessionSource, fileSizeBytes: Int) -> Session {
        Session(id: id,
                source: source,
                startTime: nil,
                endTime: nil,
                model: nil,
                filePath: "/tmp/\(id).jsonl",
                fileSizeBytes: fileSizeBytes,
                eventCount: 1,
                events: [],
                cwd: "/tmp/as-agent-fixture/project",
                repoName: "project",
                lightweightTitle: "Search candidate")
    }
}
