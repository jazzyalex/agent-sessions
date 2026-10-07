import XCTest
@testable import AgentSessions
#if canImport(Darwin)
import Darwin
#endif

#if canImport(Darwin)
private func setExactModificationTime(of url: URL, nanoseconds: Int64) throws {
    let seconds = nanoseconds / 1_000_000_000
    let remainder = nanoseconds % 1_000_000_000
    var times = [
        timespec(tv_sec: Int(seconds), tv_nsec: Int(remainder)),
        timespec(tv_sec: Int(seconds), tv_nsec: Int(remainder))
    ]
    let result = times.withUnsafeMutableBufferPointer { buffer in
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return utimensat(AT_FDCWD, path, buffer.baseAddress, 0)
        }
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
#endif

private final class DroidOneShotFileAppend: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let data: Data
    private var didRun = false

    init(url: URL, line: String) {
        self.url = url
        data = Data("\n\(line)".utf8)
    }

    func run() {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()

        guard let writer = try? FileHandle(forWritingTo: url) else { return }
        writer.seekToEndOfFile()
        writer.write(data)
        try? writer.close()
    }
}

final class ExpandedTelemetryProviderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("expanded-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writeJSONL(_ lines: [String], to url: URL) throws {
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    private func makeDroidSession(id: String = "droid-session",
                                  fileName: String? = nil,
                                  lines: [String],
                                  settings: [String: Any]? = nil,
                                  model: String? = nil) throws -> Session {
        let name = fileName ?? id
        let transcriptURL = directory.appendingPathComponent("\(name).jsonl")
        try writeJSONL(lines, to: transcriptURL)
        if let settings {
            try writeJSON(settings,
                          to: directory.appendingPathComponent("\(name).settings.json"))
        }
        return Session(id: id,
                       source: .droid,
                       startTime: nil,
                       endTime: nil,
                       model: model,
                       filePath: transcriptURL.path,
                       eventCount: 0,
                       events: [])
    }

    private func makeClineSession(id: String = "cline-session",
                                  messages: [[String: Any]],
                                  manifestModel: String = "cline-free/deepseek-v4.1-flash") throws -> Session {
        let sessionDirectory = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let manifestURL = sessionDirectory.appendingPathComponent("\(id).json")
        try writeJSON([
            "version": 1,
            "session_id": id,
            "source": "cli",
            "started_at": "2026-10-07T20:00:00Z",
            "model": manifestModel,
            "cwd": "/tmp/project"
        ], to: manifestURL)
        let messagesURL = ClineSessionDiscovery.messagesFile(forManifest: manifestURL)
        try writeJSON([
            "version": 1,
            "sessionId": id,
            "messages": messages
        ], to: messagesURL)
        return Session(id: id,
                       source: .cline,
                       startTime: nil,
                       endTime: nil,
                       model: manifestModel,
                       filePath: manifestURL.path,
                       eventCount: 0,
                       events: [])
    }

    private func makeQwenSession(
        id: String = "12345678-1234-1234-1234-123456789012",
        records: [[String: Any]],
        model: String? = "qwen-current") throws -> Session {
        let transcriptURL = directory.appendingPathComponent("\(id).jsonl")
        let lines = try records.map { record in
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        try writeJSONL(lines, to: transcriptURL)
        return Session(id: id,
                       source: .qwen,
                       startTime: nil,
                       endTime: nil,
                       model: model,
                       filePath: transcriptURL.path,
                       eventCount: 0,
                       events: [])
    }

    private func qwenRecord(id: String,
                            parent: String?,
                            sessionID: String,
                            type: String,
                            timestamp: String,
                            model: String? = nil,
                            usage: [String: Any]? = nil,
                            subtype: String? = nil,
                            forkedFrom: [String: Any]? = nil,
                            systemPayload: [String: Any]? = nil) -> [String: Any] {
        var record: [String: Any] = [
            "uuid": id,
            "parentUuid": parent ?? NSNull(),
            "sessionId": sessionID,
            "type": type,
            "timestamp": timestamp
        ]
        if let model { record["model"] = model }
        if let usage { record["usageMetadata"] = usage }
        if let subtype { record["subtype"] = subtype }
        if let forkedFrom { record["forkedFrom"] = forkedFrom }
        if let systemPayload { record["systemPayload"] = systemPayload }
        return record
    }

    private func qwenUsage(prompt: Int,
                           cached: Int,
                           output: Int,
                           thoughts: Int,
                           total: Int? = nil) -> [String: Any] {
        [
            "promptTokenCount": prompt,
            "cachedContentTokenCount": cached,
            "candidatesTokenCount": output,
            "thoughtsTokenCount": thoughts,
            "totalTokenCount": total ?? prompt + output
        ]
    }

    private func deepSeekFixtureURL(_ name: String = "v4_tool_session.jsonl") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fixtures/stage0/agents/deepseek-harness", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func makeDeepSeekSession(
        mutateRecord: ((inout [String: Any]) -> Void)? = nil,
        addSibling: Bool = false
    ) throws -> Session {
        let root = directory.appendingPathComponent("dsh-sessions", isDirectory: true)
        let cwd = "/tmp/synthetic-dsh-demo"
        let id = "dsh-synth-v4-tool-0001"
        let url = DeepSeekHarnessDiscovery.canonicalGenerationURL(
            root: root, cwd: cwd, id: id, version: 4, compression: .plain)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fixtureData = try Data(contentsOf: deepSeekFixtureURL())
        let rawLines = String(decoding: fixtureData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        var renderedLines: [String] = []
        for rawLine in rawLines {
            guard var object = try JSONSerialization.jsonObject(
                with: Data(rawLine.utf8), options: []) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let mutateRecord {
                mutateRecord(&object)
            }
            renderedLines.append(String(decoding: try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        }
        try Data((renderedLines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)

        if addSibling {
            let sibling = url.deletingLastPathComponent().appendingPathComponent("session.v3.jsonl")
            try Data("sibling-revision".utf8).write(to: sibling, options: .atomic)
        }

        return Session(id: id,
                       source: .deepseekHarness,
                       startTime: nil,
                       endTime: nil,
                       model: "stale-session-model",
                       filePath: url.path,
                       eventCount: 0,
                       events: [])
    }

    func testRegistryDispatchesThePrioritizedProviders() {
        for source in [SessionSource.antigravity, .kimi, .grok, .devin, .fx, .cline, .droid, .deepseekHarness, .qwen] {
            let descriptor = SessionSourceRegistry.descriptor(for: source)
            XCTAssertTrue(descriptor.hasTelemetryBackend, "\(source) has no registry telemetry provider")
            XCTAssertTrue(descriptor.telemetry.tokens.isAvailable || descriptor.telemetry.configuration.isAvailable)
        }
    }

    func testEngineUsesQwenRegistryReaderForActiveBranchUsage() async throws {
        let sessionID = "12345678-1234-1234-1234-123456789012"
        let rootID = "root-0001"
        let firstAssistantID = "assistant-0001"
        let deadAssistantID = "assistant-dead"
        let currentAssistantID = "assistant-0002"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: rootID, parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: firstAssistantID, parent: rootID, sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-old",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1)),
            qwenRecord(id: deadAssistantID, parent: rootID, sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:02.000Z", model: "dead-branch",
                       usage: qwenUsage(prompt: 900, cached: 100, output: 90, thoughts: 5)),
            qwenRecord(id: currentAssistantID, parent: firstAssistantID, sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:03.000Z", model: "qwen-new",
                       usage: qwenUsage(prompt: 20, cached: 5, output: 6, thoughts: 2))
        ])

        let scan = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: session.filePath)).count
        XCTAssertEqual(scan.bytesScanned, UInt64(bytes))
        XCTAssertEqual(scan.inputRevision, QwenTelemetryReader.telemetryRevision(for: session))

        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let loaded = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(loaded)
        XCTAssertEqual(telemetry.source, .qwen)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "qwen-old")
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "qwen-current")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .sessionMetadata)
        XCTAssertNil(telemetry.currentConfiguration?.observedAt)
        XCTAssertNil(telemetry.currentConfiguration?.anchorLine)
        XCTAssertNil(telemetry.currentConfiguration?.modelObservedAt)
        XCTAssertNil(telemetry.currentConfiguration?.modelAnchorLine)
        XCTAssertEqual(telemetry.configurationChanges.count, 1)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 40)
        XCTAssertEqual(telemetry.usageSummary?.recordedTotalTokens, 40)
        XCTAssertTrue(telemetry.usageSummary?.hasComponentBreakdown == true)
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["qwen.assistant.usageMetadata"])
        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertEqual(telemetry.usageEvents.first?.freshInputTokens, 8)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheReadTokens, 2)
        XCTAssertEqual(telemetry.usageEvents.first?.outputTokens, 4)
        XCTAssertEqual(telemetry.usageSlices.reduce(0) { $0 + $1.reasoningOutputTokens }, 3)
        XCTAssertFalse(telemetry.usageSlices.contains { $0.model == "dead-branch" })
        XCTAssertNil(telemetry.costEstimate)
    }

    func testQwenFailsClosedWhenAssistantUsageIsMalformed() throws {
        let sessionID = "12345678-1234-1234-1234-123456789013"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-0002", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-0003", parent: "root-0002", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 11, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen assistant usageMetadata is incomplete or malformed.")
        XCTAssertFalse(telemetry.usageSummary?.hasComponentBreakdown ?? true)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "qwen-current")
    }

    func testQwenRejectsRecordsForAnotherSession() throws {
        let sessionID = "12345678-1234-1234-1234-123456789014"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-0003", parent: nil, sessionID: "different-session-id", type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z")
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen records do not agree with the selected session identity.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenKeepsLoadedSessionModelWhenTranscriptHasNoAssistantRecord() throws {
        let sessionID = "12345678-1234-1234-1234-123456789015"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-0004", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z")
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "qwen-current")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .sessionMetadata)
        XCTAssertNil(telemetry.currentConfiguration?.modelObservedAt)
        XCTAssertNil(telemetry.currentConfiguration?.modelAnchorLine)
        XCTAssertNil(telemetry.usageSummary)
    }

    func testQwenNormalizesGeminiUsageWithSeparateThoughtsAndToolPrompt() throws {
        let sessionID = "12345678-1234-1234-1234-123456789016"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-0005", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-0005", parent: "root-0005", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "gemini-qwen",
                       usage: [
                           "promptTokenCount": 100,
                           "cachedContentTokenCount": 10,
                           "candidatesTokenCount": 20,
                           "thoughtsTokenCount": 30,
                           "toolUsePromptTokenCount": 5,
                           "totalTokenCount": 155
                       ])
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 155)
        XCTAssertEqual(telemetry.usageSummary?.recordedTotalTokens, 155)
        XCTAssertEqual(telemetry.usageEvents.count, 1)
        XCTAssertEqual(telemetry.usageEvents.first?.freshInputTokens, 95)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheReadTokens, 10)
        XCTAssertEqual(telemetry.usageEvents.first?.outputTokens, 50)
        XCTAssertEqual(telemetry.usageEvents.first?.reasoningOutputTokens, 30)
        XCTAssertEqual(telemetry.usageSlices.first?.reasoningOutputTokens, 30)
    }

    func testQwenAcceptsGeminiUsageWhenOptionalZeroFieldsAreAbsent() throws {
        let sessionID = "12345678-1234-1234-1234-123456789025"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-optional", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-optional", parent: "root-optional", sessionID: sessionID,
                       type: "assistant", timestamp: "2026-10-07T20:00:01.000Z", model: "gemini-qwen",
                       usage: [
                           "promptTokenCount": 23,
                           "candidatesTokenCount": 35,
                           "toolUsePromptTokenCount": 289,
                           "totalTokenCount": 347
                       ])
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 347)
        XCTAssertEqual(telemetry.usageEvents.first?.freshInputTokens, 312)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheReadTokens, 0)
        XCTAssertEqual(telemetry.usageEvents.first?.outputTokens, 35)
        XCTAssertEqual(telemetry.usageEvents.first?.reasoningOutputTokens, 0)
    }

    func testQwenAcceptsZeroCandidatesWhenGeminiOmitsCandidateCount() throws {
        let sessionID = "12345678-1234-1234-1234-123456789034"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-zero-candidates", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-zero-candidates", parent: "root-zero-candidates",
                       sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "gemini-qwen",
                       usage: [
                           "promptTokenCount": 268,
                           "totalTokenCount": 268
                       ])
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 268)
        XCTAssertEqual(telemetry.usageEvents.first?.outputTokens, 0)
        XCTAssertEqual(telemetry.usageEvents.first?.reasoningOutputTokens, 0)
    }

    func testQwenRejectsHybridUsageThatDropsToolPromptFromTotal() throws {
        let sessionID = "12345678-1234-1234-1234-123456789026"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-hybrid", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-hybrid", parent: "root-hybrid", sessionID: sessionID,
                       type: "assistant", timestamp: "2026-10-07T20:00:01.000Z", model: "gemini-qwen",
                       usage: [
                           "promptTokenCount": 100,
                           "cachedContentTokenCount": 10,
                           "candidatesTokenCount": 20,
                           "thoughtsTokenCount": 5,
                           "toolUsePromptTokenCount": 7,
                           "totalTokenCount": 120
                       ])
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen assistant usageMetadata is incomplete or malformed.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenExcludesForkInheritedAssistantUsageFromChildTotals() throws {
        let sessionID = "12345678-1234-1234-1234-123456789017"
        let fork = ["sessionId": "parent-session", "messageUuid": "parent-message"]
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-0006", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z", forkedFrom: fork),
            qwenRecord(id: "assistant-inherited", parent: "root-0006", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-parent",
                       usage: qwenUsage(prompt: 100, cached: 10, output: 20, thoughts: 2),
                       forkedFrom: fork),
            qwenRecord(id: "assistant-local", parent: "assistant-inherited", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:02.000Z", model: "qwen-child",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 14)
        XCTAssertEqual(telemetry.usageEvents.count, 1)
        XCTAssertEqual(telemetry.usageEvents.first?.recordID, "assistant-local")
        XCTAssertFalse(telemetry.usageSlices.contains { $0.model == "qwen-parent" })
    }

    func testQwenFailsClosedWhenAnyLocalAssistantUsageIsMissing() throws {
        let sessionID = "12345678-1234-1234-1234-123456789018"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-0007", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-missing", parent: "root-0007", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model"),
            qwenRecord(id: "assistant-known", parent: "assistant-missing", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:02.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen assistant usageMetadata is missing for at least one local assistant record.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
    }

    func testQwenSessionModelRecordWinsForCurrentModelProvenance() throws {
        let sessionID = "12345678-1234-1234-1234-123456789019"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-0008", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-0008", parent: "root-0008", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-old",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1)),
            qwenRecord(id: "model-change-0001", parent: "assistant-0008", sessionID: sessionID, type: "system",
                       timestamp: "2026-10-07T20:00:02.000Z", subtype: "session_model",
                       systemPayload: ["modelId": "qwen-new"])
        ], model: "qwen-old")

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "qwen-new")
        XCTAssertEqual(telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
        XCTAssertEqual(telemetry.currentConfiguration?.modelAnchorLine, 2)
        XCTAssertEqual(QwenSessionParser.parseFileFull(at: URL(fileURLWithPath: session.filePath))?.model,
                       "qwen-new")
    }

    func testQwenSessionModelRemainsAuthoritativeAfterAssistantRecord() throws {
        let sessionID = "12345678-1234-1234-1234-123456789027"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-order", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "model-order", parent: "root-order", sessionID: sessionID, type: "system",
                       timestamp: "2026-10-07T20:00:01.000Z", subtype: "session_model",
                       systemPayload: ["modelId": "qwen-new"]),
            qwenRecord(id: "assistant-order", parent: "model-order", sessionID: sessionID,
                       type: "assistant", timestamp: "2026-10-07T20:00:02.000Z", model: "qwen-new",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ], model: "qwen-old")

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "qwen-new")
        XCTAssertEqual(telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
        XCTAssertEqual(telemetry.currentConfiguration?.modelAnchorLine, 1)
        XCTAssertNotNil(telemetry.currentConfiguration?.modelObservedAt)
    }

    func testQwenMarksBrokenActiveParentChainUnavailable() throws {
        let sessionID = "12345678-1234-1234-1234-123456789020"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "assistant-orphan", parent: "missing-parent", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen active branch topology is incomplete; token usage is unavailable.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenMarksCyclicActiveParentChainUnavailable() throws {
        let sessionID = "12345678-1234-1234-1234-123456789021"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "cycle-a", parent: "cycle-b", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1)),
            qwenRecord(id: "cycle-b", parent: "cycle-a", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:02.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen active branch topology is incomplete; token usage is unavailable.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenDoesNotTrimIdentityFieldsWhenWalkingActiveChain() throws {
        let sessionID = "12345678-1234-1234-1234-123456789028"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: " root ", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-whitespace", parent: "root", sessionID: sessionID,
                       type: "assistant", timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen active branch topology is incomplete; token usage is unavailable.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenFailsClosedForConflictingRepeatedUUIDParents() throws {
        let sessionID = "12345678-1234-1234-1234-123456789029"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-conflict", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-conflict", parent: "root-conflict", sessionID: sessionID,
                       type: "assistant", timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model"),
            qwenRecord(id: "assistant-conflict", parent: "other-root", sessionID: sessionID,
                       type: "assistant", timestamp: "2026-10-07T20:00:02.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen active branch topology is incomplete; token usage is unavailable.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenFailsClosedForConflictingRepeatedUUIDTypes() throws {
        let sessionID = "12345678-1234-1234-1234-123456789030"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-type-conflict", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "assistant-type-conflict", parent: "root-type-conflict", sessionID: sessionID,
                       type: "assistant", timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model"),
            qwenRecord(id: "assistant-type-conflict", parent: "root-type-conflict", sessionID: sessionID,
                       type: "system", timestamp: "2026-10-07T20:00:02.000Z",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1), subtype: "ui_telemetry")
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen active branch topology is incomplete; token usage is unavailable.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenIgnoresConflictingRepeatedUUIDOnDeadBranch() throws {
        let sessionID = "12345678-1234-1234-1234-123456789031"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-dead-conflict", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "dead-parent", parent: "root-dead-conflict", sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:01.000Z"),
            qwenRecord(id: "dead-repeated", parent: "dead-parent", sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:02.000Z", model: "dead-model"),
            qwenRecord(id: "dead-repeated", parent: "dead-parent", sessionID: sessionID, type: "system",
                       timestamp: "2026-10-07T20:00:03.000Z",
                       usage: qwenUsage(prompt: 900, cached: 100, output: 90, thoughts: 5), subtype: "ui_telemetry"),
            qwenRecord(id: "active-assistant", parent: "root-dead-conflict", sessionID: sessionID,
                       type: "assistant", timestamp: "2026-10-07T20:00:04.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 14)
        XCTAssertEqual(telemetry.usageEvents.count, 1)
        XCTAssertEqual(telemetry.usageEvents.first?.recordID, "active-assistant")
    }

    func testQwenIgnoresConflictingRepeatedUUIDSessionOnDeadBranch() throws {
        let sessionID = "12345678-1234-1234-1234-123456789032"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-dead-session", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "dead-session-conflict", parent: "root-dead-session",
                       sessionID: "other-qwen-session", type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "dead-model",
                       usage: qwenUsage(prompt: 900, cached: 100, output: 90, thoughts: 5)),
            qwenRecord(id: "dead-session-conflict", parent: "root-dead-session",
                       sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:02.000Z", model: "dead-model",
                       usage: qwenUsage(prompt: 800, cached: 80, output: 80, thoughts: 4)),
            qwenRecord(id: "active-session-assistant", parent: "root-dead-session",
                       sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:03.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 14)
        XCTAssertEqual(telemetry.usageEvents.map(\.recordID), ["active-session-assistant"])
    }

    func testQwenFailsClosedForConflictingRepeatedUUIDSessionOnActiveBranch() throws {
        let sessionID = "12345678-1234-1234-1234-123456789033"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-active-session", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "active-session-conflict", parent: "root-active-session",
                       sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1)),
            qwenRecord(id: "active-session-conflict", parent: "root-active-session",
                       sessionID: "other-qwen-session", type: "assistant",
                       timestamp: "2026-10-07T20:00:02.000Z", model: "other-model",
                       usage: qwenUsage(prompt: 900, cached: 100, output: 90, thoughts: 5))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen records do not agree with the selected session identity.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenIgnoresConflictingRepeatedUUIDArtifactOnDeadBranch() throws {
        let sessionID = "12345678-1234-1234-1234-123456789035"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-dead-artifact", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "dead-artifact-conflict", parent: "root-dead-artifact",
                       sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "dead-model"),
            qwenRecord(id: "dead-artifact-conflict", parent: "root-dead-artifact",
                       sessionID: "other-qwen-session", type: "system",
                       timestamp: "2026-10-07T20:00:02.000Z", subtype: "session_artifact_event"),
            qwenRecord(id: "active-artifact-safe", parent: "root-dead-artifact",
                       sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:03.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1))
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 14)
        XCTAssertEqual(telemetry.usageEvents.map(\.recordID), ["active-artifact-safe"])
    }

    func testQwenFailsClosedForConflictingRepeatedUUIDArtifactOnActiveBranch() throws {
        let sessionID = "12345678-1234-1234-1234-123456789036"
        let session = try makeQwenSession(id: sessionID, records: [
            qwenRecord(id: "root-active-artifact", parent: nil, sessionID: sessionID, type: "user",
                       timestamp: "2026-10-07T20:00:00.000Z"),
            qwenRecord(id: "active-artifact-conflict", parent: "root-active-artifact",
                       sessionID: sessionID, type: "assistant",
                       timestamp: "2026-10-07T20:00:01.000Z", model: "qwen-model",
                       usage: qwenUsage(prompt: 10, cached: 2, output: 4, thoughts: 1)),
            qwenRecord(id: "active-artifact-conflict", parent: "root-active-artifact",
                       sessionID: "other-qwen-session", type: "system",
                       timestamp: "2026-10-07T20:00:02.000Z", subtype: "session_artifact_snapshot")
        ])

        let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Qwen records do not agree with the selected session identity.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testQwenRejectsBooleanAndStringTokenCounts() throws {
        let cases: [[String: Any]] = [
            ["promptTokenCount": true, "cachedContentTokenCount": 0,
             "candidatesTokenCount": 0, "thoughtsTokenCount": 0, "totalTokenCount": true],
            ["promptTokenCount": "10", "cachedContentTokenCount": 0,
             "candidatesTokenCount": 1, "thoughtsTokenCount": 0, "totalTokenCount": "11"]
        ]
        for (offset, usage) in cases.enumerated() {
            let sessionID = "12345678-1234-1234-1234-1234567890\(22 + offset)"
            let session = try makeQwenSession(id: sessionID, records: [
                qwenRecord(id: "root-strict-\(offset)", parent: nil, sessionID: sessionID, type: "user",
                           timestamp: "2026-10-07T20:00:00.000Z"),
                qwenRecord(id: "assistant-strict-\(offset)", parent: "root-strict-\(offset)",
                           sessionID: sessionID, type: "assistant", timestamp: "2026-10-07T20:00:01.000Z",
                           model: "qwen-model", usage: usage)
            ])
            let telemetry = try XCTUnwrap(QwenTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
            XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                           "Qwen assistant usageMetadata is incomplete or malformed.")
            XCTAssertTrue(telemetry.usageEvents.isEmpty)
        }
    }

    func testEngineUsesDeepSeekRegistryReaderForV4AssistantUsage() async throws {
        let session = try makeDeepSeekSession(mutateRecord: { object in
            guard var data = object["data"] as? [String: Any],
                  var header = data["header"] as? [String: Any] else { return }
            var config = header["config"] as? [String: Any] ?? [:]
            config["reasoningEffort"] = "high"
            header["config"] = config
            data["header"] = header
            object["data"] = data
        })

        let scan = try XCTUnwrap(DeepSeekHarnessTelemetryReader.loadTelemetry(for: session))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: session.filePath)).count
        XCTAssertEqual(scan.bytesScanned, UInt64(bytes))
        XCTAssertEqual(scan.inputRevision, DeepSeekHarnessTelemetryReader.telemetryRevision(for: session))

        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let loadedTelemetry = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(loadedTelemetry)

        XCTAssertEqual(telemetry.source, .deepseekHarness)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "synthetic-model")
        XCTAssertEqual(telemetry.initialConfiguration?.reasoningEffort, "high")
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.initialConfiguration?.modelProvenance, .requestRecord)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "synthetic-model")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .requestRecord)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 36)
        XCTAssertEqual(telemetry.usageSummary?.recordedTotalTokens, 36)
        XCTAssertTrue(telemetry.usageSummary?.hasComponentBreakdown == true)
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["assistant.message.usage"])
        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertEqual(telemetry.usageEvents.first?.freshInputTokens, 10)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheReadTokens, 2)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheWrite5mTokens, 1)
        XCTAssertEqual(telemetry.usageEvents.first?.contextInputTokens, 13)
        XCTAssertEqual(telemetry.usageSlices.first?.outputTokens, 10)
        XCTAssertNil(telemetry.costEstimate)
    }

    func testDeepSeekStreamUsageDuplicateIsVerifiedWithoutDoubleCounting() throws {
        let session = try makeDeepSeekSession(mutateRecord: { object in
            guard var data = object["data"] as? [String: Any],
                  let usage = data["usage"] as? [String: Any] else { return }
            data["stream"] = [[
                "type": "chunk",
                "time": 1700000000006,
                "chunk": ["type": "usage", "usage": usage]
            ], [
                "type": "chunk",
                "time": 1700000000007,
                "chunk": ["type": "usage", "usage": usage]
            ]]
            object["data"] = data
        })

        let telemetry = try XCTUnwrap(
            DeepSeekHarnessTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 36)
        XCTAssertEqual(telemetry.usageEvents.count, 2)
    }

    func testDeepSeekUsesFinalStreamUsageWhenTopLevelUsageIsAbsent() throws {
        let session = try makeDeepSeekSession(mutateRecord: { object in
            guard var data = object["data"] as? [String: Any],
                  let usage = data["usage"] as? [String: Any] else { return }
            data.removeValue(forKey: "usage")
            data["stream"] = [[
                "type": "chunk",
                "time": 1700000000006,
                "chunk": ["type": "usage", "usage": usage]
            ], [
                "type": "chunk",
                "time": 1700000000007,
                "chunk": ["type": "usage", "usage": usage]
            ]]
            object["data"] = data
        })

        let telemetry = try XCTUnwrap(
            DeepSeekHarnessTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 36)
        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertEqual(telemetry.usageEvents.first?.contextInputTokens, 13)
    }

    func testDeepSeekFailsClosedWhenStreamUsageConflictsWithAssistantUsage() throws {
        let session = try makeDeepSeekSession(mutateRecord: { object in
            guard var data = object["data"] as? [String: Any],
                  var usage = data["usage"] as? [String: Any] else { return }
            usage["outputTokens"] = 6
            usage["totalTokens"] = 19
            data["stream"] = [[
                "type": "chunk",
                "time": 1700000000006,
                "chunk": ["type": "usage", "usage": usage]
            ]]
            object["data"] = data
        })

        let telemetry = try XCTUnwrap(
            DeepSeekHarnessTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "synthetic-model")
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "DeepSeek Harness assistant usage is incomplete or inconsistent.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
    }

    func testDeepSeekFailsClosedForConflictingStreamOnlyUsageSamples() throws {
        let session = try makeDeepSeekSession(mutateRecord: { object in
            guard var data = object["data"] as? [String: Any],
                  var usage = data["usage"] as? [String: Any] else { return }
            data.removeValue(forKey: "usage")
            usage["outputTokens"] = 6
            usage["totalTokens"] = 19
            data["stream"] = [[
                "type": "chunk",
                "time": 1700000000006,
                "chunk": ["type": "usage", "usage": [
                    "inputTokens": 10, "outputTokens": 5,
                    "cacheReadTokens": 2, "cacheWriteTokens": 1,
                    "totalTokens": 18
                ]]
            ], [
                "type": "chunk",
                "time": 1700000000007,
                "chunk": ["type": "usage", "usage": usage]
            ]]
            object["data"] = data
        })

        let telemetry = try XCTUnwrap(
            DeepSeekHarnessTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "DeepSeek Harness assistant usage is incomplete or inconsistent.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
    }

    func testDeepSeekFailsClosedWhenRecordedTotalDoesNotMatchComponents() throws {
        let session = try makeDeepSeekSession(mutateRecord: { object in
            guard var data = object["data"] as? [String: Any],
                  var usage = data["usage"] as? [String: Any] else { return }
            usage["totalTokens"] = 17
            data["usage"] = usage
            object["data"] = data
        })

        let telemetry = try XCTUnwrap(
            DeepSeekHarnessTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "DeepSeek Harness assistant usage is incomplete or inconsistent.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "synthetic-model")
    }

    func testDeepSeekReportsMissingUsageWithoutFallingThroughToGenericParser() throws {
        let session = try makeDeepSeekSession(mutateRecord: { object in
            guard var data = object["data"] as? [String: Any] else { return }
            data.removeValue(forKey: "usage")
            object["data"] = data
        })

        let scan = try XCTUnwrap(DeepSeekHarnessTelemetryReader.loadTelemetry(for: session))
        XCTAssertEqual(scan.result.telemetry.usageSummary?.unavailableReason,
                       "DeepSeek Harness did not record usable assistant usage.")
        XCTAssertTrue(scan.result.telemetry.usageEvents.isEmpty)
        XCTAssertEqual(scan.result.telemetry.currentConfiguration?.model, "synthetic-model")
    }

    func testDeepSeekSiblingManifestRevisionInvalidatesTelemetryCache() async throws {
        let session = try makeDeepSeekSession()
        let before = try XCTUnwrap(DeepSeekHarnessTelemetryReader.telemetryRevision(for: session))
        let sibling = URL(fileURLWithPath: session.filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("session.v3.jsonl")
        try Data("same-size-one".utf8).write(to: sibling, options: .atomic)
        let firstSiblingStat = try XCTUnwrap(SessionFileStat.precise(from: sibling))
        let after = try XCTUnwrap(DeepSeekHarnessTelemetryReader.telemetryRevision(for: session))
        XCTAssertNotEqual(before, after)

        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let firstLoaded = await engine.telemetry(for: session)
        _ = try XCTUnwrap(firstLoaded)
        let parseCountAfterFirst = engine.parseCount
        try Data("same-size-two".utf8).write(to: sibling)
        #if canImport(Darwin)
        try setExactModificationTime(of: sibling, nanoseconds: firstSiblingStat.mtime)
        #endif
        let secondSiblingStat = try XCTUnwrap(SessionFileStat.precise(from: sibling))
        XCTAssertEqual(firstSiblingStat.mtime, secondSiblingStat.mtime)
        XCTAssertEqual(firstSiblingStat.size, secondSiblingStat.size)
        XCTAssertEqual(firstSiblingStat.fingerprint, secondSiblingStat.fingerprint)
        let secondLoaded = await engine.telemetry(for: session)
        _ = try XCTUnwrap(secondLoaded)
        XCTAssertEqual(engine.parseCount, parseCountAfterFirst + 1)
    }

    func testDeepSeekFingerprintMemoSkipsUnchangedRehashAndRejectsMidHashRewrite() throws {
        let session = try makeDeepSeekSession(addSibling: true)
        let sibling = URL(fileURLWithPath: session.filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("session.v3.jsonl")
        var hashPasses = 0
        DeepSeekHarnessDiscovery.testManifestFingerprintHashObserver = { _ in
            hashPasses += 1
        }
        defer { DeepSeekHarnessDiscovery.testManifestFingerprintHashObserver = nil }

        XCTAssertNotNil(DeepSeekHarnessTelemetryReader.telemetryRevision(for: session))
        let firstPassCount = hashPasses
        XCTAssertGreaterThan(firstPassCount, 0)
        XCTAssertNotNil(DeepSeekHarnessTelemetryReader.telemetryRevision(for: session))
        XCTAssertEqual(hashPasses, firstPassCount)

        try Data("sibling-revision-updated".utf8).write(to: sibling, options: .atomic)
        var didRewriteDuringHash = false
        DeepSeekHarnessDiscovery.testManifestFingerprintHashObserver = { url in
            guard !didRewriteDuringHash,
                  url.standardizedFileURL == sibling.standardizedFileURL else { return }
            didRewriteDuringHash = true
            try? Data("mid-hash-rewrite".utf8).write(to: sibling, options: .atomic)
        }
        XCTAssertNil(DeepSeekHarnessTelemetryReader.telemetryRevision(for: session))
        XCTAssertTrue(didRewriteDuringHash)
    }

    func testDeepSeekFingerprintRejectsDescriptorABAReplacement() throws {
        let session = try makeDeepSeekSession(addSibling: true)
        let sibling = URL(fileURLWithPath: session.filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("session.v3.jsonl")
        let original = try Data(contentsOf: sibling)
        let replacement = Data("sibling-replacement".utf8)
        var didReplace = false
        var didRestore = false
        DeepSeekHarnessDiscovery.testManifestFingerprintBeforeOpenObserver = { url in
            guard url.standardizedFileURL == sibling.standardizedFileURL, !didReplace else { return }
            didReplace = true
            try? replacement.write(to: sibling, options: .atomic)
        }
        DeepSeekHarnessDiscovery.testManifestFingerprintAfterOpenObserver = { url in
            guard url.standardizedFileURL == sibling.standardizedFileURL,
                  didReplace, !didRestore else { return }
            didRestore = true
            try? original.write(to: sibling, options: .atomic)
        }
        defer {
            DeepSeekHarnessDiscovery.testManifestFingerprintBeforeOpenObserver = nil
            DeepSeekHarnessDiscovery.testManifestFingerprintAfterOpenObserver = nil
        }

        XCTAssertNil(DeepSeekHarnessTelemetryReader.telemetryRevision(for: session))
        XCTAssertTrue(didReplace)
        XCTAssertTrue(didRestore)
    }

    func testDeepSeekReadsTheSelectedSuccessorFromAnOlderSessionAnchor() async throws {
        let current = try makeDeepSeekSession()
        let currentURL = URL(fileURLWithPath: current.filePath)
        let staleAnchor = Session(
            id: current.id,
            source: .deepseekHarness,
            startTime: nil,
            endTime: nil,
            model: current.model,
            filePath: currentURL.deletingLastPathComponent()
                .appendingPathComponent("session.v3.jsonl").path,
            eventCount: 0,
            events: [])

        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let loadedTelemetry = await engine.telemetry(for: staleAnchor)
        let telemetry = try XCTUnwrap(loadedTelemetry)
        XCTAssertEqual(telemetry.source, .deepseekHarness)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 36)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "synthetic-model")
    }

    func testEngineUsesClineRegistryReaderForManifestAndMessagesPair() async throws {
        let session = try makeClineSession(messages: [
            [
                "role": "assistant",
                "id": "assistant-1",
                "ts": 1785615367000,
                "modelInfo": ["id": "cline-free/deepseek-v4.1-flash", "provider": "anthropic"],
                "metrics": [
                    "inputTokens": 31,
                    "cacheReadTokens": 11,
                    "cacheWriteTokens": 13,
                    "outputTokens": 17
                ]
            ],
            [
                "role": "assistant",
                "id": "assistant-2",
                "ts": 1785615368000,
                "modelInfo": ["id": "cline-free/muse-spark-1.3-contributor", "provider": "anthropic"],
                "metrics": [
                    "inputTokens": 5,
                    "cacheReadTokens": 3,
                    "cacheWriteTokens": 0,
                    "outputTokens": 5
                ]
            ]
        ])

        let scan = try XCTUnwrap(ClineTelemetryReader.loadTelemetry(for: session))
        let manifestBytes = try Data(contentsOf: URL(fileURLWithPath: session.filePath)).count
        let messagesBytes = try Data(contentsOf: ClineSessionDiscovery.messagesFile(
            forManifest: URL(fileURLWithPath: session.filePath))).count
        XCTAssertEqual(scan.bytesScanned, UInt64(manifestBytes + messagesBytes))

        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let loaded = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(loaded)

        XCTAssertEqual(telemetry.source, .cline)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 58)
        XCTAssertTrue(telemetry.usageSummary?.hasComponentBreakdown == true)
        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertEqual(telemetry.usageEvents.first?.contextInputTokens, 31)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "cline-free/deepseek-v4.1-flash")
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.initialConfiguration?.modelProvenance, .assistantRecord)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "cline-free/deepseek-v4.1-flash")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .sessionMetadata)
        XCTAssertEqual(telemetry.configurationChanges.count, 1)
    }

    func testClineFailsClosedWhenAnAssistantMetricRowIsMalformed() throws {
        let session = try makeClineSession(messages: [
            [
                "role": "assistant",
                "id": "assistant-1",
                "ts": 1785615367000,
                "modelInfo": ["id": "cline-free/deepseek-v4.1-flash", "provider": "anthropic"],
                "metrics": [
                    "inputTokens": 31,
                    "cacheReadTokens": 11,
                    "cacheWriteTokens": 13,
                    "outputTokens": 17
                ]
            ],
            [
                "role": "assistant",
                "id": "assistant-2",
                "ts": 1785615368000,
                "modelInfo": ["id": "cline-free/muse-spark-1.3-contributor", "provider": "anthropic"],
                "metrics": [
                    "inputTokens": 5,
                    "cacheReadTokens": 3,
                    "cacheWriteTokens": 0
                ]
            ]
        ])

        let scan = try XCTUnwrap(ClineTelemetryReader.loadTelemetry(for: session))
        XCTAssertEqual(scan.result.telemetry.usageSummary?.topLineTokens, 0)
        XCTAssertFalse(scan.result.telemetry.usageSummary?.hasComponentBreakdown ?? true)
        XCTAssertEqual(scan.result.telemetry.usageSummary?.unavailableReason,
                       "Cline assistant metric components are incomplete or malformed.")
        XCTAssertTrue(scan.result.telemetry.usageEvents.isEmpty)
        XCTAssertTrue(scan.result.telemetry.usageSlices.isEmpty)
        XCTAssertEqual(scan.result.telemetry.currentConfiguration?.model,
                       "cline-free/deepseek-v4.1-flash")
    }

    func testClineKeepsConfigurationWhenAssistantMetricsAreAbsent() throws {
        let session = try makeClineSession(messages: [[
            "role": "assistant",
            "id": "assistant-1",
            "ts": 1785615367000,
            "modelInfo": ["id": "cline-free/deepseek-v4.1-flash"]
        ]])

        let telemetry = try XCTUnwrap(ClineTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "cline-free/deepseek-v4.1-flash")
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Cline did not record usable token metrics.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testClineNormalizesInclusiveOpenAIInputBeforeAddingCacheComponents() throws {
        let session = try makeClineSession(messages: [[
            "role": "assistant",
            "id": "assistant-openai",
            "ts": 1785615367000,
            "modelInfo": ["id": "gpt-5.6", "provider": "openai"],
            "metrics": [
                "inputTokens": 31,
                "cacheReadTokens": 11,
                "cacheWriteTokens": 13,
                "outputTokens": 17
            ]
        ]])

        let telemetry = try XCTUnwrap(ClineTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 48)
        XCTAssertEqual(telemetry.usageEvents.first?.freshInputTokens, 7)
        XCTAssertEqual(telemetry.usageEvents.first?.contextInputTokens, 31)
    }

    func testClineNormalizesCacheComponentsRegardlessOfProviderLabel() throws {
        let session = try makeClineSession(messages: [[
            "role": "assistant",
            "id": "assistant-unknown-cache",
            "ts": 1785615367000,
            "modelInfo": ["id": "provider-model", "provider": "cline-pass"],
            "metrics": [
                "inputTokens": 31,
                "cacheReadTokens": 11,
                "cacheWriteTokens": 13,
                "outputTokens": 17
            ]
        ]])

        let telemetry = try XCTUnwrap(ClineTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 48)
        XCTAssertEqual(telemetry.usageEvents.first?.freshInputTokens, 7)
        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
    }

    func testClineFailsClosedWhenInclusiveInputCannotCoverCacheComponents() throws {
        let session = try makeClineSession(messages: [[
            "role": "assistant",
            "id": "assistant-cache-underflow",
            "ts": 1785615367000,
            "modelInfo": ["id": "provider-model", "provider": "cline-pass"],
            "metrics": [
                "inputTokens": 10,
                "cacheReadTokens": 11,
                "cacheWriteTokens": 13,
                "outputTokens": 17
            ]
        ]])

        let telemetry = try XCTUnwrap(ClineTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Cline assistant metric components are incomplete or malformed.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testClineFailsClosedWhenMetricsModelInfoLacksProvider() throws {
        let session = try makeClineSession(messages: [[
            "role": "assistant",
            "id": "assistant-no-provider",
            "ts": 1785615367000,
            "modelInfo": ["id": "provider-model"],
            "metrics": [
                "inputTokens": 7,
                "cacheReadTokens": 0,
                "cacheWriteTokens": 0,
                "outputTokens": 17
            ]
        ]])

        let telemetry = try XCTUnwrap(ClineTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Cline assistant model/provider metadata is incomplete or malformed.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testEngineUsesDroidRegistryReaderAndKeepsAggregateSettingsUsageUnattributed() async throws {
        let session = try makeDroidSession(
            lines: [
                #"{"type":"session_start","id":"droid-session","title":"Droid"}"#,
                #"{"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"Inspect"}]}}"#
            ],
            settings: [
                "model": "glm-4.7",
                "reasoningEffort": "none",
                "tokenUsage": [
                    "inputTokens": 7931,
                    "cacheReadTokens": 47360,
                    "cacheCreationTokens": 0,
                    "outputTokens": 658,
                    "thinkingTokens": 0
                ]
            ],
            model: "stale-session-model")

        let scan = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session))
        let transcriptBytes = try Data(contentsOf: URL(fileURLWithPath: session.filePath)).count
        let settingsBytes = try Data(contentsOf: URL(fileURLWithPath: session.filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("droid-session.settings.json")).count
        XCTAssertEqual(scan.bytesScanned, UInt64(transcriptBytes + settingsBytes))

        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let loadedTelemetry = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(loadedTelemetry)
        XCTAssertEqual(telemetry.source, .droid)
        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "glm-4.7")
        XCTAssertNotEqual(telemetry.currentConfiguration?.model, session.model)
        XCTAssertEqual(telemetry.currentConfiguration?.reasoningEffort, "none")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .sessionMetadata)
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["settings.tokenUsage"])
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid records aggregate token components without an audited disjoint total or request attribution.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
        XCTAssertNil(telemetry.costEstimate)
    }

    func testDroidScanBindsTheExactInputRevisionUsedByItsDescriptors() throws {
        let session = try makeDroidSession(
            lines: [#"{"type":"session_start","id":"droid-session"}"#],
            settings: ["model": "glm-4.7"])

        let expectedRevision = try XCTUnwrap(DroidTelemetryReader.telemetryRevision(for: session))
        let scan = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session))
        XCTAssertEqual(scan.inputRevision, expectedRevision)
    }

    func testDroidCancellationDuringScanReturnsNoPartialTelemetry() throws {
        let session = try makeDroidSession(
            lines: [
                #"{"type":"system","session_id":"droid-session","model":"glm-4.7"}"#,
                #"{"type":"completion","session_id":"droid-session","usage":{"total_tokens":42}}"#
            ])
        var checks = 0
        let scan = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session) {
            checks += 1
            return checks > 2
        })

        XCTAssertGreaterThan(scan.bytesScanned, 0)
        XCTAssertNil(scan.result.telemetry.usageSummary)
    }

    func testDroidDescriptorDriftReturnsRetryableRevisionResult() throws {
        let session = try makeDroidSession(
            lines: [
                #"{"type":"system","session_id":"droid-session","model":"glm-4.7"}"#,
                #"{"type":"completion","session_id":"droid-session","usage":{"total_tokens":42}}"#
            ])
        let transcriptURL = URL(fileURLWithPath: session.filePath)
        var checks = 0
        let scan = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session) {
            checks += 1
            if checks == 3, let writer = try? FileHandle(forWritingTo: transcriptURL) {
                writer.seekToEndOfFile()
                writer.write(Data("\n{\"type\":\"completion\",\"session_id\":\"droid-session\",\"usage\":{\"total_tokens\":7}}".utf8))
                try? writer.close()
            }
            return false
        })

        XCTAssertTrue(scan.revisionChanged)
        XCTAssertNil(scan.result.telemetry.usageSummary)
    }

    func testDroidRevisionChangesInvalidateEngineCacheForSidecarConfiguration() async throws {
        let session = try makeDroidSession(
            lines: [#"{"type":"session_start","id":"droid-session"}"#],
            settings: ["model": "glm-4.7"])
        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())

        let firstLoaded = await engine.telemetry(for: session)
        let first = try XCTUnwrap(firstLoaded)
        XCTAssertEqual(first.currentConfiguration?.model, "glm-4.7")

        try writeJSON(["model": "minimax-m2.5"],
                      to: directory.appendingPathComponent("droid-session.settings.json"))
        let secondLoaded = await engine.telemetry(for: session)
        let second = try XCTUnwrap(secondLoaded)
        XCTAssertEqual(second.currentConfiguration?.model, "minimax-m2.5")
    }

    func testDroidEngineRetriesWhenScannerObservesNewInputRevision() async throws {
        let session = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [
                #"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#,
                #"{"type":"completion","session_id":"stream-session","usage":{"total_tokens":42}}"#
            ])
        let mutation = DroidOneShotFileAppend(
            url: URL(fileURLWithPath: session.filePath),
            line: #"{"type":"system","session_id":"stream-session","model":"glm-4.7"}"#)
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            metrics: metrics,
            beforeTelemetryScan: { mutation.run() })

        let loaded = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(loaded)

        XCTAssertEqual(telemetry.currentConfiguration?.model, "glm-4.7")
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 2,
                       "a registry scanner revision mismatch must take the bounded engine retry")
        XCTAssertEqual(engine.parseCount, 1,
                       "the retry should count only the accepted Droid parse")
    }

    func testDroidModelChangeUsesProviderChangeProvenance() throws {
        let session = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [
                #"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#,
                #"{"type":"model_change","session_id":"stream-session","modelId":"glm-4.7"}"#
            ])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)

        XCTAssertEqual(telemetry.currentConfiguration?.model, "glm-4.7")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .providerChangeRecord)
        XCTAssertEqual(telemetry.configurationChanges.first?.provenance, .providerChangeRecord)
    }

    func testDroidPropagatesDescriptorReadErrorsAsUnavailable() throws {
        let session = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [#"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#])
        let scan = try XCTUnwrap(
            DroidTelemetryReader.loadTelemetryForTesting(for: session) { _, _ in
                throw NSError(domain: "DroidTelemetryTests", code: 1)
            })

        XCTAssertEqual(scan.result.telemetry.usageSummary?.unavailableReason,
                       "Droid token usage evidence is incomplete or malformed.")
        XCTAssertNil(scan.result.telemetry.currentConfiguration)
    }

    func testDroidStreamCompletionTotalIsDisplayedWithoutInventingAttribution() throws {
        let session = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [
                #"{"type":"system","session_id":"stream-session","timestamp":1767812640310,"model":"minimax-m2.5","cwd":"/tmp"}"#,
                #"{"type":"completion","session_id":"stream-session","timestamp":1767812644000,"finalText":"Done","usage":{"total_tokens":42}}"#
            ])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "minimax-m2.5")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.usageSummary?.recordedTotalTokens, 42)
        XCTAssertEqual(telemetry.usageSummary?.displayTotalTokens, 42)
        XCTAssertFalse(telemetry.usageSummary?.hasComponentBreakdown ?? true)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
    }

    func testDroidFailsClosedForMalformedSettingsTokenUsageButKeepsConfiguration() throws {
        let session = try makeDroidSession(
            lines: [#"{"type":"session_start","id":"droid-session"}"#],
            settings: [
                "model": "glm-4.7",
                "reasoningEffort": "none",
                "tokenUsage": [
                    "inputTokens": "not-a-number",
                    "cacheReadTokens": 10,
                    "cacheCreationTokens": 0,
                    "outputTokens": 2,
                    "thinkingTokens": 0
                ]
            ])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "glm-4.7")
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid token usage evidence is incomplete or malformed.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testDroidFailsClosedForMismatchedTranscriptIdentity() throws {
        let session = try makeDroidSession(
            id: "selected-session",
            lines: [#"{"type":"session_start","id":"different-session"}"#],
            settings: ["model": "glm-4.7"])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid telemetry files do not agree on the selected session identity.")
        XCTAssertNil(telemetry.currentConfiguration)
    }

    func testDroidFailsClosedForMismatchedSidecarBasename() throws {
        let session = try makeDroidSession(
            id: "selected-session",
            fileName: "different-session",
            lines: [#"{"type":"session_start","id":"selected-session"}"#],
            settings: ["model": "glm-4.7"])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid telemetry files do not agree on the selected session identity.")
        XCTAssertNil(telemetry.currentConfiguration)
    }

    func testDroidFailsClosedForConflictingSessionIdentityAliases() throws {
        let session = try makeDroidSession(
            lines: [#"{"type":"system","session_id":"droid-session","sessionId":"other-session","model":"glm-4.7"}"#])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid telemetry files do not agree on the selected session identity.")
    }

    func testDroidDoesNotPublishAValidCompletionTotalAlongsideMalformedEvidence() throws {
        let session = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [
                #"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#,
                #"{"type":"completion","session_id":"stream-session","usage":{"total_tokens":42}}"#,
                "not-json"
            ])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid token usage evidence is incomplete or malformed.")
        XCTAssertNil(telemetry.usageSummary?.recordedTotalTokens)
    }

    func testDroidFailsClosedForInvalidUTF8Evidence() throws {
        let session = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [#"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#])
        let data = Data(
            #"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#.utf8
        ) + Data([0x0A, 0xFF, 0x0A])
        try data.write(to: URL(fileURLWithPath: session.filePath), options: .atomic)

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid token usage evidence is incomplete or malformed.")
    }

    func testDroidRejectsBooleanTokenCounts() throws {
        let streamSession = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [
                #"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#,
                #"{"type":"completion","session_id":"stream-session","usage":{"total_tokens":true}}"#
            ])
        let streamTelemetry = try XCTUnwrap(
            DroidTelemetryReader.loadTelemetry(for: streamSession)?.result.telemetry)
        XCTAssertEqual(streamTelemetry.usageSummary?.unavailableReason,
                       "Droid token usage evidence is incomplete or malformed.")

        let interactiveSession = try makeDroidSession(
            lines: [#"{"type":"session_start","id":"droid-session"}"#],
            settings: [
                "model": "glm-4.7",
                "tokenUsage": [
                    "inputTokens": true,
                    "cacheReadTokens": 0,
                    "cacheCreationTokens": 0,
                    "outputTokens": 1,
                    "thinkingTokens": 0
                ]
            ])
        let interactiveTelemetry = try XCTUnwrap(
            DroidTelemetryReader.loadTelemetry(for: interactiveSession)?.result.telemetry)
        XCTAssertEqual(interactiveTelemetry.usageSummary?.unavailableReason,
                       "Droid token usage evidence is incomplete or malformed.")
    }

    func testDroidFailsClosedForConflictingCompletionTotalAliases() throws {
        let session = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [
                #"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#,
                #"{"type":"completion","session_id":"stream-session","usage":{"total_tokens":42,"totalTokens":7}}"#
            ])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid completion usage aliases disagree within one record.")
    }

    func testDroidFailsClosedWhenMultipleCompletionTotalsHaveAmbiguousScope() throws {
        let session = try makeDroidSession(
            id: "stream-session",
            fileName: "stream-log",
            lines: [
                #"{"type":"system","session_id":"stream-session","model":"minimax-m2.5"}"#,
                #"{"type":"completion","session_id":"stream-session","usage":{"total_tokens":42}}"#,
                #"{"type":"completion","session_id":"stream-session","usage":{"total_tokens":7}}"#
            ])

        let telemetry = try XCTUnwrap(DroidTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Droid recorded multiple completion usage summaries with ambiguous scope.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testKimiPrefersPerTurnUsageOverSessionSummary() {
        let lines = [
            #"{"type":"llm.request","model":"kimi-k2.7-code","thinkingEffort":"on","time":1785615365000}"#,
            #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"session","usage":{"inputOther":100,"inputCacheRead":200,"inputCacheCreation":0,"output":300},"time":1785615366000}"#,
            #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"turn","usage":{"inputOther":2,"inputCacheRead":3,"inputCacheCreation":4,"output":5},"time":1785615367000}"#
        ]

        let telemetry = KimiTelemetryAccumulator.accumulate(lines: lines)

        XCTAssertEqual(telemetry.initialConfiguration?.model, "kimi-k2.7-code")
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.currentConfiguration?.reasoningEffort, "on")
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["usage.record.turn"])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 14)
        XCTAssertEqual(telemetry.usageEvents.count, 1)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheWrite5mTokens, 4)
    }

    func testKimiFallsBackToValidSessionSummaryWhenTurnRowIsMalformed() {
        let lines = [
            #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"session","usage":{"inputOther":100,"inputCacheRead":200,"inputCacheCreation":4,"output":300},"time":1785615366000}"#,
            #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"turn","usage":{"inputOther":2,"inputCacheRead":3,"inputCacheCreation":4},"time":1785615367000}"#
        ]

        let telemetry = KimiTelemetryAccumulator.accumulate(lines: lines)

        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["usage.record.session"])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 604)
        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
        XCTAssertEqual(telemetry.usageEvents.count, 1)
    }

    func testKimiDistinguishesExplicitConfigChangesFromRequestObservations() {
        let lines = [
            #"{"type":"config.update","modelAlias":"kimi/kimi-k2.7-code","thinkingEffort":"on","time":1785615365000}"#,
            #"{"type":"llm.request","model":"kimi-k2.7-code-v2","thinkingEffort":"off","time":1785615366000}"#
        ]

        let telemetry = KimiTelemetryAccumulator.accumulate(lines: lines)

        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .providerChangeRecord)
        XCTAssertEqual(telemetry.configurationChanges.last?.provenance, .requestRecord)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "kimi-k2.7-code-v2")
    }

    func testKimiFailsClosedForMalformedOrUnscopedUsageRecords() {
        let validTurn = #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"turn","usage":{"inputOther":2,"inputCacheRead":3,"inputCacheCreation":4,"output":5},"time":1785615367000}"#
        let malformedRows = [
            #"{"type":"usage.record","usageScope":"turn","time":1785615368000}"#,
            #"{"type":"usage.record","usageScope":"unexpected","usage":{"inputOther":2,"inputCacheRead":3,"inputCacheCreation":4,"output":5},"time":1785615368000}"#,
            #"{"type":"usage.record","usageScope":"turn","usage":{"inputOther":2,"inputCacheRead":3,"inputCacheCreation":4,"output":5}"#
        ]

        for malformed in malformedRows {
            let telemetry = KimiTelemetryAccumulator.accumulate(lines: [validTurn, malformed])
            XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                           "Kimi usage.record components are incomplete or malformed.",
                           malformed)
            XCTAssertTrue(telemetry.usageEvents.isEmpty, malformed)
        }
    }

    func testAntigravityFailsClosedWhenAnyPlannerTokenRowIsMalformed() {
        let lines = [
            #"{"type":"PLANNER_RESPONSE","created_at":"2026-10-04T20:21:34Z","input_tokens":6073,"cache_read_tokens":9651,"output_tokens":240}"#,
            #"{"type":"PLANNER_RESPONSE","created_at":"2026-10-04T20:21:42Z","input_tokens":1420,"cache_read_tokens":15005}"#
        ]

        let telemetry = AntigravityTelemetryAccumulator.accumulate(lines: lines)

        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 0)
        XCTAssertFalse(telemetry.usageSummary?.hasComponentBreakdown ?? true)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Antigravity planner token components are incomplete or malformed.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testAntigravityFailsClosedForSyntacticallyInvalidPlannerRow() {
        let lines = [
            #"{"type":"PLANNER_RESPONSE","created_at":"2026-10-04T20:21:34Z","input_tokens":6073,"cache_read_tokens":9651,"output_tokens":240}"#,
            #"{"type":"PLANNER_RESPONSE","created_at":"2026-10-04T20:21:50Z","input_tokens":1420,"cache_read_tokens":15005,"output_tokens":240"#
        ]

        let telemetry = AntigravityTelemetryAccumulator.accumulate(lines: lines)

        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 0)
        XCTAssertFalse(telemetry.usageSummary?.hasComponentBreakdown ?? true)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Antigravity planner token components are incomplete or malformed.")
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testAntigravityBuildsPlannerTokenEventsWithoutInventingModel() {
        let lines = [
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"OK","created_at":"2026-10-04T20:21:34Z","input_tokens":6073,"cache_read_tokens":9651,"output_tokens":240}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"OK","created_at":"2026-10-04T20:21:42Z","input_tokens":1420,"cache_read_tokens":15005,"output_tokens":240}"#
        ]

        let telemetry = AntigravityTelemetryAccumulator.accumulate(lines: lines)

        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertNil(telemetry.currentConfiguration)
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["PLANNER_RESPONSE"])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 32_629)
        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertEqual(try XCTUnwrap(telemetry.usageEvents.first?.observedAt).timeIntervalSince1970,
                       1791145294,
                       accuracy: 0.001)
    }

    func testGrokExposesFirstObservedConfigurationAndHonestTokenGap() {
        let lines = [
            #"{"type":"assistant","content":"one","model_id":"grok-4.5","reasoning_effort":"high"}"#,
            #"{"type":"assistant","content":"two","model_id":"grok-4.1","reasoning_effort":"low"}"#
        ]

        let telemetry = GrokTelemetryAccumulator.accumulate(lines: lines)

        XCTAssertEqual(telemetry.initialConfiguration?.model, "grok-4.5")
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "grok-4.1")
        XCTAssertEqual(telemetry.configurationChanges.count, 2)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Grok transcript records do not expose token counts.")
        XCTAssertNil(TranscriptTelemetryPresentation.tokens(telemetry))
    }

    func testEngineUsesKimiRegistryProviderForARealFileRevision() async throws {
        let url = directory.appendingPathComponent("wire.jsonl")
        let line = #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"turn","usage":{"inputOther":7,"inputCacheRead":11,"inputCacheCreation":0,"output":13},"time":1785615367000}"#
        try line.write(to: url, atomically: true, encoding: .utf8)

        let session = Session(id: "kimi-session",
                              source: .kimi,
                              startTime: nil,
                              endTime: nil,
                              model: "kimi-k2.7-code",
                              filePath: url.path,
                              eventCount: 0,
                              events: [])
        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let value = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.source, .kimi)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 31)
        XCTAssertEqual(telemetry.usageEvents.first?.recordID, "usage.record:0")
    }

    func testEngineUsesAntigravityRegistryProviderForARealFileRevision() async throws {
        let url = directory.appendingPathComponent("transcript.jsonl")
        let line = #"{"type":"PLANNER_RESPONSE","created_at":"2026-10-04T20:21:34Z","input_tokens":7,"cache_read_tokens":11,"output_tokens":13}"#
        try line.write(to: url, atomically: true, encoding: .utf8)

        let session = Session(id: "antigravity-session",
                              source: .antigravity,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: url.path,
                              eventCount: 0,
                              events: [])
        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let value = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.source, .antigravity)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 31)
        XCTAssertEqual(telemetry.usageEvents.first?.recordID, "PLANNER_RESPONSE:0")
    }

    func testEngineUsesGrokRegistryProviderForARealFileRevision() async throws {
        let url = directory.appendingPathComponent("chat_history.jsonl")
        let line = #"{"type":"assistant","content":"one","model_id":"grok-4.5","reasoning_effort":"high"}"#
        try line.write(to: url, atomically: true, encoding: .utf8)

        let session = Session(id: "grok-session",
                              source: .grok,
                              startTime: nil,
                              endTime: nil,
                              model: "grok-4.5",
                              filePath: url.path,
                              eventCount: 0,
                              events: [])
        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let value = await engine.telemetry(for: session)
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.source, .grok)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "grok-4.5")
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "Grok transcript records do not expose token counts.")
    }
}
