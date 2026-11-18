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

    func testCodexRowTitleSkipsContextAndUsesLoadedRequest() {
        let context = "# AGENTS.md instructions for /tmp/project\n<INSTRUCTIONS>Rules only</INSTRUCTIONS>"
        let request = "Investigate the session title regression"
        let s = Session(
            id: "context-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/context.jsonl", eventCount: 2,
            events: [
                event(id: "context", kind: .user, text: context),
                event(id: "request", kind: .user, text: request)
            ],
            cwd: nil, repoName: nil,
            lightweightTitle: "<external_codex_apps_open_page>{\"page_id\":null}</external_codex_apps_open_page>")

        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: s), request)
        XCTAssertEqual(s.events[0].text, context)
        XCTAssertEqual(s.events[1].text, request)
    }

    func testCodexRowTitleFallsBackFromUnsafeCustomTitleToMetadata() {
        let s = Session(
            id: "unsafe-custom-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/custom.jsonl", eventCount: 0, events: [],
            cwd: nil, repoName: nil, lightweightTitle: "Review sign-in recovery",
            customTitle: "<unknown>Raw metadata</unknown>")

        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: s), "Review sign-in recovery")
    }

    func testCodexRowTitleKeepsInstructionHeadingSeparateFromRequestWithoutMetadata() {
        let s = Session(
            id: "raw-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/raw.jsonl", eventCount: 2,
            events: [
                event(id: "rules", kind: .user, text: "# Instructions\nFollow the runbook."),
                event(id: "request", kind: .user, text: "Review the session title parser")
            ])

        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: s), "Review the session title parser")
    }

    func testCodexInstructionOnlyRowWithoutMetadataDoesNotShowRules() {
        let s = Session(
            id: "rules-only-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/rules.jsonl", eventCount: 1,
            events: [event(id: "rules", kind: .user, text: "# Instructions\nFollow the runbook.")])

        XCTAssertNil(SessionInfoMetadataSanitizer.rowTitle(for: s))
    }

    func testCodexRowTitlePrefersLaterRequestAfterBlankUserToAssistantFallback() {
        let s = Session(
            id: "blank-user-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/blank.jsonl", eventCount: 3,
            events: [
                event(id: "blank", kind: .user, text: " \n "),
                event(id: "assistant", kind: .assistant, text: "Assistant fallback"),
                event(id: "request", kind: .user, text: "Review the session title parser")
            ])

        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: s), "Review the session title parser")
    }

    func testCodexRowTitleRetainsAssistantAndToolFallbackAfterContextOnlyUser() {
        let context = event(id: "rules", kind: .user, text: "# Instructions\nFollow the runbook.")
        let assistant = Session(
            id: "assistant-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/assistant.jsonl", eventCount: 2,
            events: [context, event(id: "assistant", kind: .assistant, text: "Checking the title parser")])
        let tool = Session(
            id: "tool-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/tool.jsonl", eventCount: 2,
            events: [context, event(id: "tool", kind: .tool_call, tool: "exec")])

        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: assistant), "Checking the title parser")
        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: tool), "exec")
    }

    func testCodexRowTitlePreservesCustomAndOverridePriority() {
        let s = Session(
            id: "renamed-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/renamed.jsonl", eventCount: 0, events: [],
            cwd: nil, repoName: nil, lightweightTitle: "Original prompt",
            customTitle: "Named investigation")

        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: s), "Named investigation")
        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: s, override: "Provider title"), "Provider title")
        XCTAssertEqual(s.customTitle, "Named investigation")
    }

    func testCodexColdRowWithLongPromptHasReadableTitle() {
        let prompt = "Investigate missing tournament dates " + String(repeating: "details ", count: 10_000)
        let s = Session(
            id: "cold-title", source: .codex, startTime: nil, endTime: nil,
            model: nil, filePath: "/tmp/cold.jsonl", eventCount: 56, events: [],
            cwd: nil, repoName: nil, lightweightTitle: prompt)

        let title = SessionInfoMetadataSanitizer.rowTitle(for: s)
        XCTAssertTrue(title?.hasPrefix("Investigate missing tournament dates") == true)
        XCTAssertEqual(title?.count, 400)
        XCTAssertEqual(s.lightweightTitle, prompt)
        XCTAssertTrue(s.events.isEmpty)
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
