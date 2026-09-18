import Foundation
import XCTest
@testable import AgentSessions

final class DeepSeekHarnessHistoricalNormalizerTests: XCTestCase {
    func testJSONScalarAdmissionDistinguishesZeroOneFromBooleans() {
        let object = try! JSONSerialization.jsonObject(
            with: Data("{\"zero\":0,\"one\":1,\"false\":false,\"true\":true}".utf8)
        ) as! [String: Any]

        XCTAssertEqual(DeepSeekHarnessJSON.safeInt(object["zero"]), 0)
        XCTAssertEqual(DeepSeekHarnessJSON.safeInt(object["one"]), 1)
        XCTAssertNil(DeepSeekHarnessJSON.safeInt(object["false"]))
        XCTAssertNil(DeepSeekHarnessJSON.safeInt(object["true"]))
        XCTAssertNil(DeepSeekHarnessJSON.bool(object["zero"]))
        XCTAssertNil(DeepSeekHarnessJSON.bool(object["one"]))
        XCTAssertEqual(DeepSeekHarnessJSON.bool(object["false"]), false)
        XCTAssertEqual(DeepSeekHarnessJSON.bool(object["true"]), true)
    }

    private let baseTime: Int64 = 1_700_000_000_000

    private func header(version: Int, id: String = "dsh-test-session",
                        isSeeded: Bool = false, parentSessionID: String? = nil) -> DeepSeekHarnessHeader {
        DeepSeekHarnessHeader(
            version: version,
            id: id,
            createdAtMilliseconds: baseTime,
            cwd: "/tmp/dsh-tests",
            parentSessionID: parentSessionID,
            isSeeded: isSeeded,
            origin: parentSessionID == nil ? nil : "subagent",
            delegationDepth: parentSessionID == nil ? 0 : 1,
            agentPreset: parentSessionID == nil ? nil : "code"
        )
    }

    private func envelope(
        _ type: String,
        _ sequence: Int,
        data: [String: Any] = [:],
        ignorable: Bool = false,
        sourceEventSeqs: [Int]? = nil,
        surfaceOp: DeepSeekHarnessSurfaceOp? = nil
    ) -> DeepSeekHarnessEnvelope {
        DeepSeekHarnessEnvelope(
            type: type,
            sequence: sequence,
            timeMilliseconds: baseTime + Int64(sequence * 1_000),
            data: data,
            ignorable: ignorable,
            sourceEventSeqs: sourceEventSeqs,
            surfaceOp: surfaceOp
        )
    }

    private func result(
        version: Int,
        rows: [DeepSeekHarnessPhysicalRow],
        inheritedEventCount: Int = 0
    ) -> DeepSeekHarnessParseResult {
        DeepSeekHarnessParseResult(
            header: header(version: version),
            rows: rows,
            inheritedEventCount: inheritedEventCount,
            skippedIgnorableTypes: [],
            incompleteTurn: false
        )
    }

    private func packedRun(
        type: String,
        sequence: Int,
        payload: [String],
        turn: Int = 1,
        step: Int = 1,
        index: Int = 0
    ) throws -> DeepSeekHarnessPackedRun {
        let data: [String: Any] = [
            "turn": turn,
            "step": step,
            "index": index,
            "dt": Array(repeating: 1_000, count: max(0, payload.count - 1)),
            type == "tool-call-chunks" ? "args" : "texts": payload
        ]
        return try DeepSeekHarnessPackedRun.decode([
            "type": type,
            "seq0": sequence,
            "time0": Int(baseTime) + sequence * 1_000,
            "data": data
        ])
    }

