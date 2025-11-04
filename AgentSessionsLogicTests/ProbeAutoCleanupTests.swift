import XCTest
import Foundation

final class ProbeAutoCleanupTests: XCTestCase {
    private func setEnv(_ key: String, _ value: String) { setenv(key, value, 1) }
    private func mkdtemp(prefix: String = "as-probe-auto") -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCleanupNowIfAutoDeletesProject() throws {
        let projectsRoot = mkdtemp(prefix: "as-proj-root")
        let probeWD = mkdtemp(prefix: "as-probe-wd")
        setEnv("AS_TEST_CLAUDE_PROJECTS_ROOT", projectsRoot.path)
        setEnv("AS_TEST_PROBE_WD", probeWD.path)

        // Create a fake project matching the probe WD
        let projectDir = projectsRoot.appendingPathComponent("proj-auto")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["rootPath": probeWD.path], options: [])
            .write(to: projectDir.appendingPathComponent("project.json"))
        // Add one session with marker
        let marker = ClaudeProbeConfig.markerPrefix
        let sessionLine = ["type": "user", "sessionId": "s1", "message": ["content": "\(marker) ping"]] as [String : Any]
        let data = try JSONSerialization.data(withJSONObject: sessionLine)
        try (String(data: data, encoding: .utf8)! + "\n").write(to: projectDir.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)

        // Enable auto mode and execute immediate cleanup
        ClaudeProbeProject.setCleanupMode(.auto)
        let status = ClaudeProbeProject.cleanupNowIfAuto()
        switch status {
        case .success: break
        default: XCTFail("Expected success, got: \(status)")
        }
        var isDir: ObjCBool = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir))
    }
}

