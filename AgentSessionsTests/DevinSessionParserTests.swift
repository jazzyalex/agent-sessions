import XCTest
@testable import AgentSessions

/// Parser shapes verified against real `message_nodes.chat_message` payloads
/// at CLI 3000.3.27: inline base64 images render as `[image]` markers (never
/// the payload), and `tool_calls[].arguments` is a JSON *object* on the wire,
/// unlike Grok/Kimi's JSON string.
final class DevinSessionParserTests: XCTestCase {
    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    func testUserImagesRenderAsMarkersNotPayloads() {
        let message = json(["role": "user",
                            "content": "look at this",
                            "message_id": "m1",
                            "images": [["width": 100, "height": 80, "base64_data": "QUJD"]]])

        let events = DevinSessionParser.events(fromChatMessage: message, nodeID: 7, time: nil)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .user)
        XCTAssertEqual(events[0].text, "[image]\nlook at this")
    }

    func testUserWithoutImagesKeepsContentUntouched() {
        let message = json(["role": "user", "content": "plain", "message_id": "m2"])

        let events = DevinSessionParser.events(fromChatMessage: message, nodeID: 8, time: nil)

        XCTAssertEqual(events[0].text, "plain")
    }

    /// The `tool` arm carries an optional `images` array too — for an agent
    /// that screenshots, tool-side is the likelier one — and must mark it the
    /// same way the user arm does.
    func testToolImagesRenderAsMarkersInToolOutput() {
        let message = json(["role": "tool",
                            "content": "screenshot taken",
                            "tool_call_id": "call_1",
                            "images": [["width": 100, "height": 80, "base64_data": "QUJD"]]])

        let events = DevinSessionParser.events(fromChatMessage: message, nodeID: 9, time: nil)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .tool_result)
        XCTAssertEqual(events[0].toolOutput, "[image]\nscreenshot taken")
        XCTAssertEqual(events[0].messageID, "call_1")
    }

    func testAssistantNodeExpandsIntoThinkingReplyAndCalls() {
        let message = json(["role": "assistant",
                            "content": "done",
                            "message_id": "m3",
                            "thinking": ["signature": "sig", "thinking": "reasoning"],
                            "tool_calls": [["id": "call_9", "index": 0, "kind": "tool",
                                            "name": "browser.screenshot",
                                            "arguments": ["path": "/tmp/a.png", "full_page": true]]]])

        let events = DevinSessionParser.events(fromChatMessage: message, nodeID: 10, time: nil)

        XCTAssertEqual(events.map(\.kind), [.meta, .assistant, .tool_call])
        XCTAssertTrue(events[0].text?.hasPrefix("[thinking]") ?? false)
        XCTAssertEqual(events[1].text, "done")
        XCTAssertEqual(events[2].toolName, "browser.screenshot")
        // Arguments are serialised from the object with sorted keys.
        let expected = "{\"full_page\":true,\"path\":\"\\/tmp\\/a.png\"}"
        XCTAssertEqual(events[2].toolInput, expected)
        XCTAssertEqual(events[2].messageID, "call_9")
    }

    // MARK: - Tolerated shapes

    /// Every node in the 253-session survey had a string `content`, but nothing
    /// in the store enforces it. Read as a string only, a parts array becomes a
    /// contentless assistant node, which falls through to the `.meta` fallback —
    /// and the default filters hide meta, so the turn leaves the transcript
    /// silently rather than rendering badly.
    func testAssistantContentAsPartsArrayStillRenders() {
        let message = json(["role": "assistant",
                            "message_id": "m4",
                            "content": [["type": "text", "text": "first"],
                                        ["type": "image"],
                                        ["type": "text", "text": "second"]]])

        let events = DevinSessionParser.events(fromChatMessage: message, nodeID: 11, time: nil)

        XCTAssertEqual(events.map(\.kind), [.assistant])
        XCTAssertEqual(events[0].text, "first\n[image]\nsecond")
    }

    func testUserContentAsPartsArrayStillRenders() {
        let message = json(["role": "user",
                            "message_id": "m5",
                            "content": [["type": "text", "text": "hello"]]])

        let events = DevinSessionParser.events(fromChatMessage: message, nodeID: 12, time: nil)

        XCTAssertEqual(events.map(\.kind), [.user])
        XCTAssertEqual(events[0].text, "hello")
    }

    /// A parts array of nothing renderable is not text; it must not become an
    /// empty assistant bubble.
    func testAssistantContentWithNoRenderablePartsFallsBackToMeta() {
        let message = json(["role": "assistant",
                            "message_id": "m6",
                            "content": [["type": "audio"]]])

        let events = DevinSessionParser.events(fromChatMessage: message, nodeID: 13, time: nil)

        XCTAssertEqual(events.map(\.kind), [.meta])
    }

    /// The parser has a malformed-payload branch; nothing exercised it.
    func testMalformedPayloadBecomesOneRawMetaEvent() {
        let events = DevinSessionParser.events(fromChatMessage: "{not json", nodeID: 14, time: nil)

        XCTAssertEqual(events.map(\.kind), [.meta])
        XCTAssertEqual(events[0].rawJSON, "{not json", "the unparseable text is preserved for the raw view")
        XCTAssertNil(events[0].text)
    }

    /// A payload that parses as JSON but is not an object also has no role.
    func testNonObjectPayloadBecomesOneRawMetaEvent() {
        let events = DevinSessionParser.events(fromChatMessage: "[1,2,3]", nodeID: 15, time: nil)

        XCTAssertEqual(events.map(\.kind), [.meta])
    }
}
