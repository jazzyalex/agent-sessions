import XCTest
import Foundation

final class ClaudeProbeProjectTests: XCTestCase {
    private func setEnv(_ key: String, _ value: String) {
        setenv(key, value, 1)
    }

    private func mkdtemp(prefix: String = "as-probe-tests") -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testDiscoveryFindsProjectMatchingProbeWD() throws {
        let testRoot = mkdtemp(prefix: "as-probe-projects")
        let probeWD = mkdtemp(prefix: "as-probe-wd")

        // Override roots for test
        setEnv("AS_TEST_CLAUDE_PROJECTS_ROOT", testRoot.path)
        setEnv("AS_TEST_PROBE_WD", probeWD.path)

        // Create a fake Claude project with project.json matching Probe WD
        let projectDir = testRoot.appendingPathComponent("proj-123")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let metaURL = projectDir.appendingPathComponent("project.json")
        let meta = ["rootPath": probeWD.path]
        let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
        try metaData.write(to: metaURL)

        // Discovery should return the folder name
        let id = ClaudeProbeProject.discoverProbeProjectId()
        XCTAssertEqual(id, "proj-123")
    }

    func testCleanupRefusesWhenMarkerMissing() throws {
        let testRoot = mkdtemp(prefix: "as-probe-projects")
        let probeWD = mkdtemp(prefix: "as-probe-wd")
        setEnv("AS_TEST_CLAUDE_PROJECTS_ROOT", testRoot.path)
        setEnv("AS_TEST_PROBE_WD", probeWD.path)

        // Make project and metadata
        let projectDir = testRoot.appendingPathComponent("proj-no-marker")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["rootPath": probeWD.path], options: []).write(to: projectDir.appendingPathComponent("project.json"))

        // A session file whose first user message lacks the marker
        let sessionFile = projectDir.appendingPathComponent("session.ndjson")
        let userLine = ["type": "user", "sessionId": "s1", "message": ["content": "hello world"]] as [String : Any]
        let assistant = ["type": "assistant", "sessionId": "s1", "message": ["content": "ok"]] as [String : Any]
        let data1 = try JSONSerialization.data(withJSONObject: userLine)
        let data2 = try JSONSerialization.data(withJSONObject: assistant)
        let content = String(data: data1, encoding: .utf8)! + "\n" + String(data: data2, encoding: .utf8)! + "\n"
        try content.write(to: sessionFile, atomically: true, encoding: .utf8)

        let status = ClaudeProbeProject.cleanupNowUserInitiated()
        switch status {
        case .unsafe:
            break // expected
        default:
            XCTFail("Expected unsafe, got: \(status)")
        }
        // Directory should still exist
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testCleanupDeletesWhenAllMarked() throws {
        let testRoot = mkdtemp(prefix: "as-probe-projects")
        let probeWD = mkdtemp(prefix: "as-probe-wd")
        setEnv("AS_TEST_CLAUDE_PROJECTS_ROOT", testRoot.path)
        setEnv("AS_TEST_PROBE_WD", probeWD.path)

        let projectDir = testRoot.appendingPathComponent("proj-marked")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["rootPath": probeWD.path], options: []).write(to: projectDir.appendingPathComponent("project.json"))

        // Session: first user message with marker
        let sessionFile = projectDir.appendingPathComponent("session.jsonl")
        let marker = ClaudeProbeConfig.markerPrefix
        let userLine = ["type": "user", "sessionId": "s2", "message": ["content": "\(marker) ping"]] as [String : Any]
        let assistant = ["type": "assistant", "sessionId": "s2", "message": ["content": "pong"]] as [String : Any]
        let data1 = try JSONSerialization.data(withJSONObject: userLine)
        let data2 = try JSONSerialization.data(withJSONObject: assistant)
        let content = String(data: data1, encoding: .utf8)! + "\n" + String(data: data2, encoding: .utf8)! + "\n"
        try content.write(to: sessionFile, atomically: true, encoding: .utf8)

        let status = ClaudeProbeProject.cleanupNowUserInitiated()
        switch status {
        case .success:
            break // expected
        default:
            XCTFail("Expected success, got: \(status)")
        }
        // Directory should be deleted
        var isDir: ObjCBool = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir))
    }
}
