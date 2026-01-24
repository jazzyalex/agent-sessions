import XCTest
@testable import AgentSessions

final class ToolTextBlockNormalizerRegressionTests: XCTestCase {
    private func makeEvent(kind: SessionEventKind, rawJSON: String) -> SessionEvent {
        SessionEvent(id: "e1",
                     timestamp: nil,
                     kind: kind,
                     role: nil,
                     text: nil,
                     toolName: "tool",
                     toolInput: nil,
                     toolOutput: nil,
                     messageID: "call_1",
                     parentID: nil,
                     isDelta: false,
                     rawJSON: rawJSON)
    }

    func testOutputAndErrorBothRender() {
        let raw = #"{"output":"ok","error":"fail"}"#
        let event = makeEvent(kind: .tool_result, rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .opencode)
        XCTAssertEqual(block?.lines, ["ok", "fail"])
    }

    func testNonOutputStringsDoNotPreemptStdoutWhenErrorExists() {
        let raw = #"{"error":"fail","toolUseResult":{"state":"error"},"output":{"stdout":"ok"}}"#
        let event = makeEvent(kind: .tool_result, rawJSON: raw)
        let block = ToolTextBlockNormalizer.normalize(event: event, source: .opencode)
        XCTAssertEqual(block?.lines, ["ok", "fail"])
    }
}
