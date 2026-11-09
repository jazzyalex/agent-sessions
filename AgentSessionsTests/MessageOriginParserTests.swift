import XCTest
@testable import AgentSessions

final class MessageOriginParserTests: XCTestCase {
    private func codex(_ text: [Any], kinds: Any? = nil, role: String = "user", type: String = "message", envelope: String = "response_item") throws -> SessionEvent {
        var payload: [String: Any] = ["type": type, "role": role, "content": text, "author": "/root/helper"]
        if type == "agent_message" { payload.removeValue(forKey: "role") }
        if let kinds { payload["internal_chat_message_metadata_passthrough"] = ["content_item_kinds": kinds] }
        let data = try JSONSerialization.data(withJSONObject: ["type": envelope, "payload": payload])
        return SessionIndexer.parseLine(String(decoding: data, as: UTF8.self), eventID: UUID().uuidString).0
    }
    private func text(_ value: String) -> [String: String] { ["type": "input_text", "text": value] }
    private func session(_ events: [SessionEvent]) -> Session {
        Session(id: UUID().uuidString, source: .codex, startTime: nil, endTime: nil, model: "test", filePath: "/tmp/origin.jsonl", fileSizeBytes: nil, eventCount: events.count, events: events)
    }
    private func claude(_ extra: [String: Any], content: Any = "hello") throws -> [SessionEvent] {
        var record = extra
        record["type"] = "user"; record["sessionId"] = "origin-test"; record["uuid"] = UUID().uuidString
        record["message"] = ["role": "user", "content": content]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("origin-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: url)
        return try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url)).events
    }
    // Review fix 1: the real record shape — origin.kind coordinator plus isMeta.
    func testClaudeCoordinatorRecordIsPeer() throws {
        let events = try claude(["origin": ["kind": "coordinator"], "isMeta": true],
                                content: "The coordinator sent a message while you were working:\nStop.")
        XCTAssertEqual(events.first?.messageOrigin, .peer(from: "coordinator"))
    }
    func testCodexTypedUserText() throws {
        let event = try codex([text("hi")], kinds: ["user.text | x"])
        XCTAssertEqual(event.kind, .user); XCTAssertEqual(event.messageOrigin, .typed); XCTAssertEqual(event.text, "hi")
    }
    func testCodexOpenPageIsContext() throws {
        XCTAssertEqual(try codex([text("page")], kinds: ["additional_content.codex_apps_open_page | x"]).messageOrigin, .context(kinds: ["additional_content.codex_apps_open_page"]))
    }
    func testCodexMixedKeepsOnlyTypedParts() throws {
        let event = try codex([text("instructions"), text("do it")], kinds: ["agents_md.instructions", "user.text"])
        XCTAssertEqual(event.text, "instructionsdo it"); XCTAssertEqual(event.messageOrigin, .typed); XCTAssertEqual(event.messageDisplayText, "do it")
        var bare = event; bare.messageOrigin = nil; bare.messageDisplayText = nil; bare.messageHasEncryptedContent = nil
        let original = session([bare]), annotated = session([event])
        XCTAssertEqual(SessionSearchTextBuilder.build(session: original), SessionSearchTextBuilder.build(session: annotated))
        XCTAssertEqual(SessionTranscriptBuilder.buildPlainTerminalTranscript(session: original, filters: .current(showTimestamps: false, showMeta: true)), SessionTranscriptBuilder.buildPlainTerminalTranscript(session: annotated, filters: .current(showTimestamps: false, showMeta: true)))
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: annotated, includeMeta: false).first?.text, event.text)
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: annotated, includeMeta: false, includeMessageContext: true).first?.messageDisplayText, "do it")
    }
    func testCodexMixedAlignmentIncludesNonText() throws {
        let event = try codex([text("context"), ["type": "input_image"], text("yes")], kinds: ["context", "user.text", "user.text"])
        XCTAssertEqual(event.messageOrigin, .typed); XCTAssertEqual(event.messageDisplayText, "yes")
        let hidden = MessageOrigin.context(kinds: ["codex.mixed.unresolved"])
        XCTAssertEqual(try codex([text("context"), text("yes")], kinds: ["context", "user.text", "user.text"]).messageOrigin, hidden)
        XCTAssertEqual(try codex([text("context")], kinds: []).messageOrigin, hidden)
        XCTAssertEqual(try codex([text("context")], kinds: ["user.text", 3]).messageOrigin, hidden)
    }
    func testCodexEnvironmentProjection() throws {
        let value = "<environment_context>workspace</environment_context>"
        for kinds: [String]? in [nil, ["user.text"]] {
            let event = try codex([text(value)], kinds: kinds)
            XCTAssertEqual(event.kind, .meta); XCTAssertEqual(event.text, value)
            XCTAssertEqual(event.messageOrigin, kinds == nil ? .context(kinds: ["environment_context"]) : .typed)
            let model = session([event])
            XCTAssertTrue(SessionTranscriptBuilder.coalescedBlocks(for: model, includeMeta: false).isEmpty)
            XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: model, includeMeta: false, includeMessageContext: true).count, 1)
        }
    }
    // Integrated review 2026-11-09: environment context plus a typed prompt in one message must
    // stay a user event, so Terminal and the Codex title fallback still see the prompt.
    func testCodexMixedEnvironmentAndPromptStaysUser() throws {
        let context = "<environment_context>workspace</environment_context>"
        let event = try codex([text(context), text("Fix login redirect")],
                              kinds: ["environments.environment_context", "user.text"])
        XCTAssertEqual(event.kind, .user)
        XCTAssertEqual(event.messageOrigin, .typed)
        // Review 2026-11-09 (Codex): the event is the prompt alone, so no text consumer shows the
        // injected block as something the user typed. rawJSON keeps the original items.
        XCTAssertEqual(event.text, "Fix login redirect")
        XCTAssertTrue(event.rawJSON.contains("environment_context"))
        let model = session([event])
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: model, includeMeta: false).count, 1)
        let terminal = SessionTranscriptBuilder.buildPlainTerminalTranscript(
            session: model, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(terminal.contains("Fix login redirect"))
        XCTAssertFalse(terminal.contains("environment_context"))
        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: model), "Fix login redirect")
        XCTAssertFalse(Session.computeIsHousekeeping(source: .codex, events: [event]))
    }
    func testCodexTypedPromptThatNamesTheTagStaysUser() throws {
        let typed = "What is <environment_context>?"
        let event = try codex([text("<environment_context>w</environment_context>"), text(typed)],
                              kinds: ["environments.environment_context", "user.text"])
        XCTAssertEqual(event.kind, .user)
        XCTAssertEqual(event.text, typed)
    }
    func testCodexMixedPreambleCountsByTypedItems() throws {
        let preamble = (["# AGENTS.md instructions for /repo"] + (1...6).map { "- rule \($0)" }).joined(separator: "\n")
        let event = try codex([text(preamble), text("Ship the fix")], kinds: ["agents_md.instructions", "user.text"])
        XCTAssertFalse(Session.computeIsHousekeeping(source: .codex, events: [event]))
        XCTAssertEqual(SessionInfoMetadataSanitizer.rowTitle(for: session([event])), "Ship the fix")
    }
    func testInjectedTurnAbortedTagIsNotSplitOut() throws {
        let injected = "<turn_aborted>injected reason</turn_aborted>"
        let event = try codex([text(injected), text("Continue")], kinds: ["agents_md.instructions", "user.text"])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session([event]), includeMeta: true,
                                                              includeMessageContext: true)
        XCTAssertFalse(blocks.contains { $0.kind == .meta })
        XCTAssertEqual(blocks.first?.messageDisplayText, "Continue")
    }
    func testCodexAgentMessageIsPeer() throws {
        let header = "Message Type: MESSAGE\nSender: /root/helper\nPayload:\n"
        let event = try codex([text(header), ["type": "encrypted_content", "encrypted_content": "gAAAAA"]], type: "agent_message")
        XCTAssertEqual(event.kind, .meta); XCTAssertEqual(event.text, header); XCTAssertEqual(event.messageOrigin, .peer(from: "helper"))
        XCTAssertEqual(event.messageHasEncryptedContent, true); XCTAssertEqual(event.messageDisplayText, "")
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: session([event]), includeMeta: false, includeMessageContext: true).first?.messageHasEncryptedContent, true)
    }
    func testCodexEventMsgAgentMessageStaysMeta() throws {
        let event = try codex([text("mirror")], type: "agent_message", envelope: "event_msg")
        XCTAssertEqual(event.kind, .meta); XCTAssertNil(event.messageOrigin)
    }
    func testCodexNoKindsLeavesOriginNil() throws {
        XCTAssertNil(try codex([text("hello")]).messageOrigin)
        let developer = try codex([text("instructions")], kinds: ["user.text"], role: "developer")
        XCTAssertEqual(developer.kind, .meta); XCTAssertNil(developer.messageOrigin)
    }
    func testClaudeCompaction() throws { XCTAssertEqual(try claude(["isCompactSummary": true]).first?.messageOrigin, .compaction) }
    func testClaudeTaskNotification() throws { XCTAssertEqual(try claude(["origin": ["kind": "task-notification"]]).first?.messageOrigin, .notification(kind: "task")) }
    func testClaudePeer() throws { XCTAssertEqual(try claude(["origin": ["kind": "peer", "from": "opaque"]]).first?.messageOrigin, .peer(from: "another session")) }
    func testClaudeSkill() throws { XCTAssertEqual(try claude(["isMeta": true], content: "Base directory for this skill: /skills/review\nbody").first?.messageOrigin, .skill(name: "review")) }
    func testClaudeMeta() throws { XCTAssertEqual(try claude(["isMeta": true]).first?.messageOrigin, .context(kinds: ["claude.meta"])) }
    func testClaudeHuman() throws { XCTAssertEqual(try claude(["origin": ["kind": "human"]]).first?.messageOrigin, .typed) }
    func testClaudeUnknownOriginIsContext() throws { XCTAssertEqual(try claude(["origin": ["kind": "automation"]]).first?.messageOrigin, .context(kinds: ["claude.origin.automation"])) }
    func testClaudeNoFields() throws { XCTAssertNil(try claude([:]).first?.messageOrigin) }
    func testClaudeToolResultHasNoOrigin() throws {
        let events = try claude(["origin": ["kind": "human"]], content: [["type": "text", "text": "before"], ["type": "tool_result", "tool_use_id": "call", "content": "output"], ["type": "text", "text": "after"]])
        XCTAssertEqual(events.filter { $0.kind == .user }.map(\.messageOrigin), [.typed, .typed])
        XCTAssertNil(try XCTUnwrap(events.first { $0.kind == .tool_result }).messageOrigin)
    }
}
