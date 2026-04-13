import XCTest
@testable import AgentSessions

final class OpenClawSyncTests: XCTestCase {

    // MARK: - discoverDelta

    func testDiscoverDelta_emptyPrevious_returnsAllFilesAsChanged() throws {
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/agent1/sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let fileA = sessionsDir.appendingPathComponent("a.jsonl")
        try "{}".write(to: fileA, atomically: true, encoding: .utf8)

        let discovery = OpenClawSessionDiscovery(customRoot: tmp.path)
        let delta = discovery.discoverDelta(previousByPath: [:])

        XCTAssertEqual(delta.changedFiles.count, 1)
        XCTAssertEqual(delta.changedFiles.first?.lastPathComponent, "a.jsonl")
        XCTAssertEqual(delta.removedPaths.count, 0)
        XCTAssertFalse(delta.currentByPath.isEmpty)
    }

    func testDiscoverDelta_unchangedFile_notInChangedFiles() throws {
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/agent1/sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let fileA = sessionsDir.appendingPathComponent("a.jsonl")
        try "{}".write(to: fileA, atomically: true, encoding: .utf8)

        let discovery = OpenClawSessionDiscovery(customRoot: tmp.path)

        // First delta — builds currentByPath
        let delta1 = discovery.discoverDelta(previousByPath: [:])
        XCTAssertEqual(delta1.changedFiles.count, 1)

        // Second delta with same stats — no changes
        let delta2 = discovery.discoverDelta(previousByPath: delta1.currentByPath)
        XCTAssertEqual(delta2.changedFiles.count, 0)
        XCTAssertEqual(delta2.removedPaths.count, 0)
    }

    func testDiscoverDelta_removedFile_inRemovedPaths() throws {
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/agent1/sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let fileA = sessionsDir.appendingPathComponent("a.jsonl")
        try "{}".write(to: fileA, atomically: true, encoding: .utf8)

        let discovery = OpenClawSessionDiscovery(customRoot: tmp.path)
        let delta1 = discovery.discoverDelta(previousByPath: [:])

        // Delete the file
        try FileManager.default.removeItem(at: fileA)

        let delta2 = discovery.discoverDelta(previousByPath: delta1.currentByPath)
        XCTAssertEqual(delta2.changedFiles.count, 0)
        XCTAssertEqual(delta2.removedPaths.count, 1)
        XCTAssertTrue(delta2.removedPaths.first?.hasSuffix("a.jsonl") ?? false)
    }

    // MARK: - File stat roundtrip (Codable)

    func testFileStatRoundtrip_encodeDecode() throws {
        // Validate Codable roundtrip for the persisted stats payload shape.
        struct PersistedFileStat: Codable { let mtime: Int64; let size: Int64 }
        struct Payload: Codable { let version: Int; let stats: [String: PersistedFileStat] }

        let original = Payload(version: 1, stats: [
            "/path/to/a.jsonl": PersistedFileStat(mtime: 1_700_000_000, size: 4096),
            "/path/to/b.jsonl": PersistedFileStat(mtime: 1_700_000_001, size: 8192)
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.stats.count, 2)
        XCTAssertEqual(decoded.stats["/path/to/a.jsonl"]?.mtime, 1_700_000_000)
        XCTAssertEqual(decoded.stats["/path/to/a.jsonl"]?.size, 4096)
        XCTAssertEqual(decoded.stats["/path/to/b.jsonl"]?.size, 8192)
    }

    // MARK: - Hydrate+delta merge correctness

    func testMerge_deltaSupersedesHydrated() {
        let pathA = "/sessions/a.jsonl"
        let stale = makeSession(id: "id-a", path: pathA, eventCount: 1)
        let fresh = makeSession(id: "id-a", path: pathA, eventCount: 5)

        var mergedByPath: [String: Session] = [pathA: stale]
        mergedByPath[pathA] = fresh

        XCTAssertEqual(mergedByPath[pathA]?.eventCount, 5)
    }

    func testMerge_removedPathsDroppedFromResult() {
        let pathA = "/sessions/a.jsonl"
        let pathB = "/sessions/b.jsonl"
        var mergedByPath: [String: Session] = [
            pathA: makeSession(id: "id-a", path: pathA, eventCount: 3),
            pathB: makeSession(id: "id-b", path: pathB, eventCount: 2)
        ]
        for removed in [pathB] {
            mergedByPath.removeValue(forKey: removed)
        }
        XCTAssertNotNil(mergedByPath[pathA])
        XCTAssertNil(mergedByPath[pathB])
    }

    func testMerge_newFileFromDelta_addedToResult() {
        let pathA = "/sessions/a.jsonl"
        let pathB = "/sessions/b.jsonl"
        var mergedByPath: [String: Session] = [
            pathA: makeSession(id: "id-a", path: pathA, eventCount: 3)
        ]
        mergedByPath[pathB] = makeSession(id: "id-b", path: pathB, eventCount: 7)

        XCTAssertEqual(mergedByPath.count, 2)
        XCTAssertEqual(mergedByPath[pathB]?.eventCount, 7)
    }

    // MARK: - Helpers

    private func makeTempSessionDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClawSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeSession(id: String, path: String, eventCount: Int) -> Session {
        Session(
            id: id,
            source: .openclaw,
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: path,
            eventCount: eventCount,
            events: []
        )
    }
}
