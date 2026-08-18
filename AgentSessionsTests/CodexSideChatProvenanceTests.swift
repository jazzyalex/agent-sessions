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
    // MARK: - Reading the parent rollout

    /// Builds a throwaway CODEX_HOME containing one rollout.
    private func makeCodexHome(threadID: String, header: [String: Any]) throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-home-\(UUID().uuidString)", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/06/06", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let rollout = day.appendingPathComponent("rollout-2026-06-06T10-13-10-\(threadID).jsonl")
        var body = try String(data: JSONSerialization.data(withJSONObject: ["payload": header]), encoding: .utf8)!
        body += "\n{\"payload\":{\"type\":\"message\"}}\n"
        try body.write(to: rollout, atomically: true, encoding: .utf8)
        return home
    }

    /// The point of the whole change: a side chat forked from a CLI thread must
    /// come out CLI, not the "Codex Desktop" the log database claims.
    func testProvenanceComesFromTheParentRollout() throws {
        let threadID = "019e9dec-9fc5-7532-9678-fed23d8ed607"
        let home = try makeCodexHome(threadID: threadID,
                                     header: ["originator": "Codex Desktop", "source": "cli"])

        let index = CodexSideChatLogReader.rolloutIndex(codexHome: home)
        XCTAssertEqual(index[threadID]?.lastPathComponent.contains(threadID), true)

        let provenance = CodexSideChatLogReader.parentProvenance(parentThreadID: threadID,
                                                                 rolloutIndex: index)
        XCTAssertEqual(provenance?.surface, .cli)
        XCTAssertEqual(provenance?.originator, "Codex Desktop")
    }

    func testProvenanceIsAbsentWhenTheParentHasNoRollout() throws {
        let home = try makeCodexHome(threadID: "019e9dec-9fc5-7532-9678-fed23d8ed607",
                                     header: ["originator": "Codex Desktop", "source": "cli"])
        let index = CodexSideChatLogReader.rolloutIndex(codexHome: home)

        XCTAssertNil(CodexSideChatLogReader.parentProvenance(parentThreadID: "no-such-thread",
                                                             rolloutIndex: index))
        XCTAssertNil(CodexSideChatLogReader.parentProvenance(parentThreadID: nil, rolloutIndex: index))
    }

}
