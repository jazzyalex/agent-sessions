import XCTest
@testable import AgentSessions

final class FxTelemetryReaderTests: XCTestCase {
    private func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
        FixturePaths.stage0FixtureURL("agents/fx/\(name)", file: file)
    }

    private func fixtureSession() throws -> Session {
        let checkpoint = fixtureURL("small/checkpoint.json")
        return try XCTUnwrap(
            FxSessionParser.parseFileFull(at: checkpoint, allowLargeFile: true),
            "fx fixture must parse")
    }

    private func stagedSession() throws -> (root: URL, checkpoint: URL, manifest: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fx-telemetry-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root.appendingPathComponent("staged-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let sourceDirectory = fixtureURL("small")
        for name in ["checkpoint.json", "display.json", "session.json"] {
            try FileManager.default.copyItem(
                at: sourceDirectory.appendingPathComponent(name),
                to: sessionDirectory.appendingPathComponent(name))
        }
        return (
            root,
            sessionDirectory.appendingPathComponent("checkpoint.json"),
            sessionDirectory.appendingPathComponent("session.json"))
    }

    private func session(at checkpoint: URL) throws -> Session {
        try XCTUnwrap(
            FxSessionParser.parseFileFull(at: checkpoint, allowLargeFile: true),
            "staged fx fixture must parse")
    }

    private func rewriteManifest(at url: URL, _ update: (inout [String: Any]) -> Void) throws {
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "manifest must be a JSON object")
        update(&object)
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try updated.write(to: url, options: .atomic)
    }

    func testReaderUsesManifestModelEffortAndAggregateTotals() throws {
        let session = try fixtureSession()
        let manifestData = try Data(contentsOf: fixtureURL("small/session.json"))
        let scan = try XCTUnwrap(FxTelemetryReader.loadTelemetry(for: session))

        XCTAssertEqual(scan.bytesScanned, UInt64(manifestData.count))
        XCTAssertEqual(scan.inputRevision, FxTelemetryReader.telemetryRevision(for: session))

        let telemetry = scan.result.telemetry
        XCTAssertEqual(telemetry.currentConfiguration?.model, "demo/model-1")
        XCTAssertEqual(telemetry.currentConfiguration?.reasoningEffort, "auto")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .sessionMetadata)
        XCTAssertEqual(telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertTrue(telemetry.configurationChanges.isEmpty)

        let usage = try XCTUnwrap(telemetry.usageSummary)
        XCTAssertEqual(usage.topLineTokens, 1_540)
        XCTAssertFalse(usage.hasComponentBreakdown)
        XCTAssertEqual(usage.recordedTotalTokens, 1_540)
        XCTAssertEqual(usage.displayTotalTokens, 1_540)
        XCTAssertEqual(usage.usageFamilies, ["session.json.totals"])
        XCTAssertNil(usage.unavailableReason)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
        XCTAssertNil(telemetry.costEstimate)
        XCTAssertNil(telemetry.weeklyQuotaEstimate)
    }

    func testEngineDispatchesFxReaderThroughRegistry() async throws {
        let session = try fixtureSession()
        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let result = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(result)

        XCTAssertEqual(telemetry.source, .fx)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "demo/model-1")
        XCTAssertEqual(telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
        XCTAssertEqual(telemetry.usageSummary?.displayTotalTokens, 1_540)
    }

    func testMalformedAggregateTotalsFailClosed() throws {
        let staged = try stagedSession()
        try rewriteManifest(at: staged.manifest) { manifest in
            manifest["total_output_tokens"] = "340"
        }

        let stagedSession = try session(at: staged.checkpoint)
        let scan = try XCTUnwrap(FxTelemetryReader.loadTelemetry(for: stagedSession))
        let usage = try XCTUnwrap(scan.result.telemetry.usageSummary)
        XCTAssertEqual(usage.topLineTokens, 0)
        XCTAssertNil(usage.recordedTotalTokens)
        XCTAssertNil(usage.displayTotalTokens)
        XCTAssertEqual(
            usage.unavailableReason,
            "fx session.json total_input_tokens and total_output_tokens are incomplete or malformed.")
        XCTAssertTrue(scan.result.telemetry.usageEvents.isEmpty)
    }

    func testManifestRevisionChangesWhenAggregateChanges() throws {
        let staged = try stagedSession()
        let session = try session(at: staged.checkpoint)
        let before = try XCTUnwrap(FxTelemetryReader.telemetryRevision(for: session))

        try rewriteManifest(at: staged.manifest) { manifest in
            manifest["total_output_tokens"] = 341
        }

        let after = try XCTUnwrap(FxTelemetryReader.telemetryRevision(for: session))
        XCTAssertNotEqual(before, after)
    }

    func testDescriptorDeclaresFxTelemetryBoundary() {
        let telemetry = SessionSourceRegistry.descriptor(for: .fx).telemetry
        XCTAssertEqual(
            telemetry.configuration,
            .partial("current model and effort come from fx session.json; fx exposes no audited configuration-change timeline"))
        XCTAssertEqual(
            telemetry.tokens,
            .partial("fx session.json records aggregate input/output totals without per-turn or cache-component attribution"))
        XCTAssertEqual(
            telemetry.cost,
            .unavailable("fx records no audited pricing identity or cache-component split"))
        XCTAssertEqual(
            telemetry.weeklyQuota,
            .unavailable("fx does not expose a compatible account quota feed"))
    }
}
