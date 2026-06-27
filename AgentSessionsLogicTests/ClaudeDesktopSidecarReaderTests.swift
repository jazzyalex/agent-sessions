import XCTest

final class ClaudeDesktopSidecarReaderTests: XCTestCase {
    private func makeRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccsess_\(UUID().uuidString)/ws/group", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ obj: [String: Any], named name: String, in dir: URL) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        try! data.write(to: dir.appendingPathComponent(name))
    }

    func testRecordsReadsArchiveFlagsAndPath() {
        let dir = makeRoot()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        write(["cliSessionId": "cli-1", "title": "Hello", "isArchived": true, "autoArchiveExempt": false],
              named: "local_aaa.json", in: dir)
        write(["cliSessionId": "cli-2", "title": "World", "isArchived": false],
              named: "local_bbb.json", in: dir)
        write(["title": "ignored: no cli"], named: "local_ccc.json", in: dir)
        write(["cliSessionId": "cli-9"], named: "not_a_sidecar.json", in: dir)

        let recs = ClaudeDesktopSessionTitles.records(root: dir.deletingLastPathComponent().deletingLastPathComponent())

        XCTAssertEqual(recs["cli-1"]?.isArchived, true)
        XCTAssertEqual(recs["cli-1"]?.autoArchiveExempt, false)
        XCTAssertEqual(recs["cli-1"]?.title, "Hello")
        XCTAssertTrue(recs["cli-1"]?.sidecarPath.hasSuffix("local_aaa.json") ?? false)
        XCTAssertEqual(recs["cli-2"]?.isArchived, false)
        XCTAssertNil(recs["cli-9"]) // non-local_ file ignored
        XCTAssertEqual(recs.count, 2)
    }

    func testMapStillReturnsTitles() {
        let dir = makeRoot()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        write(["cliSessionId": "cli-1", "title": "Hello"], named: "local_aaa.json", in: dir)
        let titles = ClaudeDesktopSessionTitles.map(root: dir.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(titles["cli-1"], "Hello")
    }
}
