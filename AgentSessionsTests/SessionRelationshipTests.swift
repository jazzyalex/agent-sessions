import XCTest
@testable import AgentSessions

final class SessionRelationshipTests: XCTestCase {
    func testRelationshipCopyPreservesAllSessionMetadataAndRuntimeState() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(42)
        let event = SessionEvent(
            id: "event-1",
            timestamp: start,
            kind: .tool_call,
            role: "assistant",
            text: "inspect",
            toolName: "shell",
            toolInput: "{\"command\":\"pwd\"}",
            toolOutput: nil,
            messageID: "message-1",
            parentID: nil,
            isDelta: false,
            rawJSON: "{\"type\":\"tool_call\"}"
        )
        let original = Session(
            id: "cursor-session",
            source: .cursor,
            startTime: start,
            endTime: end,
            model: "cursor-model",
            filePath: "/tmp/cursor-session.jsonl",
            fileSizeBytes: 2048,
            eventCount: 1,
            events: [event],
            cwd: "/tmp/project",
            repoName: "project",
            lightweightTitle: "Cursor task",
            lightweightCommands: 3,
            isHousekeeping: true,
            codexInternalSessionIDHint: "cursor-hint",
            parentSessionID: "old-parent",
            subagentType: "old-type",
            relationshipKind: .sideChat,
            customTitle: "Pinned title",
            codexOriginator: "cursor-agent",
            codexSource: "cursor-acp",
            codexSurface: .acp,
            originator: "Cursor ACP",
            originSource: "acp-persisted",
            surface: .acp,
            reasoningEffort: "high",
            deletedAt: end
        )
        var runtimeOriginal = original
        runtimeOriginal.isFavorite = true
        runtimeOriginal.isPartiallyHydrated = true

        let updated = runtimeOriginal.withRelationship(
            parentSessionID: "cursor-acp:new-parent",
            subagentType: "cursor-acp-subagent",
            relationshipKind: .subagent
        )

        XCTAssertEqual(updated.id, runtimeOriginal.id)
        XCTAssertEqual(updated.source, runtimeOriginal.source)
        XCTAssertEqual(updated.startTime, runtimeOriginal.startTime)
        XCTAssertEqual(updated.endTime, runtimeOriginal.endTime)
        XCTAssertEqual(updated.model, runtimeOriginal.model)
        XCTAssertEqual(updated.filePath, runtimeOriginal.filePath)
        XCTAssertEqual(updated.fileSizeBytes, runtimeOriginal.fileSizeBytes)
        XCTAssertEqual(updated.eventCount, runtimeOriginal.eventCount)
        XCTAssertEqual(updated.events, runtimeOriginal.events)
        XCTAssertEqual(updated.isHousekeeping, runtimeOriginal.isHousekeeping)
        XCTAssertEqual(updated.hasToolCallEvent, runtimeOriginal.hasToolCallEvent)
        XCTAssertEqual(updated.lightweightCommands, runtimeOriginal.lightweightCommands)
        XCTAssertEqual(updated.lightweightCwd, runtimeOriginal.lightweightCwd)
        XCTAssertEqual(updated.lightweightRepoName, runtimeOriginal.lightweightRepoName)
        XCTAssertEqual(updated.lightweightTitle, runtimeOriginal.lightweightTitle)
        XCTAssertEqual(updated.customTitle, runtimeOriginal.customTitle)
        XCTAssertEqual(updated.codexInternalSessionIDHint, runtimeOriginal.codexInternalSessionIDHint)
        XCTAssertEqual(updated.codexOriginator, runtimeOriginal.codexOriginator)
        XCTAssertEqual(updated.codexSource, runtimeOriginal.codexSource)
        XCTAssertEqual(updated.codexSurface, runtimeOriginal.codexSurface)
        XCTAssertEqual(updated.originator, runtimeOriginal.originator)
        XCTAssertEqual(updated.originSource, runtimeOriginal.originSource)
        XCTAssertEqual(updated.surface, runtimeOriginal.surface)
        XCTAssertEqual(updated.reasoningEffort, runtimeOriginal.reasoningEffort)
        XCTAssertEqual(updated.deletedAt, runtimeOriginal.deletedAt)
        XCTAssertEqual(updated.isDeleted, runtimeOriginal.isDeleted)
        XCTAssertEqual(updated.isFavorite, runtimeOriginal.isFavorite)
        XCTAssertEqual(updated.isPartiallyHydrated, runtimeOriginal.isPartiallyHydrated)

        XCTAssertEqual(updated.parentSessionID, "cursor-acp:new-parent")
        XCTAssertEqual(updated.subagentType, "cursor-acp-subagent")
        XCTAssertEqual(updated.relationshipKind, .subagent)
    }
}
