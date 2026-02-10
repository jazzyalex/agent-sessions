import XCTest
@testable import AgentSessions

final class CrashReportStoreTests: XCTestCase {
    func testStorePersistsAndDedupes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pendingURL = root.appendingPathComponent("pending.json", isDirectory: false)
        let store = CrashReportStore(fileManager: .default, pendingFileURL: pendingURL, maxPendingCount: 50)

        let first = makeEnvelope(id: "crash-1", detectedAt: Date(timeIntervalSince1970: 1_000))
        let duplicate = makeEnvelope(id: "crash-1", detectedAt: Date(timeIntervalSince1970: 1_001))
        let second = makeEnvelope(id: "crash-2", detectedAt: Date(timeIntervalSince1970: 2_000))

        await store.enqueue(contentsOf: [first, duplicate, second])

        let pending = await store.pending()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.map(\.id), ["crash-2", "crash-1"])

        let reloadedStore = CrashReportStore(fileManager: .default, pendingFileURL: pendingURL, maxPendingCount: 50)
        let reloaded = await reloadedStore.pending()
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.map(\.id), ["crash-2", "crash-1"])
    }

    private func makeEnvelope(id: String, detectedAt: Date) -> CrashReportEnvelope {
        CrashReportEnvelope(
            id: id,
            detectedAt: detectedAt,
            reportSourcePathHash: "source-hash-\(id)",
            reportFilename: "\(id).crash",
            crashTimestamp: detectedAt,
            appVersion: "2.11.2",
            appBuild: "21",
            macOSVersion: "macOS 14",
            architecture: "arm64",
            terminationSummary: "EXC_BAD_ACCESS",
            topFrames: ["0 libswiftCore.dylib swift_unknownObjectRelease"],
            breadcrumbs: ["launch.diagnostics_scan"],
            rawMetadata: ["format": "crash"]
        )
    }
}
