import XCTest
@testable import AgentSessions

/// Side chats used to be stamped "Codex Desktop" unconditionally. The grouping
/// and cwd heuristics that read that stamp now key off the path sentinel
/// instead, so a side chat with no surface at all keeps its project.
final class CodexSideChatProvenanceTests: XCTestCase {
    private func sideChat(surface: CodexSessionSurface? = nil,
                          originator: String? = nil,
                          cwd: String?) -> Session {
        Session(
            id: "codex-side-chat-abc",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: CodexSideChatLogReader.sideChatSessionPath(threadID: "abc"),
            fileSizeBytes: 1,
            eventCount: 1,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil,
            relationshipKind: .sideChat,
            codexOriginator: originator,
            codexSurface: surface
        )
    }

    func testSideChatIsIdentifiedByPathNotByRelationshipKind() {
        let viaPath = sideChat(cwd: nil)
        XCTAssertTrue(viaPath.isCodexSideChatSession)

        // A hydrated session keeps its path but loses relationshipKind, because
        // session_meta has no column for it. The predicate must survive that.
        let hydrated = Session(
            id: "codex-side-chat-abc",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: CodexSideChatLogReader.sideChatSessionPath(threadID: "abc"),
            fileSizeBytes: 1,
            eventCount: 1,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil
        )
        XCTAssertFalse(hydrated.isSideChat, "precondition: relationship kind does not survive hydration")
        XCTAssertTrue(hydrated.isCodexSideChatSession)
    }

    func testDesktopChatsGroupingSurvivesASideChatWithNoSurface() {
        let generatedWorkspace = "/Users/test/Documents/Codex/2026-08-18/some-chat"
        let withoutSurface = sideChat(cwd: generatedWorkspace)

        XCTAssertFalse(withoutSurface.isCodexDesktopSession,
                       "precondition: nothing stamps a Desktop surface any more")
        XCTAssertEqual(CodexDesktopProjectClassifier.projectNameOverride(for: withoutSurface),
                       CodexDesktopProjectClassifier.chatsProjectName)
    }

    func testAnOrdinarySideChatGetsNoDesktopProjectOverride() {
        XCTAssertNil(CodexDesktopProjectClassifier.projectNameOverride(
            for: sideChat(cwd: "/Users/test/Repository/thing")))
    }
}
