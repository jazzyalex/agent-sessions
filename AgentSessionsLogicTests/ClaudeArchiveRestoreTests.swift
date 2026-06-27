import XCTest

final class ClaudeArchiveRestoreTests: XCTestCase {
    private func writeSidecar(_ obj: [String: Any]) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("local_\(UUID().uuidString).json")
        try! JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url.path
    }

    private func read(_ path: String) -> [String: Any] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    func testDisabledThrowsAndDoesNotWrite() {
        let path = writeSidecar(["cliSessionId": "c", "isArchived": true, "title": "keep"])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try ClaudeArchiveRestore.restore(sidecarPath: path, enabled: false)) { err in
            XCTAssertEqual(err as? ClaudeArchiveRestore.RestoreError, .disabled)
        }
        XCTAssertEqual(read(path)["isArchived"] as? Bool, true) // unchanged
    }

    func testEnabledClearsArchiveAndPreservesKeys() throws {
        let path = writeSidecar([
            "cliSessionId": "c", "isArchived": true, "autoArchiveExempt": false,
            "title": "keep", "sessionSettings": ["a": 1]
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ClaudeArchiveRestore.restore(sidecarPath: path, enabled: true)
        let out = read(path)
        XCTAssertEqual(out["isArchived"] as? Bool, false)
        XCTAssertEqual(out["autoArchiveExempt"] as? Bool, true)
        XCTAssertEqual(out["title"] as? String, "keep")
        XCTAssertEqual((out["sessionSettings"] as? [String: Any])?["a"] as? Int, 1)
    }

    func testMissingSidecarThrows() {
        XCTAssertThrowsError(try ClaudeArchiveRestore.restore(sidecarPath: "/no/such/local_x.json", enabled: true)) { err in
            XCTAssertEqual(err as? ClaudeArchiveRestore.RestoreError, .sidecarMissing)
        }
    }
}
