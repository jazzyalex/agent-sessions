import XCTest
@testable import AgentSessions

final class InlineSessionImageMappingTests: XCTestCase {
    private func makeEvent(id: String, kind: SessionEventKind, text: String? = nil, rawJSON: String) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: nil,
                     kind: kind,
                     role: nil,
                     text: text,
                     toolName: nil,
                     toolInput: nil,
                     toolOutput: nil,
                     messageID: nil,
                     parentID: nil,
                     isDelta: false,
                     rawJSON: rawJSON)
    }

    private func userPromptIndexForLineIndex(session: Session, lineIndex: Int) -> Int? {
        guard lineIndex >= 0 else { return nil }
        var userIndex: Int? = nil
        var seenUsers = 0
        for (idx, event) in session.events.enumerated() {
            if event.kind == .user {
                if idx <= lineIndex {
                    userIndex = seenUsers
                } else if userIndex == nil {
                    userIndex = seenUsers
                }
                seenUsers += 1
            }
            if idx > lineIndex, userIndex != nil { break }
        }
        return userIndex
    }

    private func writeTempJSONL(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InlineSessionImageMappingTests-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        guard let data = text.data(using: .utf8) else {
            XCTFail("Failed to encode test fixture as UTF-8")
            return url
        }
        try data.write(to: url)
        return url
    }

    func testImageSpanInToolResultMapsToMostRecentUserPrompt() throws {
        let jsonl = """
        {"type":"user","text":"make a screenshot"}
        {"type":"tool_result","output":"data:image/png;base64,QUJDRA=="}
        {"type":"assistant","text":"here you go"}
        {"type":"user","text":"next task data:image/png;base64,QUJDRA=="}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let events: [SessionEvent] = [
            makeEvent(id: "e0", kind: .user, text: "make a screenshot", rawJSON: #"{"type":"user"}"#),
            makeEvent(id: "e1", kind: .tool_result, text: nil, rawJSON: #"{"type":"tool_result"}"#),
            makeEvent(id: "e2", kind: .assistant, text: "here you go", rawJSON: #"{"type":"assistant"}"#),
            makeEvent(id: "e3", kind: .user, text: "next task", rawJSON: #"{"type":"user"}"#)
        ]
        let session = Session(id: "s1",
                              source: .codex,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: url.path,
                              eventCount: events.count,
                              events: events)

        let located = try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.count, 2)

        let mapped = located.map { item -> (Int, Int?) in
            (item.lineIndex, userPromptIndexForLineIndex(session: session, lineIndex: item.lineIndex))
        }
        .sorted(by: { $0.0 < $1.0 })

        XCTAssertEqual(mapped.map(\.0), [1, 3])
        XCTAssertEqual(mapped.map(\.1), [0, 1])
    }

    func testNoUserEventsReturnsNil() {
        let session = Session(id: "s2",
                              source: .codex,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: "/tmp/none.jsonl",
                              eventCount: 2,
                              events: [
                                makeEvent(id: "e0", kind: .assistant, text: "hi", rawJSON: "{}"),
                                makeEvent(id: "e1", kind: .tool_result, text: nil, rawJSON: "{}")
                              ])
        XCTAssertNil(userPromptIndexForLineIndex(session: session, lineIndex: 0))
        XCTAssertNil(userPromptIndexForLineIndex(session: session, lineIndex: 10))
    }

    func testCodexInlineImageMarkersRenderAsBracketedToken() {
        let events: [SessionEvent] = [
            makeEvent(id: "e0",
                      kind: .user,
                      text: "<image name=[Image #1]></image>[Image #1] hello",
                      rawJSON: #"{"type":"user"}"#)
        ]
        let session = Session(id: "s3",
                              source: .codex,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: "/tmp/none.jsonl",
                              eventCount: events.count,
                              events: events)

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session,
                                                                        filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("[Image #1]"))
        XCTAssertFalse(txt.contains("<image"))
        XCTAssertFalse(txt.contains("</image>"))
    }
}
