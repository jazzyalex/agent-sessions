import XCTest
@testable import AgentSessions

final class CursorACPSubagentAssociationTests: XCTestCase {
    private let parentUUID = "11111111-1111-1111-1111-111111111111"
    private let childUUID = "22222222-2222-2222-2222-222222222222"

    func testUniqueExplicitReferenceLinksChildAndKeepsParentSeparate() {
        let childPath = "/tmp/projects/agent-transcripts/\(parentUUID)/subagents/\(childUUID).jsonl"
        let child = session(id: "child", path: childPath)
        let parent = session(id: "cursor-acp:\(parentUUID)", path: "/tmp/acp-sessions/\(parentUUID)/store.db", surface: .acp)
        let result = CursorACPParseResult(session: parent, referencedTranscriptPaths: [childPath])

        let linked = CursorACPSubagentAssociation.apply(sessions: [child, parent], acpResults: [result])
        let linkedChild = try! XCTUnwrap(linked.first { $0.id == "child" })
        XCTAssertEqual(linkedChild.parentSessionID, "cursor-acp:\(parentUUID)")
        XCTAssertEqual(linkedChild.subagentType, CursorACPSubagentAssociation.subagentType)
        XCTAssertEqual(linkedChild.relationshipKind, .subagent)
        XCTAssertEqual(linked.filter { $0.id == parent.id }.count, 1)
    }

    func testDuplicateSameParentReferencesDeduplicate() {
        let childPath = "/tmp/projects/agent-transcripts/\(parentUUID)/subagents/\(childUUID).jsonl"
        let child = session(id: "child", path: childPath)
        let parent = session(id: "cursor-acp:\(parentUUID)", path: "/tmp/acp/parent.db", surface: .acp)
        let first = CursorACPParseResult(session: parent, referencedTranscriptPaths: [childPath])
        let second = CursorACPParseResult(session: parent, referencedTranscriptPaths: [childPath])

        let linked = CursorACPSubagentAssociation.apply(sessions: [child], acpResults: [first, second])
        XCTAssertEqual(linked[0].parentSessionID, "cursor-acp:\(parentUUID)")
    }

    func testConflictingParentsRemainUnresolved() {
        let childPath = "/tmp/projects/agent-transcripts/\(parentUUID)/subagents/\(childUUID).jsonl"
        let child = session(id: "child", path: childPath)
        let first = CursorACPParseResult(
            session: session(id: "cursor-acp:\(parentUUID)", path: "/tmp/acp/one.db", surface: .acp),
            referencedTranscriptPaths: [childPath]
        )
        let secondParent = "33333333-3333-3333-3333-333333333333"
        let second = CursorACPParseResult(
            session: session(id: "cursor-acp:\(secondParent)", path: "/tmp/acp/two.db", surface: .acp),
            referencedTranscriptPaths: [childPath]
        )

        let unresolved = CursorACPSubagentAssociation.apply(sessions: [child], acpResults: [first, second])
        XCTAssertNil(unresolved[0].parentSessionID)
    }

    func testRawPathParentUpgradesOnlyForSoleCandidate() {
        let childPath = "/tmp/projects/agent-transcripts/\(parentUUID)/subagents/\(childUUID).jsonl"
        let child = session(id: "child", path: childPath, parent: parentUUID, type: "subagent")
        let parent = session(id: "cursor-acp:\(parentUUID)", path: "/tmp/acp/one.db", surface: .acp)
        let result = CursorACPParseResult(session: parent, referencedTranscriptPaths: [childPath])

        let linked = CursorACPSubagentAssociation.apply(sessions: [child], acpResults: [result])
        XCTAssertEqual(linked[0].parentSessionID, "cursor-acp:\(parentUUID)")
    }

    func testRelativePathIsNotAssociated() {
        let child = session(id: "child", path: "agent-transcripts/\(parentUUID)/subagents/\(childUUID).jsonl")
        let parent = session(id: "cursor-acp:\(parentUUID)", path: "/tmp/acp/one.db", surface: .acp)
        let result = CursorACPParseResult(session: parent, referencedTranscriptPaths: ["/tmp/projects/agent-transcripts/\(parentUUID)/subagents/\(childUUID).jsonl"])

        XCTAssertNil(CursorACPSubagentAssociation.apply(sessions: [child], acpResults: [result])[0].parentSessionID)
    }

    private func session(
        id: String,
        path: String,
        surface: SessionSurface? = nil,
        parent: String? = nil,
        type: String? = nil
    ) -> Session {
        Session(
            id: id,
            source: .cursor,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: path,
            eventCount: 0,
            events: [],
            parentSessionID: parent,
            subagentType: type,
            surface: surface
        )
    }
}
