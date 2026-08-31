import XCTest
import Darwin
@testable import AgentSessions

@MainActor
final class QwenIntegrationTests: XCTestCase {
    private let sessionID = "019f0000-0000-7000-8000-000000000001"
    private let invalidSessionID = "019f0000-0000-7000-8000-000000000002"
    private let compactSessionID = "019f0000000070008000000000000003"
    private let branchSessionID = "019f0000-0000-7000-8000-000000000004"
    private let gluedSessionID = "019f0000-0000-7000-8000-000000000005"

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fixtures/stage0/agents/qwen", isDirectory: true)
    }

    private var positiveFixture: URL {
        fixtureRoot.appendingPathComponent("\(sessionID).jsonl")
    }

    private var negativeFixture: URL {
        fixtureRoot.appendingPathComponent("\(invalidSessionID).jsonl")
    }

    private var compactFixture: URL {
        fixtureRoot.appendingPathComponent("\(compactSessionID).jsonl")
    }

    private var branchFixture: URL {
        fixtureRoot.appendingPathComponent("\(branchSessionID).jsonl")
    }

    private var gluedFixture: URL {
        fixtureRoot.appendingPathComponent("\(gluedSessionID).jsonl")
    }

    private let syntheticUnknownSessionID = "019f0000-0000-7000-8000-000000000006"

    /// SYNTHETIC, not a captured transcript. Modelled from the installed 0.22.3
    /// package source; exercises the parser and is not evidence about the format.
    private var syntheticUnknownRecordFixture: URL {
        fixtureRoot.appendingPathComponent("\(syntheticUnknownSessionID).jsonl")
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qwen-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func stage(_ fixture: URL, at destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixture, to: destination)
    }

    func testSyntheticFixtureParsesTranscriptToolsAndReasoning() throws {
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: positiveFixture))

        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.source, .qwen)
        XCTAssertEqual(session.model, "synthetic-model")
        XCTAssertEqual(session.cwd, "/tmp/as-qwen-fixture/project")
        XCTAssertEqual(session.repoName, "project")
        XCTAssertEqual(session.title, "Inspect the synthetic fixture.")
        XCTAssertEqual(session.eventCount, 4)
        XCTAssertEqual(session.events.count, 7)
        XCTAssertEqual(session.events.map(\.kind),
                       [.user, .meta, .tool_call, .tool_result, .assistant, .meta, .meta])
        XCTAssertEqual(session.events.filter { $0.kind == .user }.map(\.text),
                       ["Inspect the synthetic fixture."],
                       "hook context and runtime notifications must not become user turns")
        XCTAssertFalse(session.title.contains("hook context"))
        XCTAssertEqual(session.events.last?.text, "Synthetic background notification.")
        XCTAssertEqual(session.events.first(where: { $0.role == "reasoning" })?.text,
                       "I should read the synthetic file.")

        let call = try XCTUnwrap(session.events.first(where: { $0.kind == .tool_call }))
        XCTAssertEqual(call.toolName, "read_file")
        XCTAssertEqual(call.messageID, "synthetic-call-1")
        let inputData = try XCTUnwrap(call.toolInput?.data(using: .utf8))
        let input = try XCTUnwrap(
            JSONSerialization.jsonObject(with: inputData) as? [String: String]
        )
        XCTAssertEqual(input, ["path": "/tmp/as-qwen-fixture/project/README.md"])

        let result = try XCTUnwrap(session.events.first(where: { $0.kind == .tool_result }))
        XCTAssertEqual(result.toolName, "read_file")
        XCTAssertEqual(result.messageID, "synthetic-call-1")
        XCTAssertEqual(result.toolOutput, "Synthetic file contents.")
        XCTAssertTrue(session.hasToolCallEvent)
        XCTAssertTrue(UnifiedSessionIndexer.passesHasCommandsFilter(session))
    }

    func testPayloadlessUserProjectionStripsOnlyValidFinalHookContext() throws {
        let root = try makeTemporaryRoot()
        let open = "<qwen:user-prompt-submit-context>"
        let close = "</qwen:user-prompt-submit-context>"

        func parsedUserText(id: String, finalPart: String) throws -> Session {
            let url = root.appendingPathComponent("\(id).jsonl")
            var user = record(
                uuid: "synthetic-user",
                parentUUID: nil,
                sessionID: id,
                type: "user",
                timestamp: "2026-08-17T12:00:00.000Z",
                cwd: "/tmp/as-qwen-fixture/project",
                messageText: "Visible retained prompt."
            )
            user.removeValue(forKey: "systemPayload")
            user["message"] = [
                "role": "user",
                "parts": [
                    ["text": "Visible retained prompt."],
                    ["text": finalPart]
                ]
            ]
            try writeJSONLines([user], to: url)
            return try XCTUnwrap(QwenSessionParser.parseFileFull(at: url))
        }

        let validID = "019f0000-0000-7000-8000-000000000010"
        let valid = try parsedUserText(
            id: validID,
            finalPart: "  \(open)\nSynthetic injected context.\n\(close)  "
        )
        XCTAssertEqual(valid.events.first?.text, "Visible retained prompt.")
        XCTAssertEqual(valid.title, "Visible retained prompt.")
        XCTAssertFalse(valid.events.compactMap(\.text).joined().contains("Synthetic injected context"))

        let malformedID = "019f0000-0000-7000-8000-000000000011"
        let malformed = try parsedUserText(
            id: malformedID,
            finalPart: "\(open)Synthetic malformed context.\(close)"
        )
        XCTAssertTrue(malformed.events.first?.text?.contains("Synthetic malformed context") == true)

        let nestedID = "019f0000-0000-7000-8000-000000000012"
        let nested = try parsedUserText(
            id: nestedID,
            finalPart: "\(open)\nouter \(open) nested \(close)\n\(close)"
        )
        XCTAssertTrue(nested.events.first?.text?.contains("nested") == true)
    }

    /// Regression: a degenerate hook-context wrapper whose prefix and suffix overlap
    /// (they share the single newline) used to form an invalid Range and crash the whole
    /// indexing pass. It must parse as an empty-bodied wrapper instead.
    func testDegenerateHookContextWrapperParsesWithoutCrashing() throws {
        let root = try makeTemporaryRoot()
        let open = "<qwen:user-prompt-submit-context>"
        let close = "</qwen:user-prompt-submit-context>"

        func parsedUserText(id: String, finalPart: String) throws -> Session {
            let url = root.appendingPathComponent("\(id).jsonl")
            var user = record(
                uuid: "synthetic-user",
                parentUUID: nil,
                sessionID: id,
                type: "user",
                timestamp: "2026-08-17T12:00:00.000Z",
                cwd: "/tmp/as-qwen-fixture/project",
                messageText: "Visible retained prompt."
            )
            user.removeValue(forKey: "systemPayload")
            user["message"] = [
                "role": "user",
                "parts": [
                    ["text": "Visible retained prompt."],
                    ["text": finalPart]
                ]
            ]
            try writeJSONLines([user], to: url)
            return try XCTUnwrap(QwenSessionParser.parseFileFull(at: url))
        }

        // Shared-newline wrapper: 68 characters, prefix (34) + suffix (35) overlap.
        let sharedNewline = "\(open)\n\(close)"
        XCTAssertTrue(sharedNewline.hasPrefix("\(open)\n"))
        XCTAssertTrue(sharedNewline.hasSuffix("\n\(close)"))
        let degenerate = try parsedUserText(
            id: "019f0000-0000-7000-8000-000000000013",
            finalPart: sharedNewline
        )
        XCTAssertEqual(degenerate.events.first?.text, "Visible retained prompt.")

        // Near miss: a genuinely empty body (both newlines present) is also stripped.
        let emptyBody = try parsedUserText(
            id: "019f0000-0000-7000-8000-000000000014",
            finalPart: "\(open)\n\n\(close)"
        )
        XCTAssertEqual(emptyBody.events.first?.text, "Visible retained prompt.")

        // Near miss: a one-character body is a well-formed wrapper and is stripped.
        let oneCharBody = try parsedUserText(
            id: "019f0000-0000-7000-8000-000000000015",
            finalPart: "\(open)\nx\n\(close)"
        )
        XCTAssertEqual(oneCharBody.events.first?.text, "Visible retained prompt.")

        // Near miss: a whitespace-only body is likewise a well-formed wrapper.
        let whitespaceBody = try parsedUserText(
            id: "019f0000-0000-7000-8000-000000000016",
            finalPart: "\(open)\n   \n\(close)"
        )
        XCTAssertEqual(whitespaceBody.events.first?.text, "Visible retained prompt.")
    }

    func testLightweightParseKeepsSearchAndAnalyticsMetadata() throws {
        let session = try XCTUnwrap(QwenSessionParser.parseFile(at: positiveFixture))

        XCTAssertTrue(session.events.isEmpty)
        XCTAssertEqual(session.lightweightTitle, "Inspect the synthetic fixture.")
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-qwen-fixture/project")
        XCTAssertEqual(session.lightweightRepoName, "project")
        XCTAssertEqual(session.lightweightCommands, 1)
        XCTAssertEqual(session.eventCount, 4)
        XCTAssertNotNil(session.startTime)
        XCTAssertNotNil(session.endTime)
    }

    func testParserRejectsFilenameAndRecordSessionIDMismatch() {
        XCTAssertNil(QwenSessionParser.parseFile(at: negativeFixture))
        XCTAssertNil(QwenSessionParser.parseFileFull(at: negativeFixture))
    }

    func testCompactSessionIDAcceptedByParserAndDiscovery() throws {
        XCTAssertEqual(QwenSessionDiscovery.sessionID(forTranscript: compactFixture),
                       compactSessionID)
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: compactFixture))
        XCTAssertEqual(session.id, compactSessionID)
        XCTAssertEqual(session.title, "Inspect a compact-ID synthetic fixture.")

        let qwenHome = try makeTemporaryRoot()
        let transcript = qwenHome
            .appendingPathComponent("projects/synthetic-project/chats/\(compactSessionID).jsonl")
        try stage(compactFixture, at: transcript)
        let discovery = QwenSessionDiscovery(
            homeDirectory: URL(fileURLWithPath: "/virtual/home", isDirectory: true),
            environment: ["QWEN_HOME": qwenHome.path]
        )

        XCTAssertEqual(discovery.discoverSessionFiles().map(\.lastPathComponent),
                       ["\(compactSessionID).jsonl"])
    }

    func testActiveChainExcludesRewoundBranchAndAggregatesFragments() throws {
        let full = try XCTUnwrap(QwenSessionParser.parseFileFull(at: branchFixture))

        XCTAssertEqual(full.id, branchSessionID)
        XCTAssertEqual(full.customTitle, "Active branch title")
        XCTAssertEqual(full.title, "Active branch title")
        XCTAssertEqual(full.listTitle, "Active branch title")
        XCTAssertEqual(full.cwd, "/tmp/as-qwen-fixture/new-project")
        XCTAssertEqual(full.repoName, "new-project")
        XCTAssertEqual(full.model, "synthetic-active-model")
        XCTAssertEqual(full.eventCount, 4)
        XCTAssertEqual(full.events.count, 7)
        XCTAssertEqual(full.events.map(\.kind),
                       [.user, .meta, .user, .meta, .tool_call, .assistant, .meta])
        XCTAssertEqual(full.events.filter { $0.kind == .user }.compactMap(\.text),
                       ["Begin the active-chain fixture.", "Continue from the rewound branch."])
        XCTAssertEqual(full.events.first(where: { $0.role == "reasoning" })?.text,
                       "Reason over the active branch.")
        XCTAssertEqual(full.events.first(where: { $0.kind == .tool_call })?.toolName,
                       "read_file")
        XCTAssertEqual(full.events.first(where: { $0.kind == .assistant })?.text,
                       "Active branch answer.")
        XCTAssertFalse(full.events.compactMap(\.text).contains("Discarded branch answer."))
        XCTAssertFalse(full.events.compactMap(\.text).contains("Discarded branch title"))
        XCTAssertFalse(full.events.compactMap(\.text).contains {
            $0.contains("Synthetic artifact")
        })

        let lightweight = try XCTUnwrap(QwenSessionParser.parseFile(at: branchFixture))
        XCTAssertTrue(lightweight.events.isEmpty)
        XCTAssertEqual(lightweight.customTitle, full.customTitle)
        XCTAssertEqual(lightweight.lightweightCwd, full.cwd)
        XCTAssertEqual(lightweight.model, full.model)
        XCTAssertEqual(lightweight.eventCount, full.eventCount)
        XCTAssertEqual(lightweight.lightweightCommands, 1)
        XCTAssertEqual(lightweight.endTime, full.endTime)
    }

    func testReloadMergeMakesFullActiveChainMetadataAuthoritative() throws {
        let parsed = try XCTUnwrap(QwenSessionParser.parseFileFull(at: branchFixture))
        let stale = Session(
            id: parsed.id,
            source: .qwen,
            startTime: parsed.startTime,
            endTime: parsed.endTime,
            model: "discarded-branch-model",
            filePath: parsed.filePath,
            eventCount: 99,
            events: [],
            cwd: "/tmp/discarded-project",
            repoName: "discarded-project",
            lightweightTitle: "Discarded branch prompt",
            lightweightCommands: 42,
            customTitle: "Discarded branch title",
            surface: .cli
        )

        let merged = QwenSessionIndexer.mergeReloadedSession(current: stale, parsed: parsed)
        XCTAssertEqual(merged.eventCount, parsed.eventCount)
        XCTAssertEqual(merged.events.map(\.id), parsed.events.map(\.id))
        XCTAssertEqual(merged.lightweightTitle, "Begin the active-chain fixture.")
        XCTAssertEqual(merged.lightweightCommands, 1)
        XCTAssertEqual(merged.customTitle, "Active branch title")
        XCTAssertEqual(merged.lightweightCwd, "/tmp/as-qwen-fixture/new-project")
        XCTAssertEqual(merged.repoName, "new-project")
        XCTAssertEqual(merged.model, "synthetic-active-model")

        let cleared = Session(
            id: parsed.id,
            source: .qwen,
            startTime: parsed.startTime,
            endTime: parsed.endTime,
            model: nil,
            filePath: parsed.filePath,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            lightweightCommands: 0,
            customTitle: nil,
            surface: .cli
        )
        let clearedMerge = QwenSessionIndexer.mergeReloadedSession(current: stale, parsed: cleared)
        XCTAssertEqual(clearedMerge.eventCount, 0)
        XCTAssertNil(clearedMerge.lightweightTitle)
        XCTAssertEqual(clearedMerge.lightweightCommands, 0)
        XCTAssertNil(clearedMerge.customTitle)
        XCTAssertNil(clearedMerge.lightweightCwd)
        XCTAssertNil(clearedMerge.repoName)
        XCTAssertNil(clearedMerge.model)

        let failedParse = QwenSessionIndexer.mergeReloadedSession(current: stale, parsed: nil)
        XCTAssertEqual(failedParse.eventCount, stale.eventCount)
        XCTAssertEqual(failedParse.lightweightTitle, stale.lightweightTitle)
        XCTAssertEqual(failedParse.lightweightCommands, stale.lightweightCommands)
        XCTAssertEqual(failedParse.customTitle, stale.customTitle)
        XCTAssertEqual(failedParse.lightweightCwd, stale.lightweightCwd)
        XCTAssertEqual(failedParse.repoName, stale.repoName)
    }

    func testGluedObjectsRecoverWithoutAcceptingArbitraryJunk() throws {
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: gluedFixture))
        XCTAssertEqual(session.id, gluedSessionID)
        XCTAssertEqual(session.eventCount, 2)
        XCTAssertEqual(session.events.map(\.kind), [.user, .assistant])
        XCTAssertEqual(session.events.first?.text, #"Inspect {"glued": "objects"} safely."#)

        let physicalLine = try String(contentsOf: gluedFixture, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        XCTAssertEqual(QwenJSONL.objects(inPhysicalLine: physicalLine).count, 2)
        XCTAssertTrue(QwenJSONL.objects(inPhysicalLine: "junk\(physicalLine)").isEmpty)
        XCTAssertTrue(QwenJSONL.objects(inPhysicalLine: "\(physicalLine)junk").isEmpty)

        let objects = QwenJSONL.objects(inPhysicalLine: physicalLine)
        let first = try jsonString(objects[0])
        let second = try jsonString(objects[1])
        XCTAssertTrue(QwenJSONL.objects(inPhysicalLine: "\(first)junk\(second)").isEmpty)

        let qwenHome = try makeTemporaryRoot()
        let transcript = qwenHome
            .appendingPathComponent("projects/synthetic-project/chats/\(gluedSessionID).jsonl")
        try stage(gluedFixture, at: transcript)
        let discovery = QwenSessionDiscovery(
            homeDirectory: URL(fileURLWithPath: "/virtual/home", isDirectory: true),
            environment: ["QWEN_HOME": qwenHome.path]
        )
        XCTAssertEqual(discovery.discoverSessionFiles().map(\.lastPathComponent),
                       ["\(gluedSessionID).jsonl"])
    }

    func testActiveChainStopsAtMissingParentAndCycle() throws {
        let root = try makeTemporaryRoot()

        let gapID = "019f0000-0000-7000-8000-000000000006"
        let gapURL = root.appendingPathComponent("\(gapID).jsonl")
        try writeJSONLines([
            record(uuid: "gap-root", parentUUID: nil, sessionID: gapID, type: "user",
                   timestamp: "2026-08-17T15:00:00.000Z", cwd: "/tmp/gap-old",
                   messageText: "Earlier disconnected prompt."),
            record(uuid: "gap-leaf", parentUUID: "missing-parent", sessionID: gapID, type: "user",
                   timestamp: "2026-08-17T15:00:01.000Z", cwd: "/tmp/gap-current",
                   messageText: "Current gap prompt.")
        ], to: gapURL)
        let gap = try XCTUnwrap(QwenSessionParser.parseFileFull(at: gapURL))
        XCTAssertEqual(gap.events.compactMap(\.text), ["Current gap prompt."])
        XCTAssertEqual(gap.cwd, "/tmp/gap-current")

        let cycleID = "019f0000-0000-7000-8000-000000000007"
        let cycleURL = root.appendingPathComponent("\(cycleID).jsonl")
        try writeJSONLines([
            record(uuid: "cycle-a", parentUUID: "cycle-b", sessionID: cycleID, type: "user",
                   timestamp: "2026-08-17T15:01:00.000Z", cwd: "/tmp/cycle",
                   messageText: "Cycle A."),
            record(uuid: "cycle-b", parentUUID: "cycle-a", sessionID: cycleID, type: "assistant",
                   timestamp: "2026-08-17T15:01:01.000Z", cwd: "/tmp/cycle",
                   messageText: "Cycle B.")
        ], to: cycleURL)
        let cycle = try XCTUnwrap(QwenSessionParser.parseFileFull(at: cycleURL))
        XCTAssertEqual(cycle.events.map(\.kind), [.user, .assistant])
        XCTAssertEqual(cycle.eventCount, 2)
    }

    func testInvalidIdentityAndTypeRecordsCannotBecomeLeaf() throws {
        let root = try makeTemporaryRoot()
        let id = "019f0000-0000-7000-8000-000000000008"
        let url = root.appendingPathComponent("\(id).jsonl")
        var missingParent = record(uuid: "invalid-parent", parentUUID: nil, sessionID: id,
                                   type: "user", timestamp: "2026-08-17T15:02:01.000Z",
                                   cwd: "/tmp/invalid", messageText: "Must be skipped.")
        missingParent.removeValue(forKey: "parentUuid")
        try writeJSONLines([
            record(uuid: "valid-root", parentUUID: nil, sessionID: id, type: "user",
                   timestamp: "2026-08-17T15:02:00.000Z", cwd: "/tmp/valid",
                   messageText: "Valid prompt."),
            missingParent,
            record(uuid: "unknown-type", parentUUID: "valid-root", sessionID: id, type: "future_type",
                   timestamp: "2026-08-17T15:02:02.000Z", cwd: "/tmp/invalid",
                   messageText: "Unknown type.")
        ], to: url)

        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: url))
        // The unknown type is still excluded from the conversation and from the leaf.
        // It is no longer silent, though: it is reported once as a meta notice, which
        // is the only reason this assertion filters instead of comparing everything.
        XCTAssertEqual(
            session.events.filter { $0.kind != .meta }.compactMap(\.text),
            ["Valid prompt."]
        )
        XCTAssertEqual(
            session.events.filter { $0.role == QwenSessionParser.unrecognizedNoticeRole }.count,
            1
        )
        XCTAssertEqual(
            try XCTUnwrap(QwenSessionParser.unrecognizedRecordCensus(at: url)),
            ["future_type": 1]
        )
        XCTAssertEqual(session.cwd, "/tmp/valid")
    }

    func testLightweightParseReadsFinalLeafPastTwoHundredRecords() throws {
        let root = try makeTemporaryRoot()
        let id = "019f0000-0000-7000-8000-000000000009"
        let url = root.appendingPathComponent("\(id).jsonl")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = try XCTUnwrap(formatter.date(from: "2026-08-17T16:00:00.000Z"))

        var records: [[String: Any]] = []
        var parent: String?
        for index in 0..<201 {
            let uuid = String(format: "00000000-0000-4000-8000-%012d", index)
            var item = record(
                uuid: uuid,
                parentUUID: parent,
                sessionID: id,
                type: index == 0 ? "user" : "system",
                timestamp: formatter.string(from: base.addingTimeInterval(Double(index))),
                cwd: "/tmp/as-qwen-fixture/old-long-project",
                messageText: index == 0 ? "Long session opening prompt." : nil
            )
            if index > 0 { item["subtype"] = "ui_telemetry" }
            records.append(item)
            parent = uuid
        }
        let finalAssistant = "00000000-0000-4000-8000-000000000201"
        var assistant = record(
            uuid: finalAssistant,
            parentUUID: parent,
            sessionID: id,
            type: "assistant",
            timestamp: formatter.string(from: base.addingTimeInterval(201)),
            cwd: "/tmp/as-qwen-fixture/new-long-project",
            messageText: "Final answer after line 200."
        )
        assistant["model"] = "synthetic-after-200-model"
        records.append(assistant)
        var title = record(
            uuid: "00000000-0000-4000-8000-000000000202",
            parentUUID: finalAssistant,
            sessionID: id,
            type: "system",
            timestamp: formatter.string(from: base.addingTimeInterval(202)),
            cwd: "/tmp/as-qwen-fixture/new-long-project",
            messageText: nil
        )
        title["subtype"] = "custom_title"
        title["systemPayload"] = ["customTitle": "Title written after line 200", "titleSource": "manual"]
        records.append(title)
        try writeJSONLines(records, to: url)

        let session = try XCTUnwrap(QwenSessionParser.parseFile(at: url))
        XCTAssertTrue(session.events.isEmpty)
        XCTAssertEqual(session.eventCount, 2)
        XCTAssertEqual(session.lightweightTitle, "Long session opening prompt.")
        XCTAssertEqual(session.customTitle, "Title written after line 200")
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-qwen-fixture/new-long-project")
        XCTAssertEqual(session.model, "synthetic-after-200-model")
        XCTAssertEqual(session.endTime, base.addingTimeInterval(202))
    }

    func testDiscoveryUsesQwenHomeAndOnlyScansChatLocations() throws {
        let qwenHome = try makeTemporaryRoot()
        let projects = qwenHome.appendingPathComponent("projects", isDirectory: true)
        let active = projects.appendingPathComponent("synthetic-project/chats/\(sessionID).jsonl")
        let archived = projects.appendingPathComponent("synthetic-project/chats/archive/\(sessionID).jsonl")
        let invalid = projects.appendingPathComponent("synthetic-project/chats/\(invalidSessionID).jsonl")
        let unrelated = projects.appendingPathComponent("synthetic-project/workflows/\(sessionID).jsonl")
        let nestedLookalike = projects.appendingPathComponent(
            "synthetic-project/backup/chats/\(sessionID).jsonl"
        )
        try stage(positiveFixture, at: active)
        try stage(positiveFixture, at: archived)
        try stage(negativeFixture, at: invalid)
        try stage(positiveFixture, at: unrelated)
        try stage(positiveFixture, at: nestedLookalike)

        let discovery = QwenSessionDiscovery(
            homeDirectory: URL(fileURLWithPath: "/virtual/home", isDirectory: true),
            environment: ["QWEN_HOME": qwenHome.path]
        )

        XCTAssertEqual(discovery.sessionsRoot().path, projects.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(
            Set(found.map { $0.resolvingSymlinksInPath().path }),
            Set([active, archived].map { $0.resolvingSymlinksInPath().path })
        )
        XCTAssertEqual(QwenSessionDiscovery.transcriptLocation(for: active, projectsRoot: projects), .active)
        XCTAssertEqual(QwenSessionDiscovery.transcriptLocation(for: archived, projectsRoot: projects), .archived)
        XCTAssertNil(QwenSessionDiscovery.transcriptLocation(for: nestedLookalike, projectsRoot: projects))
    }

    func testAvailabilityUsesInjectedQwenHomeWithoutReadingTheRealMachine() {
        let suiteName = "QwenIntegrationTests-Availability-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = AvailabilityContext(
            defaults: defaults,
            fileProbe: FakeFileProbe(directories: ["/virtual/qwen-home/projects"]),
            homeDirectory: URL(fileURLWithPath: "/virtual/home", isDirectory: true),
            environment: ["QWEN_HOME": "/virtual/qwen-home"],
            detectBinary: { _ in false }
        )

        XCTAssertTrue(SessionSource.qwen.descriptor.isAvailable(context))
    }

    // MARK: - QWEN_HOME fallback to ~/.qwen
    //
    // 0.22.3 reads QWEN_HOME via getGlobalQwenDir(); 0.14.3 goes straight to
    // ~/.qwen. A 0.14.x user with QWEN_HOME exported for an unrelated reason
    // therefore has sessions we were not looking at. Provenance: discussion
    // QwenLM/qwen-code#10579 and docs/superpowers/plans/2026-08-31-qwen-0.22-format-brief.md.
    //
    // The trigger is "$QWEN_HOME/projects is not a directory", deliberately not
    // "the root yields no sessions": the descriptor's availability closure has to
    // apply the same rule and cannot afford to enumerate.

    private func defaultProjectsRoot(under home: URL) -> URL {
        home.appendingPathComponent(".qwen", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    func testQwenHomeWithoutProjectsDirectoryFallsBackToDefaultRoot() throws {
        let home = try makeTemporaryRoot()
        let qwenHome = try makeTemporaryRoot()
        let active = defaultProjectsRoot(under: home)
            .appendingPathComponent("synthetic-project/chats/\(sessionID).jsonl")
        try stage(positiveFixture, at: active)

        let discovery = QwenSessionDiscovery(
            homeDirectory: home,
            environment: ["QWEN_HOME": qwenHome.path]
        )

        XCTAssertEqual(discovery.sessionsRoot().path, defaultProjectsRoot(under: home).path)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 1)
    }

    func testQwenHomeWithProjectsDirectoryWinsOverDefaultRoot() throws {
        let home = try makeTemporaryRoot()
        let qwenHome = try makeTemporaryRoot()
        let qwenHomeProjects = qwenHome.appendingPathComponent("projects", isDirectory: true)
        try stage(
            positiveFixture,
            at: qwenHomeProjects.appendingPathComponent("synthetic-project/chats/\(sessionID).jsonl")
        )
        // Must be the compact fixture, not positiveFixture: hasValidHead rejects a
        // filename whose session ID does not match the record, so a mismatched decoy
        // would be skipped for the wrong reason and the test would pass vacuously.
        try stage(
            compactFixture,
            at: defaultProjectsRoot(under: home)
                .appendingPathComponent("other-project/chats/\(compactSessionID).jsonl")
        )

        let discovery = QwenSessionDiscovery(
            homeDirectory: home,
            environment: ["QWEN_HOME": qwenHome.path]
        )

        XCTAssertEqual(discovery.sessionsRoot().path, qwenHomeProjects.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first.flatMap { QwenSessionDiscovery.sessionID(forTranscript: $0) }, sessionID)
    }

    func testExplicitOverrideWinsOverQwenHomeAndDefaultRoot() throws {
        let home = try makeTemporaryRoot()
        let qwenHome = try makeTemporaryRoot()
        let override = try makeTemporaryRoot()
        try stage(
            positiveFixture,
            at: qwenHome.appendingPathComponent("projects/a-project/chats/\(sessionID).jsonl")
        )
        try stage(
            positiveFixture,
            at: defaultProjectsRoot(under: home).appendingPathComponent("b-project/chats/\(sessionID).jsonl")
        )
        let overrideProjects = override.appendingPathComponent("projects", isDirectory: true)
        try stage(
            compactFixture,
            at: overrideProjects.appendingPathComponent("c-project/chats/\(compactSessionID).jsonl")
        )

        let discovery = QwenSessionDiscovery(
            customRoot: override.path,
            homeDirectory: home,
            environment: ["QWEN_HOME": qwenHome.path]
        )

        XCTAssertEqual(discovery.sessionsRoot().path, overrideProjects.path)
        XCTAssertEqual(
            discovery.discoverSessionFiles().compactMap { QwenSessionDiscovery.sessionID(forTranscript: $0) },
            [compactSessionID]
        )
    }

    func testCustomRootPointingDirectlyAtAProjectsDirectoryStillResolves() throws {
        // The QWEN_HOME branch now requires a `projects` child. That narrowing must
        // not leak into customRoot, where pointing straight at a projects directory
        // is a supported shape.
        let home = try makeTemporaryRoot()
        let copiedRoot = try makeTemporaryRoot()
        try stage(
            positiveFixture,
            at: copiedRoot.appendingPathComponent("a-project/chats/\(sessionID).jsonl")
        )

        let discovery = QwenSessionDiscovery(
            customRoot: copiedRoot.path,
            homeDirectory: home,
            environment: [:]
        )

        XCTAssertEqual(discovery.sessionsRoot().path, copiedRoot.path)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 1)
    }

    func testEmptyQwenHomeProjectsRootDoesNotFallBackToDefaultRoot() throws {
        // Accepted limitation, pinned deliberately: only an enumeration trigger
        // would catch this, and the descriptor cannot afford one. A 0.22.x user
        // with a real-but-empty projects root should not silently be shown their
        // old 0.14.x sessions. Deleting this test is a decision, not a cleanup.
        let home = try makeTemporaryRoot()
        let qwenHome = try makeTemporaryRoot()
        let qwenHomeProjects = qwenHome.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: qwenHomeProjects, withIntermediateDirectories: true)
        try stage(
            positiveFixture,
            at: defaultProjectsRoot(under: home).appendingPathComponent("b-project/chats/\(sessionID).jsonl")
        )

        let discovery = QwenSessionDiscovery(
            homeDirectory: home,
            environment: ["QWEN_HOME": qwenHome.path]
        )

        XCTAssertEqual(discovery.sessionsRoot().path, qwenHomeProjects.path)
        XCTAssertTrue(discovery.discoverSessionFiles().isEmpty)
    }

    func testNoOverrideAndNoQwenHomeUsesDefaultRoot() throws {
        let home = try makeTemporaryRoot()
        try stage(
            positiveFixture,
            at: defaultProjectsRoot(under: home).appendingPathComponent("a-project/chats/\(sessionID).jsonl")
        )

        let discovery = QwenSessionDiscovery(homeDirectory: home, environment: [:])

        XCTAssertEqual(discovery.sessionsRoot().path, defaultProjectsRoot(under: home).path)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 1)
    }

    func testSharedResolverFallsBackOnlyWhenQwenHomeHasNoProjectsDirectory() {
        let home = URL(fileURLWithPath: "/virtual/home", isDirectory: true)
        let defaultRoot = "/virtual/home/.qwen/projects"

        func resolve(_ existing: Set<String>, environment: [String: String], customRoot: String? = nil) -> String {
            QwenSessionDiscovery.resolvedSessionsRoot(
                customRoot: customRoot,
                homeDirectory: home,
                environment: environment,
                directoryExists: { existing.contains($0.standardizedFileURL.path) }
            ).standardizedFileURL.path
        }

        // The case isAvailable cannot see: QWEN_HOME exists, its projects child does
        // not. Both roots exist, so the boolean is true either way — only the resolved
        // root distinguishes right from wrong, which is why this is tested directly.
        XCTAssertEqual(
            resolve([defaultRoot, "/virtual/qwen-home"], environment: ["QWEN_HOME": "/virtual/qwen-home"]),
            defaultRoot
        )
        XCTAssertEqual(
            resolve(
                [defaultRoot, "/virtual/qwen-home", "/virtual/qwen-home/projects"],
                environment: ["QWEN_HOME": "/virtual/qwen-home"]
            ),
            "/virtual/qwen-home/projects"
        )
        XCTAssertEqual(resolve([defaultRoot], environment: [:]), defaultRoot)
        // customRoot keeps <root>-itself acceptance; the QWEN_HOME narrowing must not leak.
        XCTAssertEqual(
            resolve([defaultRoot, "/virtual/copied"], environment: [:], customRoot: "/virtual/copied"),
            "/virtual/copied"
        )
        XCTAssertEqual(
            resolve(
                [defaultRoot, "/virtual/copied", "/virtual/copied/projects"],
                environment: [:],
                customRoot: "/virtual/copied"
            ),
            "/virtual/copied/projects"
        )
    }

    func testAvailabilityFallsBackToDefaultRootWhenQwenHomeIsNotADirectory() {
        // Pins that the descriptor actually routes through the shared resolver.
        // isAvailable can only observe the choice when the two candidate roots
        // differ in existence, hence a QWEN_HOME that is not present at all.
        let suiteName = "QwenIntegrationTests-Fallback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = AvailabilityContext(
            defaults: defaults,
            fileProbe: FakeFileProbe(directories: ["/virtual/home/.qwen/projects"]),
            homeDirectory: URL(fileURLWithPath: "/virtual/home", isDirectory: true),
            environment: ["QWEN_HOME": "/virtual/qwen-home"],
            detectBinary: { _ in false }
        )

        XCTAssertTrue(SessionSource.qwen.descriptor.isAvailable(context))
    }

    func testFallbackRootStaysResumeEligibleWithAnExplicitDefaultQwenHome() throws {
        // configuredStorageContext passes QWEN_HOME through the customRoot
        // parameter, so without matching treatment the fallback would surface
        // sessions and then mark every one of them browse-only.
        let home = try makeTemporaryRoot()
        let qwenHome = try makeTemporaryRoot()
        let active = defaultProjectsRoot(under: home)
            .appendingPathComponent("a-project/chats/\(sessionID).jsonl")
        try stage(positiveFixture, at: active)
        let suiteName = "QwenIntegrationTests-FallbackResume-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let context = QwenResumeEligibility.configuredStorageContext(
            defaults: defaults,
            homeDirectory: home,
            environment: ["QWEN_HOME": qwenHome.path]
        )

        XCTAssertEqual(context.projectsRoot.path, defaultProjectsRoot(under: home).standardizedFileURL.path)
        XCTAssertTrue(context.supportsResumeLookup)
        // Must name ~/.qwen explicitly rather than inherit the stale export: 0.22.x
        // honors QWEN_HOME and would otherwise look in the wrong place and report the
        // session as missing.
        XCTAssertEqual(
            context.environmentOverride,
            .qwenHome(home.appendingPathComponent(".qwen", isDirectory: true).standardizedFileURL)
        )

        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: active))
        XCTAssertTrue(QwenResumeEligibility.canResume(session, storageContext: context))
        XCTAssertFalse(session.isArchivedQwenSession(storageContext: context))
    }

    // MARK: - 0.22.x unrecognized records and fork capture

    func testSyntheticUnknownTypeAndSubtypeAreCountedAndSurfacedAsOneMetaEvent() throws {
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: syntheticUnknownRecordFixture))

        let census = try XCTUnwrap(
            QwenSessionParser.unrecognizedRecordCensus(at: syntheticUnknownRecordFixture)
        )
        XCTAssertEqual(census, ["session_checkpoint": 1, "system/quantum_flux": 1])
        // Same numbers without a second read of the file.
        XCTAssertEqual(QwenSessionParser.unrecognizedRecordCensus(in: session), census)

        // The unknown-type record stays out of the chain (upstream skips it too, so
        // matching keeps our leaf selection identical), but it is no longer silent.
        let notices = session.events.filter { $0.role == QwenSessionParser.unrecognizedNoticeRole }
        XCTAssertEqual(notices.count, 1)
        let noticeText = try XCTUnwrap(notices.first?.text)
        XCTAssertTrue(noticeText.contains("session_checkpoint"), noticeText)
        XCTAssertTrue(noticeText.contains("system/quantum_flux"), noticeText)
        XCTAssertEqual(notices.first?.kind, .meta)
        // The two fates are described separately: the unknown type is skipped, the
        // unknown subtype is displayed. One sentence covering both would be false.
        XCTAssertTrue(noticeText.contains("Skipped and not shown"), noticeText)
        XCTAssertTrue(noticeText.contains("Shown above as metadata"), noticeText)

        // Unknown subtype still renders as a non-destructive meta event with raw JSON.
        let unknownSubtype = try XCTUnwrap(session.events.first { $0.role == "quantum_flux" })
        XCTAssertEqual(unknownSubtype.kind, .meta)
        XCTAssertTrue(unknownSubtype.rawJSON.contains("quantum_flux"))
    }

    func testKnownUpstreamSubtypesAreNotReportedAsUnrecognized() throws {
        // ui_telemetry and notification are in 0.22.3's KNOWN_RECORD_SUBTYPES, so a
        // 0.14.3 fixture must stay silent — the notice only fires on genuine novelty.
        // XCTUnwrap, not == [:]: the census returns nil for a file it cannot open, so a
        // moved or mistyped fixture path must fail here rather than read as "clean".
        let census = try XCTUnwrap(QwenSessionParser.unrecognizedRecordCensus(at: positiveFixture))
        XCTAssertEqual(census, [:])
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: positiveFixture))
        XCTAssertTrue(session.events.allSatisfy { $0.role != QwenSessionParser.unrecognizedNoticeRole })

        // The nil-vs-empty distinction itself, so it cannot quietly regress.
        XCTAssertNil(
            QwenSessionParser.unrecognizedRecordCensus(
                at: fixtureRoot.appendingPathComponent("does-not-exist.jsonl")
            )
        )
    }

    func testForkedFromIsRetainedOnTheRecordItWasWrittenOn() throws {
        // Task 3 capture: forkedFrom is the only one of the subagent/fork fields that
        // appears in chats/ transcripts. agentId/agentName/isSidechain/agentRunId are
        // written to subagents/<sessionId>/agent-<agentId>.jsonl, which discovery
        // never reaches, so there is nothing to capture and nothing to re-thread.
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: syntheticUnknownRecordFixture))
        let forked = try XCTUnwrap(session.events.first { $0.kind == .user })
        XCTAssertTrue(forked.rawJSON.contains("\"forkedFrom\""), forked.rawJSON)
        XCTAssertTrue(forked.rawJSON.contains("019f0000-0000-7000-8000-000000000001"), forked.rawJSON)
    }

    func testArchiveBackfillCollapsesDuplicateSessionIDsWithoutTrapping() throws {
        let qwenHome = try makeTemporaryRoot()
        let projects = qwenHome.appendingPathComponent("projects", isDirectory: true)
        try stage(positiveFixture,
                  at: projects.appendingPathComponent("project-a/chats/\(sessionID).jsonl"))
        try stage(positiveFixture,
                  at: projects.appendingPathComponent("project-b/chats/archive/\(sessionID).jsonl"))

        let suiteName = "QwenIntegrationTests-Archive-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(qwenHome.path, forKey: QwenPreferencesKey.sessionsRootOverride)

        let backfill = try XCTUnwrap(SessionSource.qwen.descriptor.archive)
            .backfillURLs(defaults)
        XCTAssertEqual(backfill.count, 1)
        XCTAssertNotNil(backfill[sessionID])
    }

    func testCommandBuilderUsesAdvertisedResumeAndScopedContinueForms() throws {
        let builder = QwenResumeCommandBuilder()
        XCTAssertEqual(
            try builder.makeCoreCommand(strategy: .sessionByID(id: sessionID),
                                        binaryCommand: "qwen"),
            "qwen --resume \(sessionID)"
        )
        XCTAssertEqual(
            try builder.makeCoreCommand(strategy: .continueMostRecent,
                                        binaryCommand: "qwen"),
            "qwen --continue"
        )

        let package = try builder.makeCommand(
            strategy: .sessionByID(id: sessionID),
            binaryURL: URL(fileURLWithPath: "/opt/homebrew/bin/qwen"),
            workingDirectory: URL(fileURLWithPath: "/tmp/synthetic qwen project")
        )
        XCTAssertEqual(
            package.shellCommand,
            "cd '/tmp/synthetic qwen project' && '/opt/homebrew/bin/qwen' --resume '\(sessionID)'"
        )
    }

    func testRelocatedProjectsRootIsCarriedIntoCopyCommand() throws {
        let runtimeRoot = try makeTemporaryRoot()
        let projectsRoot = runtimeRoot.appendingPathComponent("projects", isDirectory: true)
        let activeURL = projectsRoot.appendingPathComponent("synthetic-project/chats/\(sessionID).jsonl")
        try stage(positiveFixture, at: activeURL)

        let suiteName = "QwenIntegrationTests-Relocated-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(runtimeRoot.path, forKey: QwenPreferencesKey.sessionsRootOverride)
        let context = QwenResumeEligibility.configuredStorageContext(
            defaults: defaults,
            homeDirectory: URL(fileURLWithPath: "/virtual/home", isDirectory: true),
            environment: [:]
        )
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: activeURL))

        XCTAssertEqual(context.projectsRoot, projectsRoot.standardizedFileURL)
        XCTAssertEqual(
            context.environmentOverride,
            .runtimeDirectory(runtimeRoot.standardizedFileURL)
        )
        XCTAssertTrue(context.supportsResumeLookup)
        XCTAssertTrue(QwenResumeEligibility.canCopyResumeCommand(session, storageContext: context))

        let core = try QwenResumeCommandBuilder().makeCoreCommand(
            strategy: .sessionByID(id: sessionID),
            binaryCommand: "qwen",
            storageEnvironmentOverride: context.environmentOverride
        )
        XCTAssertEqual(
            core,
            "QWEN_RUNTIME_DIR='\(runtimeRoot.standardizedFileURL.path)' qwen --resume \(sessionID)"
        )
    }

    func testInheritedQwenHomeIsPreservedForCopyAndAllLaunchCommandShapes() throws {
        let root = try makeTemporaryRoot()
        let qwenHome = root.appendingPathComponent("inherited qwen home", isDirectory: true)
        let projectsRoot = qwenHome.appendingPathComponent("projects", isDirectory: true)
        let activeURL = projectsRoot.appendingPathComponent("synthetic-project/chats/\(sessionID).jsonl")
        try stage(positiveFixture, at: activeURL)

        let suiteName = "QwenIntegrationTests-QwenHome-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = QwenResumeEligibility.configuredStorageContext(
            defaults: defaults,
            homeDirectory: URL(fileURLWithPath: "/virtual/home", isDirectory: true),
            environment: ["QWEN_HOME": qwenHome.path]
        )
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: activeURL))

        XCTAssertEqual(context.projectsRoot, projectsRoot.standardizedFileURL)
        XCTAssertEqual(context.environmentOverride, .qwenHome(qwenHome.standardizedFileURL))
        XCTAssertTrue(QwenResumeEligibility.canResume(session, storageContext: context))

        let builder = QwenResumeCommandBuilder()
        let core = try builder.makeCoreCommand(
            strategy: .sessionByID(id: sessionID),
            binaryCommand: "qwen",
            storageEnvironmentOverride: context.environmentOverride
        )
        XCTAssertEqual(
            core,
            "QWEN_HOME='\(qwenHome.standardizedFileURL.path)' qwen --resume \(sessionID)"
        )

        let package = try builder.makeCommand(
            strategy: .sessionByID(id: sessionID),
            binaryURL: URL(fileURLWithPath: "/opt/homebrew/bin/qwen"),
            workingDirectory: URL(fileURLWithPath: "/tmp/synthetic project"),
            storageEnvironmentOverride: context.environmentOverride
        )
        XCTAssertEqual(
            package.shellCommand,
            "cd '/tmp/synthetic project' && QWEN_HOME='\(qwenHome.standardizedFileURL.path)' '/opt/homebrew/bin/qwen' --resume '\(sessionID)'"
        )
        XCTAssertEqual(
            package.displayCommand,
            "QWEN_HOME='\(qwenHome.standardizedFileURL.path)' '/opt/homebrew/bin/qwen' --resume '\(sessionID)'"
        )

        let manualRuntime = root.appendingPathComponent("manual runtime", isDirectory: true)
        try stage(
            positiveFixture,
            at: manualRuntime.appendingPathComponent("projects/project/chats/\(sessionID).jsonl")
        )
        defaults.set(manualRuntime.path, forKey: QwenPreferencesKey.sessionsRootOverride)
        let preferenceWins = QwenResumeEligibility.configuredStorageContext(
            defaults: defaults,
            environment: ["QWEN_HOME": qwenHome.path]
        )
        XCTAssertEqual(
            preferenceWins.environmentOverride,
            .runtimeDirectory(manualRuntime.standardizedFileURL)
        )
    }

    func testRenamedCopiedProjectsRootIsBrowseOnly() throws {
        let root = try makeTemporaryRoot()
        let copiedRoot = root.appendingPathComponent("renamed-session-copy", isDirectory: true)
        let activeURL = copiedRoot.appendingPathComponent("synthetic-project/chats/\(sessionID).jsonl")
        try stage(positiveFixture, at: activeURL)

        let discovery = QwenSessionDiscovery(customRoot: copiedRoot.path, environment: [:])
        XCTAssertEqual(
            discovery.discoverSessionFiles().map { $0.resolvingSymlinksInPath().path },
            [activeURL.resolvingSymlinksInPath().path]
        )

        let suiteName = "QwenIntegrationTests-CopiedRoot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(copiedRoot.path, forKey: QwenPreferencesKey.sessionsRootOverride)
        let context = QwenResumeEligibility.configuredStorageContext(defaults: defaults, environment: [:])
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: activeURL))

        XCTAssertEqual(context.projectsRoot, copiedRoot.standardizedFileURL)
        XCTAssertNil(context.environmentOverride)
        XCTAssertFalse(context.supportsResumeLookup)
        XCTAssertFalse(QwenResumeEligibility.canResume(session, storageContext: context))
        XCTAssertFalse(QwenResumeEligibility.canCopyResumeCommand(session, storageContext: context))
    }

    func testResumeCommandUsesLatestActiveChainWorkingDirectory() throws {
        let session = try XCTUnwrap(QwenSessionParser.parseFileFull(at: branchFixture))
        let package = try QwenResumeCommandBuilder().makeCommand(
            strategy: .sessionByID(id: session.id),
            binaryURL: URL(fileURLWithPath: "/opt/homebrew/bin/qwen"),
            workingDirectory: session.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )

        XCTAssertEqual(
            package.shellCommand,
            "cd '/tmp/as-qwen-fixture/new-project' && '/opt/homebrew/bin/qwen' --resume '\(branchSessionID)'"
        )
    }

    func testArchivedQwenSessionsAreNotResumeOrCopyEligible() throws {
        let root = try makeTemporaryRoot()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let activeURL = projectsRoot.appendingPathComponent("project/chats/\(sessionID).jsonl")
        let archivedURL = projectsRoot.appendingPathComponent("project/chats/archive/\(sessionID).jsonl")
        let misleadingURL = projectsRoot.appendingPathComponent("project/archive/chats/\(sessionID).jsonl")
        let appArchiveURL = root.appendingPathComponent(
            "AgentSessions/Archives/qwen/\(sessionID)/data/\(sessionID).jsonl"
        )
        try stage(positiveFixture, at: activeURL)
        try stage(positiveFixture, at: archivedURL)
        try stage(positiveFixture, at: misleadingURL)
        try stage(positiveFixture, at: appArchiveURL)

        let active = try XCTUnwrap(QwenSessionParser.parseFileFull(at: activeURL))
        let archived = try XCTUnwrap(QwenSessionParser.parseFileFull(at: archivedURL))
        let misleading = try XCTUnwrap(QwenSessionParser.parseFileFull(at: misleadingURL))
        let appArchive = try XCTUnwrap(QwenSessionParser.parseFileFull(at: appArchiveURL))
        let context = QwenResumeEligibility.StorageContext(
            projectsRoot: projectsRoot,
            environmentOverride: nil,
            supportsResumeLookup: true
        )

        XCTAssertFalse(active.isArchivedQwenSession(storageContext: context))
        XCTAssertTrue(QwenResumeEligibility.canResume(active, storageContext: context))
        XCTAssertTrue(QwenResumeEligibility.canCopyResumeCommand(active, storageContext: context))

        XCTAssertTrue(archived.isArchivedQwenSession(storageContext: context))
        XCTAssertFalse(QwenResumeEligibility.canResume(archived, storageContext: context))
        XCTAssertFalse(QwenResumeEligibility.canCopyResumeCommand(archived, storageContext: context))

        XCTAssertTrue(misleading.isArchivedQwenSession(storageContext: context))
        XCTAssertFalse(QwenResumeEligibility.canResume(misleading, storageContext: context))
        XCTAssertFalse(QwenResumeEligibility.canCopyResumeCommand(misleading, storageContext: context))

        XCTAssertTrue(appArchive.isArchivedQwenSession(storageContext: context))
        XCTAssertFalse(QwenResumeEligibility.canResume(appArchive, storageContext: context))
        XCTAssertFalse(QwenResumeEligibility.canCopyResumeCommand(appArchive, storageContext: context))
    }

    func testCLIProbeParsesQwen02113HelpFlagsAsWholeTokens() {
        let binaryPath = makeTemporaryExecutable()
        let executor = MockCommandExecutor()
        executor.responses[[binaryPath, "--version"]] = .init(
            stdout: "0.21.13", stderr: "", exitCode: 0
        )
        executor.responses[[binaryPath, "--help"]] = .init(
            stdout: "--resume <id>  Resume a session\n--continue  Continue the latest session",
            stderr: "",
            exitCode: 0
        )

        switch QwenCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let result):
            XCTAssertEqual(result.versionString, "0.21.13")
            XCTAssertTrue(result.supportsResume)
            XCTAssertTrue(result.supportsContinue)
        case .failure(let error):
            XCTFail("unexpected probe failure: \(error)")
        }
    }

    /// Qwen is a `#!/usr/bin/env node` script, so a Finder-launched app — whose
    /// PATH has no Homebrew in it — cannot run the probe at all. See #58, which
    /// reported this for Pi.
    func testCLIProbeRunsQwenWithAPathThatCanResolveNode() {
        let binaryPath = makeTemporaryExecutable()
        let executor = MockCommandExecutor()
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        let envFailure = CommandResult(stdout: "", stderr: "env: node: No such file or directory\n", exitCode: 127)
        executor.responses[[binaryPath, "--version"]] = envFailure
        executor.responses[[binaryPath, "--help"]] = envFailure

        _ = QwenCLIEnvironment(executor: executor).probe(customPath: binaryPath)

        let retried = executor.environments(forCommandContaining: "--help").compactMap { $0?["PATH"] }
        XCTAssertFalse(retried.isEmpty, "a failed probe must be retried with a widened PATH")
        XCTAssertTrue(retried.allSatisfy { $0.contains("/opt/homebrew/bin") },
                      "retry PATH lost the login-shell entries: \(retried)")
    }

    /// The #58 case end to end: a Node CLI that cannot start under the PATH a
    /// Finder-launched app inherits, and does start once the probe widens it.
    /// The other tests pin "a retry happened" and "a retry can succeed"
    /// separately — this is the one that fails if the two do not join up.
    func testCLIProbeRecoversUnderTheWidenedPath() {
        let binaryPath = makeTemporaryExecutable()
        let executor = MockCommandExecutor()
        executor.needsHomebrewOnPath = true
        executor.loginShellPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        executor.responses[[binaryPath, "--version"]] = .init(stdout: "0.21.13", stderr: "", exitCode: 0)
        executor.responses[[binaryPath, "--help"]] = .init(stdout: "--resume <id>\n--continue", stderr: "", exitCode: 0)

        switch QwenCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let result):
            XCTAssertEqual(result.versionString, "0.21.13")
            XCTAssertTrue(result.supportsResume)
            XCTAssertTrue(result.supportsContinue)
        case .failure(let error):
            XCTFail("Finder-launched probe never recovered: \(error)")
        }
    }

    /// A probe that never executed is not evidence that Qwen lacks resume flags.
    /// Recording it as "supports nothing" is what makes the resume actions go
    /// quiet, and the verdict is cached.
    func testCLIProbeFailsLoudlyWhenQwenCouldNotExecute() {
        let binaryPath = makeTemporaryExecutable()
        let executor = MockCommandExecutor()
        let envFailure = CommandResult(stdout: "", stderr: "env: node: No such file or directory\n", exitCode: 127)
        executor.responses[[binaryPath, "--version"]] = envFailure
        executor.responses[[binaryPath, "--help"]] = envFailure

        switch QwenCLIEnvironment(executor: executor).probe(customPath: binaryPath) {
        case .success(let result):
            XCTFail("expected failure, got success with resume=\(result.supportsResume)")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("node"),
                          "error should surface the real reason: \(error.localizedDescription)")
        }
    }

    /// A cache written by a probe that could not execute Qwen names a real
    /// binary with every capability false. Trusting it disables Copy Resume
    /// Command forever, since the cache is only refreshed while the resolved
    /// path is empty.
    func testCopyPlanDiscardsACachedBinaryThatAdvertisesNoCapabilities() throws {
        let suiteName = "QwenIntegrationTests-PoisonedCache-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = QwenSettings.makeForTesting(defaults: defaults)

        settings.setResolvedBinary(makeTemporaryExecutable(), supportsResume: false, supportsContinue: false)

        let plan = try XCTUnwrap(settings.copyCommandPlan(sessionID: sessionID),
                                 "a failed probe must not silently disable Copy Resume Command")
        XCTAssertEqual(plan.binary, QwenCLIEnvironment.binaryName)
        XCTAssertTrue(settings.resolvedBinaryPath.isEmpty, "the unusable cache entry should be cleared")
    }

    /// 5.0 stored a resolved path with every capability false whenever the probe
    /// could not execute the CLI. An auto-detected entry heals on read — the
    /// reader drops it and the plan falls back to a bare `qwen`. A custom path
    /// has no such fallback and nothing that would reprobe it, so the entry has
    /// to be dropped at load instead, before anything reads it.
    func testACapabilityFreeCustomCacheFromAnOlderBuildIsHealedAtLoad() {
        let suiteName = "QwenIntegrationTests-LegacyCustomPoisoned-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let binaryPath = makeTemporaryExecutable()

        defaults.set(binaryPath, forKey: QwenSettings.Keys.binaryPath)
        defaults.set(binaryPath, forKey: QwenSettings.Keys.resolvedBinaryPath)
        defaults.set(false, forKey: QwenSettings.Keys.resolvedSupportsResume)
        defaults.set(false, forKey: QwenSettings.Keys.resolvedSupportsContinue)

        let settings = QwenSettings.makeForTesting(defaults: defaults)

        XCTAssertEqual(settings.binaryPath, binaryPath, "the custom selection itself must survive")
        XCTAssertTrue(settings.resolvedBinaryPath.isEmpty, "the dead entry must not outlive the load")
        XCTAssertEqual(defaults.string(forKey: QwenSettings.Keys.resolvedBinaryPath), "")
    }

    func testCustomBinaryCopyPlanUsesOnlyCapabilitiesProbedForThatPath() throws {
        let suiteName = "QwenIntegrationTests-CustomCapabilities-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let binaryPath = makeTemporaryExecutable()
        let settings = QwenSettings.makeForTesting(defaults: defaults)

        settings.setBinaryPath(binaryPath)
        XCTAssertNil(settings.copyCommandPlan(sessionID: sessionID),
                     "a custom executable is not resume-capable until its exact path is probed")

        settings.setResolvedBinary(binaryPath, supportsResume: false, supportsContinue: true)
        let continuePlan = try XCTUnwrap(settings.copyCommandPlan(sessionID: sessionID))
        XCTAssertEqual(continuePlan.binary, binaryPath)
        guard case .continueMostRecent = continuePlan.strategy else {
            return XCTFail("custom binary without --resume must fall back to --continue")
        }

        let reloaded = QwenSettings.makeForTesting(defaults: defaults)
        let persistedPlan = try XCTUnwrap(reloaded.copyCommandPlan(sessionID: sessionID))
        guard case .continueMostRecent = persistedPlan.strategy else {
            return XCTFail("custom binary capabilities must survive settings reconstruction")
        }

        settings.setResolvedBinary(binaryPath, supportsResume: true, supportsContinue: false)
        let resumePlan = try XCTUnwrap(settings.copyCommandPlan(sessionID: sessionID))
        guard case .sessionByID(let id) = resumePlan.strategy else {
            return XCTFail("probed --resume support must select the session ID")
        }
        XCTAssertEqual(id, sessionID)
        XCTAssertNil(settings.copyCommandPlan(sessionID: "   "),
                     "--resume alone cannot reopen an unidentified session")

        settings.setResolvedBinary(binaryPath, supportsResume: false, supportsContinue: false)
        XCTAssertNil(settings.copyCommandPlan(sessionID: sessionID))

        let replacement = makeTemporaryExecutable()
        settings.setResolvedBinary(binaryPath, supportsResume: true, supportsContinue: true)
        settings.setBinaryPath(replacement)
        XCTAssertNil(settings.copyCommandPlan(sessionID: sessionID),
                     "changing the custom path must invalidate the previous executable's flags")
    }

    func testCurrentCustomProbeSuccessPersistsCapabilities() {
        let suiteName = "QwenIntegrationTests-ProbeCurrent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = QwenSettings.makeForTesting(defaults: defaults)
        let customPath = "/tmp/as-qwen-current"

        settings.setBinaryPath(customPath)
        let request = settings.currentProbeRequest()
        let acceptance = settings.acceptProbeCompletion(
            qwenProbeSuccess(path: customPath, supportsResume: true, supportsContinue: false),
            for: request
        )

        XCTAssertEqual(acceptance, .accepted)
        XCTAssertEqual(settings.resolvedBinaryPath, customPath)
        XCTAssertTrue(settings.resolvedSupportsResume)
        XCTAssertFalse(settings.resolvedSupportsContinue)
    }

    func testStaleAutoWarmSuccessCannotOverwriteCustomSelection() {
        let suiteName = "QwenIntegrationTests-ProbeWarmRace-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = QwenSettings.makeForTesting(defaults: defaults)
        let staleAutoRequest = settings.currentProbeRequest()
        let customPath = "/tmp/as-qwen-custom-after-warm"

        settings.setBinaryPath(customPath)
        let currentRequest = settings.currentProbeRequest()
        let acceptance = settings.acceptProbeCompletion(
            qwenProbeSuccess(path: "/opt/synthetic/bin/qwen",
                             supportsResume: true,
                             supportsContinue: true),
            for: staleAutoRequest
        )

        XCTAssertEqual(acceptance, .stale(reprobe: currentRequest))
        XCTAssertEqual(settings.binaryPath, customPath)
        XCTAssertEqual(settings.resolvedBinaryPath, "")
        XCTAssertFalse(settings.resolvedSupportsResume)
        XCTAssertFalse(settings.resolvedSupportsContinue)
    }

    func testStaleProbeFailureCannotClearCurrentSuccess() {
        let suiteName = "QwenIntegrationTests-ProbeFailureRace-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = QwenSettings.makeForTesting(defaults: defaults)
        let oldPath = "/tmp/as-qwen-old-selection"
        let currentPath = "/tmp/as-qwen-current-selection"

        settings.setBinaryPath(oldPath)
        let staleRequest = settings.currentProbeRequest()
        settings.setBinaryPath(currentPath)
        let currentRequest = settings.currentProbeRequest()
        XCTAssertEqual(
            settings.acceptProbeCompletion(
                qwenProbeSuccess(path: currentPath,
                                 supportsResume: false,
                                 supportsContinue: true),
                for: currentRequest
            ),
            .accepted
        )

        let staleFailure = settings.acceptProbeCompletion(
            .failure(.binaryNotFound),
            for: staleRequest
        )
        XCTAssertEqual(staleFailure, .stale(reprobe: currentRequest))
        XCTAssertEqual(settings.resolvedBinaryPath, currentPath)
        XCTAssertFalse(settings.resolvedSupportsResume)
        XCTAssertTrue(settings.resolvedSupportsContinue)
    }

    func testProbeGenerationRejectsABACompletionAndRequestsFreshProbe() {
        let suiteName = "QwenIntegrationTests-ProbeABA-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = QwenSettings.makeForTesting(defaults: defaults)
        let firstPath = "/tmp/as-qwen-selection-a"
        let secondPath = "/tmp/as-qwen-selection-b"

        settings.setBinaryPath(firstPath)
        let staleFirstRequest = settings.currentProbeRequest()
        settings.setBinaryPath(secondPath)
        settings.setBinaryPath(firstPath)
        let currentFirstRequest = settings.currentProbeRequest()

        XCTAssertNotEqual(staleFirstRequest.generation, currentFirstRequest.generation)
        XCTAssertEqual(staleFirstRequest.binaryOverride, currentFirstRequest.binaryOverride)
        XCTAssertEqual(
            settings.acceptProbeCompletion(
                qwenProbeSuccess(path: firstPath,
                                 supportsResume: true,
                                 supportsContinue: true),
                for: staleFirstRequest
            ),
            .stale(reprobe: currentFirstRequest)
        )
        XCTAssertEqual(settings.resolvedBinaryPath, "")
    }

    func testResumeCoordinatorRefusesUnscopedContinue() async {
        let launcher = MockLauncher()
        let environment = MockEnvironment(result: .success(.init(
            versionString: "0.21.13",
            binaryURL: URL(fileURLWithPath: "/opt/homebrew/bin/qwen"),
            supportsResume: false,
            supportsContinue: true
        )))
        let coordinator = QwenResumeCoordinator(
            environment: environment,
            builder: QwenResumeCommandBuilder(),
            launcher: launcher
        )

        let result = await coordinator.resumeInTerminal(input: .init(
            sessionID: sessionID,
            workingDirectory: nil,
            binaryOverride: nil
        ))

        XCTAssertFalse(result.launched)
        XCTAssertEqual(result.error,
                       "No working directory for this session, so --continue could resume an unrelated one.")
        XCTAssertTrue(launcher.commands.isEmpty)
    }

    func testResumeCoordinatorLaunchesExactSessionByID() async {
        let launcher = MockLauncher()
        let environment = MockEnvironment(result: .success(.init(
            versionString: "0.21.13",
            binaryURL: URL(fileURLWithPath: "/opt/homebrew/bin/qwen"),
            supportsResume: true,
            supportsContinue: true
        )))
        let coordinator = QwenResumeCoordinator(
            environment: environment,
            builder: QwenResumeCommandBuilder(),
            launcher: launcher
        )

        let result = await coordinator.resumeInTerminal(input: .init(
            sessionID: sessionID,
            workingDirectory: URL(fileURLWithPath: "/tmp/synthetic-project"),
            binaryOverride: nil,
            storageEnvironmentOverride: .runtimeDirectory(
                URL(fileURLWithPath: "/tmp/synthetic qwen runtime")
            )
        ))

        XCTAssertTrue(result.launched)
        XCTAssertNil(result.error)
        XCTAssertEqual(
            launcher.commands,
            ["cd '/tmp/synthetic-project' && QWEN_RUNTIME_DIR='/tmp/synthetic qwen runtime' '/opt/homebrew/bin/qwen' --resume '\(sessionID)'"]
        )
    }

    private final class MockCommandExecutor: CommandExecuting {
        var responses: [[String]: CommandResult] = [:]
        var loginShellPATH = "/usr/bin:/bin"
        /// Models a `#!/usr/bin/env node` CLI: it cannot start unless the
        /// environment it is given can find its interpreter.
        var needsHomebrewOnPath = false
        private(set) var calls: [(command: [String], environment: [String: String]?)] = []

        func run(_ command: [String], cwd: URL?) throws -> CommandResult {
            try run(command, cwd: cwd, environment: nil)
        }

        /// Answers the login-shell discovery call whatever exact script the
        /// probe sends, and records the environment each command was given.
        func run(_ command: [String], cwd: URL?, environment: [String: String]?) throws -> CommandResult {
            calls.append((command, environment))
            if command.count == 3, command[1] == "-lic" {
                return .init(
                    stdout: "\(CLIProbeEnvironment.pathMarker.begin)\(loginShellPATH)\(CLIProbeEnvironment.pathMarker.end)\n",
                    stderr: "",
                    exitCode: 0
                )
            }
            if needsHomebrewOnPath, environment?["PATH"]?.contains("/opt/homebrew/bin") != true {
                return .init(stdout: "", stderr: "env: node: No such file or directory\n", exitCode: 127)
            }
            return responses[command] ?? .init(stdout: "", stderr: "", exitCode: 0)
        }

        func environments(forCommandContaining argument: String) -> [[String: String]?] {
            calls.filter { $0.command.contains(argument) }.map(\.environment)
        }
    }

    private func qwenProbeSuccess(
        path: String,
        supportsResume: Bool,
        supportsContinue: Bool
    ) -> Result<QwenCLIEnvironment.ProbeResult, QwenCLIEnvironment.ProbeError> {
        .success(.init(
            versionString: "0.21.13-synthetic",
            binaryURL: URL(fileURLWithPath: path),
            supportsResume: supportsResume,
            supportsContinue: supportsContinue
        ))
    }

    private final class MockEnvironment: QwenCLIEnvironmentProviding, @unchecked Sendable {
        let result: Result<QwenCLIEnvironment.ProbeResult, QwenCLIEnvironment.ProbeError>

        init(result: Result<QwenCLIEnvironment.ProbeResult, QwenCLIEnvironment.ProbeError>) {
            self.result = result
        }

        func probe(customPath: String?)
            -> Result<QwenCLIEnvironment.ProbeResult, QwenCLIEnvironment.ProbeError> {
            result
        }
    }

    private final class MockLauncher: QwenTerminalLaunching {
        private(set) var commands: [String] = []

        func launchInTerminal(_ package: QwenResumeCommandBuilder.CommandPackage) async throws {
            commands.append(package.shellCommand)
        }
    }

    private func makeTemporaryExecutable() -> String {
        let file = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qwen-probe-\(UUID().uuidString)")
        try? "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        _ = chmod(file.path, 0o755)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }

    private func record(uuid: String,
                        parentUUID: String?,
                        sessionID: String,
                        type: String,
                        timestamp: String,
                        cwd: String,
                        messageText: String?) -> [String: Any] {
        var object: [String: Any] = [
            "uuid": uuid,
            "parentUuid": parentUUID ?? NSNull(),
            "sessionId": sessionID,
            "timestamp": timestamp,
            "type": type,
            "cwd": cwd,
            "version": "0.21.13"
        ]
        if let messageText {
            object["message"] = [
                "role": type == "assistant" ? "model" : "user",
                "parts": [["text": messageText]]
            ]
            if type == "user" {
                object["systemPayload"] = ["displayText": messageText]
            }
        }
        return object
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map(jsonString).joined(separator: "\n") + "\n"
        try lines.write(to: url, atomically: true, encoding: .utf8)
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
