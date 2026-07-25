import XCTest
@testable import AgentSessions

final class KimiSessionDiscoveryTests: XCTestCase {
    func testKimiSourceIdentity() {
        XCTAssertEqual(SessionSource.kimi.rawValue, "kimi")
        XCTAssertEqual(SessionSource.kimi.displayName, "Kimi Code")
        XCTAssertEqual(SessionSource.kimi.versionIntroduced, "4.7")
        XCTAssertTrue(SessionSource.allCases.contains(.kimi))
    }

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kimi-disc-\(UUID().uuidString)", isDirectory: true)
        let main = root.appendingPathComponent("sessions/wd_project_0123456789ab/sess-1/agents/main", isDirectory: true)
        let sub = root.appendingPathComponent("sessions/wd_project_0123456789ab/sess-1/agents/agent-7/", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let envelope = #"{"type":"metadata","protocol_version":"1.5","created_at":1750000000000}"#
        try (envelope + "\n").write(to: main.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
        try (envelope + "\n").write(to: sub.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    func testDiscoversOnlyMainWireFiles() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = KimiSessionDiscovery(customRoot: root.path).discoverSessionFiles()

        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].path.hasSuffix("sess-1/agents/main/wire.jsonl"))
    }

    func testSessionIDIsTheSessionDirectoryName() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = KimiSessionDiscovery(customRoot: root.path).discoverSessionFiles()[0]

        XCTAssertEqual(KimiSessionDiscovery.sessionID(forWireFile: file), "sess-1")
    }

    func testRejectsFileWithoutMetadataEnvelope() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("sessions/wd_project_0123456789ab/sess-1/agents/main/wire.jsonl")
        try #"{"type":"context.append_message"}"# .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(KimiSessionDiscovery(customRoot: root.path).discoverSessionFiles().isEmpty)
    }

    func testDefaultRootIsKimiCodeSessions() {
        let root = KimiSessionDiscovery().sessionsRoot()
        XCTAssertTrue(root.path.hasSuffix("/.kimi-code/sessions"))
    }
}
