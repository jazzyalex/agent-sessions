import XCTest
@testable import AgentSessions

final class SessionTitleTests: XCTestCase {
    private func event(id: String, kind: SessionEventKind, text: String? = nil, tool: String? = nil) -> SessionEvent {
        SessionEvent(
            id: id,
            timestamp: nil,
            kind: kind,
            role: nil,
            text: text,
            toolName: tool,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
    }

    func testTitlePrefersUserLine() {
        let s = Session(
            id: "s-title-1",
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/tmp/a.jsonl",
            eventCount: 2,
            events: [
                event(id: "e1", kind: .user, text: "   Find   files  \n  now  "),
                event(id: "e2", kind: .assistant, text: "okay")
            ]
        )
        XCTAssertEqual(s.title, "Find files now")
    }

    func testTitleFallsBackToAssistant() {
        let s = Session(
            id: "s-title-2",
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/tmp/b.jsonl",
            eventCount: 2,
            events: [
                event(id: "e1", kind: .user, text: "    \n  \t  "),
                event(id: "e2", kind: .assistant, text: "Hello there")
            ]
        )
        XCTAssertEqual(s.title, "Hello there")
    }

    func testTitleNoPromptWhenEmpty() {
        let s = Session(
            id: "s-title-3",
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/tmp/c.jsonl",
            eventCount: 1,
            events: [
                event(id: "e1", kind: .meta, text: nil)
            ]
        )
        XCTAssertEqual(s.title, "No prompt")
    }

    func testListTitleIgnoresLaterUserAfterBlankFirstUser() {
        let s = Session(
            id: "s-list-title-blank-user",
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/tmp/list-title-blank-user.jsonl",
            eventCount: 3,
            events: [
                event(id: "e1", kind: .user, text: "   \n   "),
                event(id: "e2", kind: .assistant, text: "assistant fallback"),
                event(id: "e3", kind: .user, text: "later user")
            ]
        )
        XCTAssertEqual(s.listTitle, "assistant fallback")
    }

    func testListTitleIgnoresLaterAssistantAfterBlankFirstAssistant() {
        let s = Session(
            id: "s-list-title-blank-assistant",
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/tmp/list-title-blank-assistant.jsonl",
            eventCount: 3,
            events: [
                event(id: "e1", kind: .assistant, text: "  \n  "),
                event(id: "e2", kind: .assistant, text: "later assistant"),
                event(id: "e3", kind: .tool_call, tool: "shell")
            ]
        )
        XCTAssertEqual(s.listTitle, "shell")
    }

    func testMessageCountUsesEstimateWhenEventsAreEmpty() {
        let s = Session(
            id: "s-message-count-estimate",
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/tmp/message-count-estimate.jsonl",
            eventCount: 4,
            events: []
        )
        XCTAssertEqual(s.messageCount, 4)
    }

    func testMessageCountSkipsMetaEventsWithoutDroppingEstimate() {
        let s = Session(
            id: "s-message-count-non-meta",
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/tmp/message-count-non-meta.jsonl",
            eventCount: 5,
            events: [
                event(id: "e1", kind: .meta),
                event(id: "e2", kind: .user, text: "hello"),
                event(id: "e3", kind: .assistant, text: "hi")
            ]
        )
        XCTAssertEqual(s.nonMetaCount, 2)
        XCTAssertEqual(s.messageCount, 5)
    }
}
