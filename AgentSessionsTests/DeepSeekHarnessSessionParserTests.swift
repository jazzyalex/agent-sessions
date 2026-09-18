import Foundation
import XCTest
@testable import AgentSessions

/// Projection tests for `DeepSeekHarnessSessionParser`.
///
/// Every fixture below is written to a temp file using real released v3
/// physical shapes admitted by the current reader and normalizer: a
/// `{"type":"session",...}` header line followed by zero-based dense
/// envelopes with `surfaceOp` on every surface event and no
/// `sourceEventSeqs` on `assistant/message`. Filenames are canonical
/// generation names (`session.vN.jsonl`), never shared fixtures.
final class DeepSeekHarnessSessionParserTests: XCTestCase {
    private let baseTime: Int64 = 1_700_000_000_000

    // MARK: - Fixture builders

    private func header(id: String = "dsh-parser-test-main",
                        version: Int = 3,
                        isSeeded: Bool = false,
                        parentSessionID: String? = nil,
                        origin: String? = nil,
                        preset: String? = nil) -> [String: Any] {
        var header: [String: Any] = [
            "type": "session",
            "version": version,
            "id": id,
            "createdAt": Int(baseTime),
            "isSeeded": isSeeded,
            "delegationDepth": origin == nil ? 0 : 1,
            "cwd": "/tmp/synthetic-dsh-demo",
        ]
        if let parentSessionID { header["parentSession"] = parentSessionID }
        if let origin { header["origin"] = origin }
        if let preset { header["agentPreset"] = preset }
        return header
    }

