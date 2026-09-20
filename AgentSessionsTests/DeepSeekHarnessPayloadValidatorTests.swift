import Foundation
import XCTest
@testable import AgentSessions

/// Focused admission tests for `DeepSeekHarnessPayloadValidator`.
///
/// Fixtures use released v2/v3 physical shapes admitted by the pinned DSH
/// catalog: exact required/optional key sets, frozen scalar rules, and the
/// nested content/source/header/tool/feedback/turn/retry/dispatch families.
/// Negative cases assert deterministic stage-specific errors (`format v2`
/// before migration, `format v3` after).
final class DeepSeekHarnessPayloadValidatorTests: XCTestCase {
    private let baseTime: Int64 = 1_700_000_000_000

    // MARK: - Builders

    private func v2(_ type: String, _ sequence: Int,
                    data: [String: Any],
                    ignorable: Bool = false,
                    sourceEventSeqs: [Int]? = nil,
                    surfaceOp: DeepSeekHarnessSurfaceOp? = nil) -> DeepSeekHarnessEnvelope {
        DeepSeekHarnessEnvelope(
            type: type, sequence: sequence,
            timeMilliseconds: baseTime + Int64(sequence * 1_000),
            data: data, ignorable: ignorable,
            sourceEventSeqs: sourceEventSeqs, surfaceOp: surfaceOp)
    }

    private func v3(_ type: String, _ sequence: Int,
                    data: [String: Any],
                    ignorable: Bool = false,
                    sourceEventSeqs: [Int]? = nil,
                    surfaceOp: DeepSeekHarnessSurfaceOp? = nil) -> DeepSeekHarnessEnvelope {
        v2(type, sequence, data: data, ignorable: ignorable,
           sourceEventSeqs: sourceEventSeqs, surfaceOp: surfaceOp)
    }

    private func userMessageData(id: String = "user-1", text: String = "hello",
                                 source: [String: Any] = ["kind": "user"]) -> [String: Any] {
        ["id": id, "role": "user",
         "content": [["type": "text", "text": text] as [String: Any]],
         "source": source]
    }

    private func assistantMessageData(id: String = "assistant-1") -> [String: Any] {
        ["turn": 1, "step": 1,
         "message": ["id": id, "role": "assistant",
                     "content": [["type": "text", "text": "done"] as [String: Any]],
                     "source": ["kind": "model", "provider": "p", "model": "m"] as [String: Any]
                    ] as [String: Any],
         "stream": [] as [Any]]
    }

    private func toolResultData(messageID: String = "result-1", callID: String = "call-1",
                                isError: Bool = false) -> [String: Any] {
        ["turn": 1, "step": 1,
         "message": ["id": messageID, "role": "user",
                     "content": [["type": "tool-result", "toolCallId": callID,
                                  "content": [["type": "text", "text": "out"] as [String: Any]],
                                  "isError": isError] as [String: Any]],
                     "source": ["kind": "tool", "callId": callID] as [String: Any]
                    ] as [String: Any]]
    }