    private func v1Rows(includeConsumedReference: Bool = false) throws -> [DeepSeekHarnessPhysicalRow] {
        let assistantMessage: [String: Any] = [
            "turn": 1,
            "step": 1,
            "message": [
                "id": "assistant-message-1",
                "role": "assistant",
                "content": [["type": "text", "text": "done"]]
            ] as [String: Any]
        ]
        var rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .packed(try packedRun(type: "text-chunks", sequence: 2, payload: ["hello"])),
            .packed(try packedRun(type: "reasoning-chunks", sequence: 3, payload: ["thinking"])),
            .event(envelope("assistant/message", 4,
                            data: assistantMessage,
                            sourceEventSeqs: [2, 3],
                            surfaceOp: .append))
        ]
        if includeConsumedReference {
            rows.append(.event(envelope("command/done", 5, data: ["sourceEventSeq": 2])))
        } else {
            rows.append(.event(envelope("step/end", 5, data: ["turn": 1, "step": 1])))
        }
        return rows
    }

    private func v2Rows() -> [DeepSeekHarnessPhysicalRow] {
        [
            .event(envelope("step/start", 0, data: ["turn": 1, "step": 1])),
            .event(envelope("request/header", 1, data: [
                "header": [
                    "system": "Use the PTC tools.",
                    "model": "dsh-test-model"
                ] as [String: Any]
            ])),
            .event(envelope("tool/code-dispatch-start", 2, data: ["turn": 1, "step": 1])),
            .event(envelope("tool/code-dispatch", 3, data: ["turn": 1, "step": 1])),
            .event(envelope("step/end", 4, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 5, data: ["turn": 1]))
        ]
    }

    private func canonicalJSON(_ events: [DeepSeekHarnessNormalizedEvent]) throws -> String {
        try XCTUnwrap(DeepSeekHarnessJSON.canonicalString(events.map { $0.envelope.rawObject }))
    }

    func testV3ZeroBasedDenseEventsPreserveCanonicalSurfaceMetadataAndSystemHead() throws {
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("system/message", 2, data: [
                "turn": 1,
                "step": 1,
                "message": ["id": "system-1", "role": "system"] as [String: Any]
            ], surfaceOp: .append)),
            .event(envelope("user/message", 3, data: [
                "id": "user-1", "role": "user", "text": "hello"
            ], surfaceOp: .append)),
            .event(envelope("assistant/message", 4, data: [
                "message": ["id": "assistant-1", "role": "assistant"] as [String: Any],
                "stream": [["kind": "text", "text": "hello"]]
            ], surfaceOp: .append)),
            .event(envelope("tool/call", 5, data: ["callId": "call-1", "tool": "shell"])),
            .event(envelope("tool/result", 6, data: [
                "message": ["id": "result-1", "role": "tool"] as [String: Any]
            ], surfaceOp: .append)),
            .event(envelope("step/end", 7, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 8, data: ["turn": 1]))
        ]

        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(
            result(version: 3, rows: rows)
        )

        XCTAssertEqual(normalized.map(\.envelope.sequence), Array(0..<rows.count))
        XCTAssertEqual(normalized.first?.canonicalType, "turn/start")
        let surfaceEvents = normalized.filter {
            DeepSeekHarnessVocabulary.surfaceV3.contains($0.canonicalType)
        }
        XCTAssertEqual(surfaceEvents.first?.canonicalType, "system/message")
        XCTAssertEqual(surfaceEvents.first?.envelope.surfaceOp, .append)
        XCTAssertNil(surfaceEvents.first?.envelope.sourceEventSeqs)
        XCTAssertFalse(surfaceEvents.dropFirst().contains {
            if case .replaceV3 = $0.envelope.surfaceOp { return true }
            return false
        })
    }

    func testV1PackedTextAndReasoningRowsFoldOnceIntoAssistantMessage() throws {
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(
            result(version: 1, rows: try v1Rows())
        )

        let assistantMessages = normalized.filter { $0.canonicalType == "assistant/message" }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertNil(assistantMessages[0].envelope.sourceEventSeqs)
        let stream = try XCTUnwrap(assistantMessages[0].data["stream"] as? [[String: Any]])
        XCTAssertEqual(stream.compactMap { $0["type"] as? String }, ["text-chunks", "reasoning-chunks"])
        XCTAssertEqual(normalized.filter { $0.canonicalType == "assistant/attempt" }.count, 0)
    }

    func testV1ReferenceIntoConsumedPackedChunkFails() throws {
        XCTAssertThrowsError(try DeepSeekHarnessHistoricalNormalizer.normalize(
            result(version: 1, rows: try v1Rows(includeConsumedReference: true))
        )) { error in
            guard case .invalidReference(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected invalidReference, got \(error)")
            }
            XCTAssertTrue(detail.contains("consumed"), detail)
        }
    }

    func testV2InsertsAndProtectsSystemHeadAndRenamesCodeDispatchToPTC() throws {
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(
            result(version: 2, rows: v2Rows())
        )

        let systems = normalized.filter { $0.canonicalType == "system/message" }
        XCTAssertEqual(systems.count, 2)
        XCTAssertEqual(systems[0].envelope.surfaceOp, .append)
        XCTAssertEqual(systems[1].envelope.surfaceOp, .replaceV3(startSeq: 1, endSeq: 1))
        XCTAssertEqual(systems[1].envelope.sourceEventSeqs, [1])
        XCTAssertTrue(normalized.contains { $0.canonicalType == "tool/ptc-dispatch-start" })
        XCTAssertTrue(normalized.contains { $0.canonicalType == "tool/ptc-dispatch" })
        XCTAssertFalse(normalized.contains { $0.canonicalType == "tool/code-dispatch" })
    }

    func testV3RequiredUnknownFailsWhileIgnorableUnknownIsRetainedForDiagnostics() throws {
        let required = result(version: 3, rows: [
            .event(envelope("x-test/required", 0))
        ])
        XCTAssertThrowsError(try DeepSeekHarnessHistoricalNormalizer.normalize(required)) { error in
            XCTAssertEqual(error as? DeepSeekHarnessFormatError, .unknownRequiredEvent("x-test/required"))
        }

        let ignorable = result(version: 3, rows: [
            .event(envelope("x-test/ignorable", 0, ignorable: true))
        ])
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(ignorable)
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].canonicalType, "x-test/ignorable")
        XCTAssertTrue(normalized[0].diagnosticOnly)
    }

    func testRepeatNormalizationProducesDeterministicCanonicalJSON() throws {
        let first = try DeepSeekHarnessHistoricalNormalizer.normalize(
            result(version: 2, rows: v2Rows())
        )
        let second = try DeepSeekHarnessHistoricalNormalizer.normalize(
            result(version: 2, rows: v2Rows())
        )

        XCTAssertEqual(try canonicalJSON(first), try canonicalJSON(second))
    }

    func testHistoricalHeaderPromotesCodePresetToPTCWithoutRewritingNativeV3() {
        let historical = header(version: 2, parentSessionID: "parent")
        let migrated = DeepSeekHarnessHistoricalNormalizer.normalizedHeader(historical)
        XCTAssertEqual(migrated.version, 3)
        XCTAssertEqual(migrated.agentPreset, "ptc")

        let native = DeepSeekHarnessHeader(
            version: 3,
            id: historical.id,
            createdAtMilliseconds: historical.createdAtMilliseconds,
            cwd: historical.cwd,
            parentSessionID: historical.parentSessionID,
            isSeeded: historical.isSeeded,
            origin: historical.origin,
            delegationDepth: historical.delegationDepth,
            agentPreset: "code"
        )
        XCTAssertEqual(DeepSeekHarnessHistoricalNormalizer.normalizedHeader(native).agentPreset, "code")
    }
}