    private func envelope(_ type: String, _ sequence: Int,
                          data: [String: Any],
                          surfaceAppend: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "type": type,
            "seq": sequence,
            "time": Int(baseTime) + sequence * 1_000,
            "data": data,
        ]
        if surfaceAppend { row["surfaceOp"] = "append" }
        return row
    }

    private func userData(id: String, text: String, kind: String = "user",
                          plugin: String? = nil) -> [String: Any] {
        var source: [String: Any] = ["kind": kind]
        if let plugin { source["plugin"] = plugin }
        return [
            "id": id,
            "role": "user",
            "content": [["type": "text", "text": text]],
            "source": source,
        ]
    }

    private func assistantData(id: String, text: String, reasoning: String? = nil,
                               toolCall: (id: String, name: String, args: String)? = nil,
                               streamText: String? = nil) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let reasoning { content.append(["type": "reasoning", "text": reasoning]) }
        if let toolCall {
            content.append(["type": "tool-call", "id": toolCall.id,
                            "name": toolCall.name, "arguments": toolCall.args])
        }
        var stream: [[String: Any]] = [
            ["type": "text-chunks", "time0": Int(baseTime), "index": 0,
             "dt": [], "texts": [streamText ?? text]],
        ]
        if let toolCall {
            stream.append(["type": "tool-call-chunks", "time0": Int(baseTime) + 1,
                           "index": 1, "dt": [], "id": toolCall.id,
                           "name": toolCall.name, "args": [toolCall.args]])
        }
        stream.append(["type": "chunk", "time": Int(baseTime) + 2,
                       "chunk": ["type": "finish", "reason": ["kind": "stop"]]])
        return [
            "turn": 1,
            "step": 1,
            "message": [
                "id": id,
                "role": "assistant",
                "content": content,
                "source": ["kind": "model", "provider": "deepseek", "model": "deepseek-chat"],
            ] as [String: Any],
            "stream": stream,
        ]
    }

    private func toolResultData(messageID: String, callID: String, text: String) -> [String: Any] {
        [
            "turn": 1,
            "step": 1,
            "message": [
                "id": messageID,
                "role": "user",
                "content": [[
                    "type": "tool-result",
                    "toolCallId": callID,
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ]],
                "source": ["kind": "tool", "callId": callID],
            ] as [String: Any],
        ]
    }

    /// The shared main session: plugin context precedes the direct-human
    /// prompt, one assistant message carries text + reasoning + a tool call
    /// that also exists as a log event, a failed attempt must stay hidden,
    /// and an attachment-only message closes the transcript.
    private func mainRows() -> [[String: Any]] {
        [
            header(),
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("system/message", 2, data: [
                "turn": 1, "step": 1,
                "message": [
                    "id": "sys-1", "role": "system",
                    "content": [["type": "text", "text": "You are a helpful assistant."]],
                    "source": ["kind": "plugin", "plugin": "@deepseek-ai/dsh-system-prompt"],
                ] as [String: Any],
            ], surfaceAppend: true),
            envelope("user/message", 3,
                     data: userData(id: "u-plugin", text: "PLUGIN INJECTED CONTEXT",
                                    kind: "plugin", plugin: "demo-plugin"),
                     surfaceAppend: true),
            envelope("user/message", 4,
                     data: userData(id: "u-1", text: "Fix the parser bug"),
                     surfaceAppend: true),
            envelope("request/header", 5, data: [
                "header": ["config": ["provider": "deepseek", "model": "deepseek-chat"] as [String: Any]] as [String: Any],
                "reason": "initial",
            ]),
            envelope("assistant/message", 6,
                     data: assistantData(id: "a-1", text: "On it.",
                                         reasoning: "Need to read the parser first.",
                                         toolCall: (id: "call-1", name: "read",
                                                    args: "{\"path\":\"parser.swift\"}")),
                     surfaceAppend: true),
            envelope("tool/call", 7, data: [
                "turn": 1, "step": 1, "callId": "call-1", "name": "read",
                "arguments": "{\"path\":\"parser.swift\"}",
            ]),
            envelope("tool/result", 8,
                     data: toolResultData(messageID: "r-1", callID: "call-1",
                                          text: "file contents here"),
                     surfaceAppend: true),
            envelope("assistant/attempt", 9, data: [
                "turn": 1, "step": 1,
                "stream": [["type": "text-chunks", "time0": Int(baseTime), "index": 0,
                            "dt": [], "texts": ["FAILED ATTEMPT MUST STAY HIDDEN"]]],
            ]),
            envelope("assistant/message", 10,
                     data: assistantData(id: "a-2", text: "Done."),
                     surfaceAppend: true),
            envelope("user/message", 11, data: [
                "id": "u-2", "role": "user",
                "content": [
                    ["type": "image", "attachment": [
                        "attachmentId": "att-1", "mediaType": "image/png",
                        "bytes": 1234, "width": 8, "height": 8, "name": "shot.png",
                    ] as [String: Any]],
                    ["type": "file", "attachment": [
                        "attachmentId": "att-2", "name": "notes.txt", "bytes": 56,
                    ] as [String: Any]],
                ],
                "source": ["kind": "user"],
            ] as [String: Any], surfaceAppend: true),
            envelope("step/end", 12, data: ["turn": 1, "step": 1]),
            envelope("turn/end", 13, data: ["turn": 1, "reason": ["kind": "completed"]]),
            envelope("todo/write", 14, data: ["todos": []]),
            envelope("session/title", 15, data: [
                "title": "LLM TITLE MUST NOT WIN",
                "messageSeqs": [] as [Int],
                "source": "llm",
            ]),
        ]
    }

    private func writeSession(filename: String, rows: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        let lines = try rows.map { row -> String in
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func mainURL() throws -> URL {
        try writeSession(filename: "session.v3.jsonl", rows: mainRows())
    }

    // MARK: - Title and injected-content exclusion

    func testDirectHumanTitleUsesNestedContent() throws {
        let url = try mainURL()
        guard let preview = DeepSeekHarnessSessionParser.parseFile(at: url) else {
            return XCTFail("lightweight parse returned nil")
        }
        XCTAssertEqual(preview.lightweightTitle, "Fix the parser bug")
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertEqual(full.lightweightTitle, "Fix the parser bug")
        // Session.title for a loaded transcript derives from the first .user
        // event, which must also be the direct-human prompt.
        XCTAssertEqual(full.title, "Fix the parser bug")
        XCTAssertEqual(full.firstUserPreview, "Fix the parser bug")
    }

    func testPluginMessageExcludedFromTitleCountsAndUserKind() throws {
        let url = try mainURL()
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        let pluginRows = full.events.filter { $0.text == "PLUGIN INJECTED CONTEXT" }
        XCTAssertEqual(pluginRows.count, 1)
        XCTAssertEqual(pluginRows.first?.kind, .meta, "injected context must not be a .user event")
        XCTAssertEqual(full.events.filter { $0.kind == .user }.count, 2,
                       "only direct-human messages count as user events")
        XCTAssertFalse(full.lightweightTitle?.contains("PLUGIN") == true)
        XCTAssertFalse(full.title.contains("PLUGIN"))
    }

    func testGeneratedSessionTitleEventNeverTitles() throws {
        let url = try mainURL()
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertFalse(full.events.contains { ($0.text ?? "").contains("LLM TITLE MUST NOT WIN") })
        XCTAssertEqual(full.lightweightTitle, "Fix the parser bug")
    }

    // MARK: - Assistant content renders once

    func testEmbeddedTextReasoningAndToolCallRenderOnce() throws {
        let url = try mainURL()
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertEqual(full.events.filter { $0.kind == .assistant }.map { $0.text }, ["On it.", "Done."])
        let reasoning = full.events.filter { $0.role == "reasoning" }
        XCTAssertEqual(reasoning.count, 1)
        XCTAssertEqual(reasoning.first?.kind, .meta)
        XCTAssertEqual(reasoning.first?.text, "Need to read the parser first.")
        // The embedded stream is provenance, not transcript rows: its
        // fragments must not appear as extra events.
        XCTAssertEqual(full.events.filter { $0.isDelta }.count, 0)
        XCTAssertEqual(full.events.filter { $0.kind == .assistant }.count, 2)
    }

    func testAssistantAttemptStaysDiagnosticOnly() throws {
        let url = try mainURL()
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertFalse(full.events.contains { ($0.text ?? "").contains("FAILED ATTEMPT") })
        XCTAssertFalse(full.events.contains { ($0.rawJSON).contains("FAILED ATTEMPT") },
                       "attempt diagnostics must not leak into any retained raw payload")
    }

    // MARK: - Tool calls and results

    func testToolCallDedupedByCallIDWithBothProvenances() throws {
        let url = try mainURL()
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        let calls = full.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(calls.count, 1, "block + log event must produce exactly one invocation")
        XCTAssertEqual(calls.first?.id, "dsh-call-call-1")
        XCTAssertEqual(calls.first?.toolName, "read")
        XCTAssertTrue((calls.first?.toolInput ?? "").contains("parser.swift"))
        XCTAssertEqual(calls.first?.messageID, "call-1")
        let raw = calls.first?.rawJSON ?? ""
        XCTAssertTrue(raw.contains("\"block\""), "message-block provenance must be retained")
        XCTAssertTrue(raw.contains("\"event\""), "log-event provenance must be retained")
        XCTAssertEqual(full.lightweightCommands, 1)
    }

    func testToolResultPairsByCallID() throws {
        let url = try mainURL()
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        let results = full.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.messageID, "call-1")
        XCTAssertEqual(results.first?.toolName, "read", "name backfilled from the paired call")
        XCTAssertEqual(results.first?.toolOutput, "file contents here")
    }

    // MARK: - Attachments

    func testAttachmentPlaceholdersAreMetadataOnly() throws {
        let url = try mainURL()
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        let attachments = full.events.filter { $0.role == "attachment" }
        XCTAssertEqual(attachments.map { $0.text },
                       ["[image: shot.png, image/png, 1234 bytes]", "[file: notes.txt, 56 bytes]"])
        XCTAssertTrue(attachments.allSatisfy { $0.kind == .meta })
        for event in full.events {
            XCTAssertFalse((event.text ?? "").contains("att-1"), "attachment ids must never render")
            XCTAssertFalse((event.text ?? "").contains("att-2"), "attachment ids must never render")
        }
        XCTAssertEqual(full.lightweightTitle, "Fix the parser bug",
                       "attachment-only message must not title the session")
    }

    // MARK: - Model, subagent, and fork semantics

    func testModelComesFromNestedRequestHeader() throws {
        let url = try mainURL()
        XCTAssertEqual(DeepSeekHarnessSessionParser.parseFile(at: url)?.model, "deepseek-chat")
        XCTAssertEqual(DeepSeekHarnessSessionParser.parseFileFull(at: url)?.model, "deepseek-chat")
    }

    func testNormalizedCodePresetBecomesPtcSubagent() throws {
        let url = try writeSession(filename: "session.v2.jsonl", rows: [
            header(id: "dsh-subagent-1", version: 2, parentSessionID: "dsh-parent-1",
                   origin: "subagent", preset: "code"),
            envelope("step/start", 0, data: ["turn": 1, "step": 1]),
            envelope("request/header", 1, data: [
                "header": ["config": ["provider": "deepseek", "model": "deepseek-chat"] as [String: Any]] as [String: Any],
                "reason": "initial",
            ]),
            envelope("step/end", 2, data: ["turn": 1, "step": 1]),
            envelope("turn/end", 3, data: ["turn": 1]),
        ])
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertEqual(full.parentSessionID, "dsh-parent-1")
        XCTAssertEqual(full.subagentType, "ptc", "historical code preset normalizes to ptc")
        XCTAssertEqual(full.relationshipKind, .subagent)
        XCTAssertEqual(full.surface, .subagent)
        XCTAssertEqual(full.model, "deepseek-chat")
        // Deterministic project + creation-time fallback, never a prompt.
        XCTAssertEqual(full.lightweightTitle, "synthetic-dsh-demo · 2023-11-14 22:13")
    }

    func testParentWithoutSubagentOriginStaysRoot() throws {
        let url = try writeSession(filename: "session.v3.jsonl", rows: [
            header(id: "dsh-fork-1", isSeeded: true, parentSessionID: "dsh-parent-1"),
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("session/end-seed", 2, data: ["inherited": true]),
            envelope("user/message", 3, data: userData(id: "u-1", text: "Forked work"),
                     surfaceAppend: true),
            envelope("step/end", 4, data: ["turn": 1, "step": 1]),
            envelope("turn/end", 5, data: ["turn": 1]),
        ])
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertNil(full.parentSessionID, "forks must not masquerade as subagents")
        XCTAssertNil(full.subagentType)
        XCTAssertEqual(full.relationshipKind, .root)
        XCTAssertEqual(full.surface, .unknown)
        XCTAssertEqual(full.lightweightTitle, "Forked work")
        XCTAssertTrue(full.events.contains { $0.role == "seed" }, "seed boundary stays visible")
    }

    // MARK: - Parse modes and determinism

    func testLightweightAndFullShareSemantics() throws {
        let url = try mainURL()
        guard let preview = DeepSeekHarnessSessionParser.parseFile(at: url),
              let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertTrue(preview.events.isEmpty, "lightweight parse must carry no events")
        XCTAssertFalse(full.events.isEmpty)
        XCTAssertEqual(preview.eventCount, full.eventCount)
        XCTAssertEqual(preview.lightweightTitle, full.lightweightTitle)
        XCTAssertEqual(preview.model, full.model)
        XCTAssertEqual(preview.lightweightCommands, full.lightweightCommands)
        XCTAssertEqual(preview.startTime, full.startTime)
        XCTAssertEqual(preview.endTime, full.endTime)
    }

    func testInterruptedTurnAddsDisplayOnlyMarker() throws {
        let url = try writeSession(filename: "session.v3.jsonl", rows: [
            header(id: "dsh-interrupted-1"),
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("user/message", 2, data: userData(id: "u-1", text: "Unfinished work"),
                     surfaceAppend: true),
        ])
        guard let full = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        XCTAssertTrue(full.events.contains { $0.text == "Interrupted turn" })
        guard let preview = DeepSeekHarnessSessionParser.parseFile(at: url) else {
            return XCTFail("lightweight parse returned nil")
        }
        XCTAssertEqual(preview.eventCount, full.eventCount, "marker is meta-only")
    }

    func testRepeatParsesAreDeterministic() throws {
        let url = try mainURL()
        guard let first = DeepSeekHarnessSessionParser.parseFileFull(at: url),
              let second = DeepSeekHarnessSessionParser.parseFileFull(at: url) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertEqual(first.events, second.events)
        XCTAssertEqual(first.lightweightTitle, second.lightweightTitle)
        XCTAssertEqual(first.eventCount, second.eventCount)
        XCTAssertEqual(first.startTime, second.startTime)
        XCTAssertEqual(first.endTime, second.endTime)
    }

    // MARK: - Failure closure

    func testFailedReadsAndNormalizationReturnNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = dir.appendingPathComponent("session.jsonl")
        try "not json\n".write(to: garbage, atomically: true, encoding: .utf8)
        XCTAssertNil(DeepSeekHarnessSessionParser.parseFile(at: garbage))
        XCTAssertNil(DeepSeekHarnessSessionParser.parseFileFull(at: garbage))

        let unknownRequired = try writeSession(filename: "session.v3.jsonl", rows: [
            header(id: "dsh-unknown-1"),
            envelope("future/thing", 0, data: [:]),
        ])
        XCTAssertNil(DeepSeekHarnessSessionParser.parseFile(at: unknownRequired))
        XCTAssertNil(DeepSeekHarnessSessionParser.parseFileFull(at: unknownRequired))

        let wrongName = dir.appendingPathComponent("random.jsonl")
        try "x\n".write(to: wrongName, atomically: true, encoding: .utf8)
        XCTAssertNil(DeepSeekHarnessSessionParser.parseFile(at: wrongName))
    }
}