    private func requestHeaderData(system: Any? = nil,
                                   tools: Any? = nil,
                                   reason: Any? = "initial") -> [String: Any] {
        var header: [String: Any] = [
            "config": ["provider": "p", "model": "m"] as [String: Any],
        ]
        if let system { header["system"] = system }
        if let tools { header["tools"] = tools }
        var data: [String: Any] = ["header": header]
        if let reason { data["reason"] = reason }
        return data
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
            as? [String: Any])
    }

    // MARK: - V2 positive admission

    func testV2AdmitsRepresentativeTranscriptFamilies() throws {
        let events = [
            v2("turn/start", 0, data: ["turn": 1]),
            v2("step/start", 1, data: ["turn": 1, "step": 1]),
            v2("user/message", 2, data: userMessageData(), surfaceOp: .append),
            v2("request/header", 3, data: requestHeaderData(system: "context")),
            v2("tool/call", 4, data: ["turn": 1, "step": 1, "callId": "call-1",
                                      "name": "read", "arguments": "{}"]),
            v2("assistant/message", 5, data: assistantMessageData(), surfaceOp: .append),
            v2("tool/result", 6, data: toolResultData(), surfaceOp: .append),
            v2("step/end", 7, data: ["turn": 1, "step": 1]),
            v2("turn/end", 8, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ]
        for event in events {
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(event)
        }
    }

    func testV2AdmitsCompactionRetryDispatchAndFeedback() throws {
        let events = [
            v2("compaction/start", 0, data: ["compactionId": "c-1", "turn": 1]),
            v2("compaction/summary", 1, data: [
                "compactionId": "c-1",
                "summary": [["type": "text", "text": "summary"] as [String: Any]],
                "shadowedRange": ["start": 0, "end": 0] as [String: Any],
                "shadowedSeqs": [0],
                "shadowedTokenCount": 3,
                "provider": "p", "model": "m",
            ]),
            v2("compaction/end", 2, data: ["compactionId": "c-1", "turn": 1]),
            v2("llm/retry", 3, data: [
                "retryId": "retry-1", "turn": 1, "step": 1, "provider": "p",
                "mode": "normal", "policyKey": "k", "retry": 1, "maxRetries": 2,
                "delayMs": 100,
                "failure": ["message": "boom", "code": "E"] as [String: Any],
            ]),
            v2("llm/retry-started", 4, data: ["retryId": "retry-1", "turn": 1,
                                              "step": 1, "retry": 1]),
            v2("tool/code-dispatch-start", 5, data: [
                "rootCallId": "root", "parentCallId": "root", "subCallId": "sub",
                "name": "read", "arguments": "{}",
            ]),
            v2("tool/code-dispatch", 6, data: [
                "rootCallId": "root", "parentCallId": "root", "subCallId": "sub",
                "name": "read", "arguments": "{}",
                "isError": false,
                "content": [["type": "text", "text": "out"] as [String: Any]],
            ]),
            v2("feedback/message-put", 7, data: [
                "sessionId": "s-1",
                "item": ["messageId": "m-1", "rating": "positive", "version": "v1",
                         "createdAt": 10, "updatedAt": 11] as [String: Any],
            ]),
            v2("feedback/message-delete", 8, data: ["sessionId": "s-1", "messageId": "m-1"]),
            v2("session/end-seed", 9, data: ["inherited": true]),
        ]
        for event in events {
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(event)
        }
    }

    // MARK: - V2 negative admission

    func testV2RejectsExtraKeysAndUnknownEvents() throws {
        var data = userMessageData()
        data["injected"] = "nope"
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("user/message", 0, data: data, surfaceOp: .append))) { error in
            guard case .invalidPayload(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
            XCTAssertTrue(detail.contains("unexpected field injected"), detail)
        }

        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("x-test/anything", 0, data: [:], ignorable: true))) { error in
            // Migration refuses unclassified v2 events even when ignorable.
            guard case .unsupportedMigration(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected unsupportedMigration, got \(error)")
            }
            XCTAssertTrue(detail.contains("unclassified event"), detail)
        }
    }

    func testV2RejectsMalformedNestedContent() throws {
        var toolResult = toolResultData()
        var message = toolResult["message"] as! [String: Any]
        message["content"] = "not-an-array"
        toolResult["message"] = message
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("tool/result", 0, data: toolResult, surfaceOp: .append)))

        var text = userMessageData()
        text["content"] = [["type": "text", "text": 42] as [String: Any]]
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("user/message", 0, data: text, surfaceOp: .append)))
    }

    func testV2RejectsWrongRoleAndSourceKind() throws {
        var assistant = assistantMessageData()
        var message = assistant["message"] as! [String: Any]
        message["role"] = "user"
        assistant["message"] = message
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("assistant/message", 0, data: assistant, surfaceOp: .append)))

        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("user/message", 0,
                   data: userMessageData(source: ["kind": "telepathy"]),
                   surfaceOp: .append))) { error in
            guard case .unsupportedMigration(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected unsupportedMigration, got \(error)")
            }
            XCTAssertTrue(detail.contains("unclassified message source"), detail)
        }

        // agent-message without the relay shape is not a classified source.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("user/message", 0,
                   data: userMessageData(source: ["kind": "agent-message", "form": "notice"]),
                   surfaceOp: .append)))
    }

    func testV2RejectsBadSourceRangesAndSurfaceOps() throws {
        // Future seq reference.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("user/message", 1, data: userMessageData(),
                   sourceEventSeqs: [1], surfaceOp: .append)))
        // Empty sources on a non-assistant surface event.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("user/message", 1, data: userMessageData(),
                   sourceEventSeqs: [], surfaceOp: .append)))
        // Duplicate sources.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("tool/result", 3, data: toolResultData(),
                   sourceEventSeqs: [0, 0], surfaceOp: .append)))
        // Assistant messages embed their stream and cannot carry sources.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("assistant/message", 1, data: assistantMessageData(),
                   sourceEventSeqs: [0], surfaceOp: .append))) { error in
            guard case .invalidPayload(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
            XCTAssertTrue(detail.contains("obsolete chunk references"), detail)
        }
        // Surface events require surfaceOp; log events forbid it.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("user/message", 0, data: userMessageData())))
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("turn/start", 0, data: ["turn": 1], surfaceOp: .append)))
        // Replacement endpoints must reference earlier events.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("user/message", 1, data: userMessageData(),
                   surfaceOp: .replace(start: 0, end: 1))))
    }

    func testV2RejectsMalformedRequestHeaders() throws {
        // Missing reason.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("request/header", 0, data: requestHeaderData(reason: nil))))
        // Config without a model.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("request/header", 0, data: [
                    "header": ["config": ["provider": "p"] as [String: Any]] as [String: Any],
                    "reason": "initial",
                ])))
        // Tools must be an array of schemas, not a string.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("request/header", 0, data: requestHeaderData(tools: "read"))))
        // Retired-system type errors are caught here even though migration
        // would silently drop a non-string system value.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("request/header", 0, data: requestHeaderData(system: 42)))) { error in
            guard case .invalidPayload(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
            XCTAssertTrue(detail.contains("system"), detail)
        }
    }

    func testV2RejectsToolIdentityMismatches() throws {
        // Two content blocks instead of exactly one.
        var two = toolResultData()
        var twoMessage = two["message"] as! [String: Any]
        twoMessage["content"] = [
            ["type": "tool-result", "toolCallId": "call-1",
             "content": [] as [Any], "isError": false] as [String: Any],
            ["type": "text", "text": "extra"] as [String: Any],
        ]
        two["message"] = twoMessage
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("tool/result", 0, data: two, surfaceOp: .append)))

        // Block identity must match the tool source call id.
        var mismatch = toolResultData(callID: "call-2")
        var mismatchMessage = mismatch["message"] as! [String: Any]
        mismatchMessage["source"] = ["kind": "tool", "callId": "call-1"] as [String: Any]
        mismatch["message"] = mismatchMessage
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("tool/result", 0, data: mismatch, surfaceOp: .append)))

        // TOOL_NOT_STARTED repair requires the canonical historical id.
        var repair = toolResultData(messageID: "wrong-id", callID: "call-9", isError: true)
        repair["error"] = ["name": "ToolNotStartedError", "code": "TOOL_NOT_STARTED"] as [String: Any]
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("tool/result", 7, data: repair, surfaceOp: .append)))

        var canonical = toolResultData(messageID: "interrupted-tool-result-call-9-7",
                                        callID: "call-9", isError: true)
        canonical["error"] = ["name": "ToolNotStartedError",
                              "code": "TOOL_NOT_STARTED"] as [String: Any]
        try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
            v2("tool/result", 7, data: canonical, surfaceOp: .append))
    }

    func testV2RejectsBadFeedbackAndRetryShapes() throws {
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("feedback/message-put", 0, data: [
                    "sessionId": "s-1",
                    "item": ["messageId": "m-1", "rating": "meh", "version": "v1",
                             "createdAt": 10, "updatedAt": 11] as [String: Any],
                ])))
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("feedback/message-delete", 0, data: ["sessionId": "s-1"])))
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("llm/retry", 0, data: [
                    "retryId": "r", "turn": 1, "step": 1, "provider": "p",
                    "mode": "always", "policyKey": "k", "retry": 1, "maxRetries": 2,
                    "delayMs": 1,
                    "failure": ["message": "m", "code": "c"] as [String: Any],
                ])))
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("session/end-seed", 0, data: ["inherited": false])))
    }

    func testV2RejectsBooleanVersusNumberTraps() throws {
        // Numeric 1 must not read as boolean true inside payloads.
        var toolResult = toolResultData()
        var message = toolResult["message"] as! [String: Any]
        var content = (message["content"] as! [Any]).map { $0 as! [String: Any] }
        content[0]["isError"] = 1
        message["content"] = content
        toolResult["message"] = message
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(
                v2("tool/result", 0, data: toolResult, surfaceOp: .append)))

        // A numeric ignorable must not pass as true at the envelope.
        let raw = try jsonObject(
            "{\"type\":\"turn/start\",\"seq\":0,\"time\":1,\"data\":{\"turn\":1},\"ignorable\":1}")
        var rejected = false
        if let envelope = try? DeepSeekHarnessEnvelope.decode(raw) {
            XCTAssertThrowsError(
                try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(envelope))
            XCTAssertThrowsError(
                try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(envelope))
            rejected = true
        } else {
            rejected = true
        }
        XCTAssertTrue(rejected, "numeric ignorable must be rejected at some stage")

        // A boolean seq must not read as a count.
        let badSeq = try jsonObject(
            "{\"type\":\"turn/start\",\"seq\":true,\"time\":1,\"data\":{\"turn\":1}}")
        XCTAssertThrowsError(try DeepSeekHarnessEnvelope.decode(badSeq))
    }

    // MARK: - V2-invalid-before-migration end to end

    func testV2InvalidPayloadFailsBeforeMigrationDropsTheField() throws {
        let header = DeepSeekHarnessHeader(
            version: 2, id: "dsh-validator-test", createdAtMilliseconds: baseTime,
            cwd: "/tmp/dsh-tests", parentSessionID: nil, isSeeded: false,
            origin: nil, delegationDepth: 0, agentPreset: nil)
        // Migration strips a non-string system prompt (`as? String ?? ""`),
        // so without pre-migration admission this log would normalize cleanly.
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(v2("step/start", 0, data: ["turn": 1, "step": 1])),
            .event(v2("request/header", 1, data: requestHeaderData(system: 42))),
            .event(v2("step/end", 2, data: ["turn": 1, "step": 1])),
        ]
        let result = DeepSeekHarnessParseResult(
            header: header, rows: rows, inheritedEventCount: 0,
            skippedIgnorableTypes: [], incompleteTurn: false)
        XCTAssertThrowsError(try DeepSeekHarnessHistoricalNormalizer.normalize(result)) { error in
            guard case .invalidPayload(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
            XCTAssertTrue(detail.hasPrefix("format v2"), detail)
        }
    }

    func testValidV2SessionStillNormalizesAfterAdmission() throws {
        let header = DeepSeekHarnessHeader(
            version: 2, id: "dsh-validator-test", createdAtMilliseconds: baseTime,
            cwd: "/tmp/dsh-tests", parentSessionID: nil, isSeeded: false,
            origin: nil, delegationDepth: 0, agentPreset: nil)
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(v2("turn/start", 0, data: ["turn": 1])),
            .event(v2("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(v2("user/message", 2, data: userMessageData(), surfaceOp: .append)),
            .event(v2("request/header", 3, data: requestHeaderData(system: "Be brief."))),
            .event(v2("assistant/message", 4, data: assistantMessageData(), surfaceOp: .append)),
            .event(v2("step/end", 5, data: ["turn": 1, "step": 1])),
        ]
        let result = DeepSeekHarnessParseResult(
            header: header, rows: rows, inheritedEventCount: 0,
            skippedIgnorableTypes: [], incompleteTurn: false)
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result)
        XCTAssertTrue(normalized.contains { $0.canonicalType == "assistant/message" })
        XCTAssertTrue(normalized.contains { $0.canonicalType == "system/message" })
    }

    // MARK: - V3 post-migration admission

    func testV3AdmitsCanonicalSystemHeaderAndErrorResult() throws {
        let system = v3("system/message", 0, data: [
            "turn": 1, "step": 1,
            "message": ["id": "sys-1", "role": "system",
                        "source": ["kind": "plugin",
                                   "plugin": "@deepseek-ai/dsh-system-prompt"] as [String: Any],
                        "content": [["type": "text", "text": "prompt"] as [String: Any]]
                       ] as [String: Any],
        ], surfaceOp: .append)
        try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(system)

        let header = v3("request/header", 1, data: requestHeaderData())
        try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(header)

        var errorResult = toolResultData(isError: true)
        errorResult["error"] = ["name": "E", "code": "C"] as [String: Any]
        try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
            v3("tool/result", 2, data: errorResult, surfaceOp: .append))

        // Unknown ignorable events pass envelope admission for diagnostics.
        try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
            v3("x-test/future", 3, data: ["anything": true], ignorable: true))
        // Obsolete dispatch tags pass only when ignorable.
        try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
            v3("tool/code-dispatch", 4, data: ["note": "old"], ignorable: true))
    }

    func testV3RejectsStructuralAndCanonicalViolations() throws {
        // System message without source/content.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("system/message", 0, data: [
                    "turn": 1, "step": 1,
                    "message": ["id": "sys-1", "role": "system"] as [String: Any],
                ], surfaceOp: .append)))
        // Retired header.system in v3.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("request/header", 0, data: requestHeaderData(system: "old"))))
        // Empty optional header fields must be omitted in v3.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("request/header", 0, data: requestHeaderData(tools: []))))
        // Error metadata on a non-error result.
        var mismatch = toolResultData(isError: false)
        mismatch["error"] = ["name": "E", "code": "C"] as [String: Any]
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("tool/result", 0, data: mismatch, surfaceOp: .append)))
        // Assistant messages embed their stream.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("assistant/message", 1, data: assistantMessageData(),
                   sourceEventSeqs: [0], surfaceOp: .append)))
        // Surface events require surfaceOp; log events forbid it.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("user/message", 0, data: userMessageData())))
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("turn/start", 0, data: ["turn": 1], surfaceOp: .append)))
        // Required unknowns fail, including non-ignorable obsolete tags.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("x-test/required", 0, data: [:]))) { error in
            XCTAssertEqual(error as? DeepSeekHarnessFormatError,
                           .unknownRequiredEvent("x-test/required"))
        }
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("tool/code-dispatch", 0, data: ["note": "old"])))
        // Replacement endpoints must reference earlier events.
        XCTAssertThrowsError(
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(
                v3("user/message", 1, data: userMessageData(),
                   surfaceOp: .replaceV3(startSeq: 0, endSeq: 1))))
    }
}
