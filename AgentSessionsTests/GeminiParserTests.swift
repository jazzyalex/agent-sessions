import XCTest
@testable import AgentSessions

final class GeminiParserTests: XCTestCase {
    private func writeTemp(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gemini_test_\(UUID().uuidString).json")
        try json.data(using: .utf8)?.write(to: url)
        return url
    }

    func testFlatArrayTextAndParts() throws {
        let json = """
        [
          {"type":"user","text":"Prompt 1","ts":"2025-09-18T02:45:00Z"},
          {"type":"model","parts":[{"text":"Reply 1"}],"ts":"2025-09-18T02:45:08Z"}
        ]
        """
        let url = try writeTemp(json)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.events.count, 2)
        XCTAssertEqual(session.events[0].kind, .user)
        XCTAssertEqual(session.events[0].role, "user")
        XCTAssertEqual(session.events[0].text, "Prompt 1")
        XCTAssertNotNil(session.events[0].timestamp)
        XCTAssertEqual(session.events[1].kind, .assistant)
        XCTAssertEqual(session.events[1].role, "assistant")
        XCTAssertEqual(session.events[1].text, "Reply 1")
        XCTAssertNotNil(session.events[1].timestamp)
    }

    func testWrappedHistoryEpoch() throws {
        let json = """
        {
          "history": [
            {"role":"user","text":"Ask","ts":1695000000},
            {"role":"gemini","parts":[{"text":"Answer"}]}
          ],
          "meta": {"model":"gmini-pro"}
        }
        """
        let url = try writeTemp(json)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.events.count, 2)
        XCTAssertEqual(session.events[0].kind, .user)
        XCTAssertEqual(session.events[1].kind, .assistant)
        XCTAssertEqual(session.events[1].text, "Answer")
        XCTAssertNotNil(session.startTime)
        XCTAssertNotNil(session.endTime)
    }

    func testInlineDataPlaceholder() throws {
        let json = """
        {
          "history": [
            {"type":"user","parts":[{"text":"Describe this image:"},{"inlineData":{"mimeType":"image/png","data":"AAAA"}}]},
            {"type":"model","parts":[{"text":"It looks like..."}]}
          ]
        }
        """
        let url = try writeTemp(json)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.events.count, 2)
        XCTAssertTrue(session.events[0].text?.contains("[inline data omitted]") == true)
        XCTAssertEqual(session.events[1].text, "It looks like...")
    }
}

