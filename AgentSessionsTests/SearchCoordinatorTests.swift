import XCTest
@testable import AgentSessions

final class SearchCoordinatorTests: XCTestCase {
    func testFTSEligibleSources_excludesSourcesWithoutFTSIndex() {
        XCTAssertEqual(
            SearchCoordinator.ftsEligibleSources(from: [.cursor, .codebuddy, .workbuddy]),
            []
        )

        XCTAssertEqual(
            SearchCoordinator.ftsEligibleSources(from: [.codex, .codebuddy, .workbuddy]),
            [.codex]
        )
    }

    func testSearchCoordinatorFindsLightweightCodeBuddyTranscriptThroughFallback() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-search-\(UUID().uuidString).jsonl")
        try """
        {"type":"message","sessionId":"buddy-search","timestamp":1777651201000,"cwd":"/tmp/as-buddy-fixture/project","role":"user","content":"UniqueBuddySearchToken"}
        {"type":"message","sessionId":"buddy-search","timestamp":1777651202000,"cwd":"/tmp/as-buddy-fixture/project","role":"assistant","content":"Done."}
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let preview = CodebuddySessionParser.parseFile(at: url, forcedID: "buddy-search") else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertTrue(preview.events.isEmpty)

        let coordinator = SearchCoordinator(store: BuddySearchStore())
        let filters = Filters(
            query: "UniqueBuddySearchToken",
            dateFrom: nil,
            dateTo: nil,
            model: nil,
            kinds: Set(SessionEventKind.allCases),
            repoName: nil,
            pathContains: nil
        )
        coordinator.start(
            query: filters.query,
            filters: filters,
            includeCodex: false,
            includeClaude: false,
            includeGemini: false,
            includeOpenCode: false,
            includeHermes: false,
            includeCopilot: false,
            includeDroid: false,
            includeOpenClaw: false,
            includeCursor: false,
            includeCodebuddy: true,
            includeWorkbuddy: false,
            enableDeepScan: false,
            all: [preview]
        )

        for _ in 0..<60 {
            if coordinator.results.contains(where: { $0.id == "buddy-search" }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(coordinator.results.map(\.id), ["buddy-search"])
    }
}

private final class BuddySearchStore: SearchSessionStoring {
    private let codebuddyCache = TranscriptCache()
    private let workbuddyCache = TranscriptCache()

    func transcriptCache(for source: SessionSource) -> TranscriptCache? {
        switch source {
        case .codebuddy: return codebuddyCache
        case .workbuddy: return workbuddyCache
        default: return nil
        }
    }

    func updateSession(_ session: Session) {}

    func parseFull(session: Session) async -> Session? {
        guard session.events.isEmpty else { return session }
        let url = URL(fileURLWithPath: session.filePath)
        switch session.source {
        case .codebuddy:
            return CodebuddySessionParser.parseFileFull(at: url, forcedID: session.id)
        case .workbuddy:
            return WorkbuddySessionParser.parseFileFull(at: url, forcedID: session.id)
        default:
            return session
        }
    }
}
