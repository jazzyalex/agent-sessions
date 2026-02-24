import XCTest
@testable import AgentSessions

final class TranscriptGoldenFixtureTests: XCTestCase {
    func testPlanFixtureSemanticSnapshot() throws {
        let text = try loadFixture("plan_block.txt")
        let lines = buildAssistantLines(text: text)

        XCTAssertFalse(lines.contains(where: { $0.text.contains("<proposed_plan>") }))

        let snapshots = semanticSnapshots(from: lines)
        XCTAssertEqual(snapshots, ["plan|assistant|# Execution Plan|## Foundation"])
    }

    func testCodeFenceFixtureSemanticSnapshot() throws {
        let text = try loadFixture("code_fences.txt")
        let lines = buildAssistantLines(text: text)

        let snapshots = semanticSnapshots(from: lines)
        XCTAssertEqual(snapshots, [
            "code|assistant|Code (swift)|print(\"hello\")",
            "code|assistant|Code (bash)|echo \"world\"",
            "code|assistant|Code (json)|{\"ok\": true}"
        ])
    }

    func testUnifiedDiffFixtureSemanticSnapshot() throws {
        let text = try loadFixture("unified_diff.txt")
        let lines = buildAssistantLines(text: text)

        let snapshots = semanticSnapshots(from: lines)
        XCTAssertEqual(snapshots, ["diff|assistant|Diff|diff --git a/App.swift b/App.swift"])
    }

    func testReviewFixtureSemanticSnapshot() throws {
        let text = try loadFixture("review_payload.json")
        let lines = buildAssistantLines(text: text)

        let snapshots = semanticSnapshots(from: lines)
        XCTAssertEqual(snapshots, ["reviewSummary|assistant|Review|Correctness: correct"])
    }

    func testFileReferenceFixtureLinkificationPatterns() throws {
        let text = try loadFixture("file_refs.txt")
        let matches = TranscriptLinkifier.matches(in: text)
        let nsText = text as NSString

        XCTAssertGreaterThanOrEqual(matches.count, 5)
        XCTAssertTrue(matches.contains(where: { $0.path == "Foo.swift" && $0.line == 56 && $0.column == nil }))
        XCTAssertTrue(matches.contains(where: { $0.path == "path/to/Foo.swift" && $0.line == 56 && $0.column == nil }))
        XCTAssertTrue(matches.contains(where: { $0.path == "path/to/Foo.swift" && $0.line == 56 && $0.column == 12 }))
        let hashLinkMatch = try XCTUnwrap(matches.first(where: { match in
            guard match.path == "Foo.swift", match.line == 56, match.column == nil else { return false }
            let suffixStart = match.range.location + match.range.length
            guard suffixStart < nsText.length else { return false }
            let suffixLength = min(8, nsText.length - suffixStart)
            let suffix = nsText.substring(with: NSRange(location: suffixStart, length: suffixLength))
            return suffix == "#L56-L80"
        }))
        XCTAssertEqual(nsText.substring(with: hashLinkMatch.range), "Foo.swift")
    }

    private func buildAssistantLines(text: String) -> [TerminalLine] {
        let session = Session(id: "fixture-session",
                              source: .codex,
                              startTime: nil,
                              endTime: nil,
                              model: "gpt-5",
                              filePath: "/tmp/fixture-session.jsonl",
                              fileSizeBytes: nil,
                              eventCount: 1,
                              events: [SessionEvent(id: "evt-1",
                                                    timestamp: nil,
                                                    kind: .assistant,
                                                    role: "assistant",
                                                    text: text,
                                                    toolName: nil,
                                                    toolInput: nil,
                                                    toolOutput: nil,
                                                    messageID: "msg-1",
                                                    parentID: nil,
                                                    isDelta: false,
                                                    rawJSON: "{}")])
        return TerminalBuilder.buildLines(for: session, showMeta: false)
    }

    private func semanticSnapshots(from lines: [TerminalLine]) -> [String] {
        var snapshots: [String] = []
        var currentGroup: Int? = nil
        var currentSemantic: SemanticKind? = nil
        var currentRole: TerminalLineRole? = nil
        var currentLines: [String] = []

        func flush() {
            guard let semantic = currentSemantic,
                  let role = currentRole,
                  !currentLines.isEmpty else {
                currentLines = []
                return
            }
            let first = currentLines.first ?? ""
            let second = currentLines.dropFirst().first ?? ""
            snapshots.append("\(semantic)|\(role)|\(first)|\(second)")
            currentLines = []
        }

        for line in lines {
            if line.decorationGroupID != currentGroup {
                flush()
                currentGroup = line.decorationGroupID
                currentSemantic = line.semanticKind
                currentRole = line.role
            }
            if line.semanticKind != nil {
                currentLines.append(line.text)
            }
        }
        flush()

        return snapshots
    }

    private func loadFixture(_ name: String, file: StaticString = #filePath) throws -> String {
        let url = FixturePaths.repoRootURL(file: file)
            .appendingPathComponent("AgentSessionsTests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
