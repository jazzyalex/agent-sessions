import XCTest
@testable import AgentSessions

final class Base64ImageDataURLScannerLineIndexTests: XCTestCase {
    private func writeTempJSONL(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Base64ImageDataURLScannerLineIndexTests-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        guard let data = text.data(using: .utf8) else {
            XCTFail("Failed to encode test fixture as UTF-8")
            return url
        }
        try data.write(to: url)
        return url
    }

    func testSpansComputeExpectedLineIndexes() throws {
        let jsonl = """
        {"type":"user","text":"no image here"}
        {"type":"user","text":"data:image/png;base64,QUJDRA=="}
        {"type":"tool_result","output":"prefix data:image/jpeg;base64,QUJDRA== suffix"}
        {"type":"assistant","text":"done"}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let located = try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.count, 2)
        XCTAssertEqual(located.map(\.lineIndex).sorted(), [1, 2])
    }

    func testSpanOnFirstLineHasLineIndexZero() throws {
        let jsonl = """
        {"type":"user","text":"data:image/png;base64,QUJDRA=="}
        {"type":"assistant","text":"ok"}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let located = try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.count, 1)
        XCTAssertEqual(located[0].lineIndex, 0)
    }

    func testLikelyImageURLContextFiltersEscapedToolOutput() throws {
        let jsonl = """
        {"type":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,QUJDRA=="}]}
        {"type":"tool_result","output":"example \\\"image_url\\\":\\\"data:image/png;base64,QUJDRA==\\\""}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let located = try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.count, 2)

        let byLine = Dictionary(grouping: located, by: \.lineIndex)
        XCTAssertEqual(byLine.keys.sorted(), [0, 1])

        let real = byLine[0]!.first!
        XCTAssertTrue(Base64ImageDataURLScanner.isLikelyImageURLContext(at: url, startOffset: real.span.startOffset))

        let escaped = byLine[1]!.first!
        XCTAssertFalse(Base64ImageDataURLScanner.isLikelyImageURLContext(at: url, startOffset: escaped.span.startOffset))
    }
}
