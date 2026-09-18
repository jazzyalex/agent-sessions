import Foundation
import XCTest
@testable import AgentSessions

/// Second-phase historical-semantics parity for the v1-to-v2 edge, pinned
/// against the frozen DSH reference (`ddefc45fbc7f8e46dd73185e68295696d1297887`):
/// strict v1 admission, the interrupted-turn repair, and exact
/// assistant-stream coalescing across packed/raw boundaries.
final class DeepSeekHarnessHistoricalMigrationParityTests: XCTestCase {
    private let baseTime: Int64 = 1_700_000_000_000

    private func header(version: Int = 1, id: String = "dsh-parity-test") -> DeepSeekHarnessHeader {
        DeepSeekHarnessHeader(
            version: version, id: id, createdAtMilliseconds: baseTime,
            cwd: "/tmp/dsh-tests", parentSessionID: nil, isSeeded: false,
            origin: nil, delegationDepth: 0, agentPreset: nil)
    }

    private func envelope(
        _ type: String,
        _ sequence: Int,
        time: Int64? = nil,
        data: [String: Any] = [:],
        ignorable: Bool = false,
        sourceEventSeqs: [Int]? = nil,
        surfaceOp: DeepSeekHarnessSurfaceOp? = nil
    ) -> DeepSeekHarnessEnvelope {
        DeepSeekHarnessEnvelope(
            type: type, sequence: sequence,
            timeMilliseconds: time ?? baseTime + Int64(sequence * 1_000),
            data: data, ignorable: ignorable,
            sourceEventSeqs: sourceEventSeqs, surfaceOp: surfaceOp)
    }

    private func result(
        rows: [DeepSeekHarnessPhysicalRow],
        inheritedEventCount: Int = 0
    ) -> DeepSeekHarnessParseResult {
        DeepSeekHarnessParseResult(
            header: header(), rows: rows, inheritedEventCount: inheritedEventCount,
            skippedIgnorableTypes: [], incompleteTurn: false)
    }

    private func packedRun(
        type: String,
        sequence: Int,
        time: Int64,
        payload: [String],
        index: Int = 0,
        turn: Int = 1,
        step: Int = 1
    ) throws -> DeepSeekHarnessPackedRun {
        try DeepSeekHarnessPackedRun.decode([
            "type": type,
            "seq0": sequence,
            "time0": Int(time),
            "data": [
                "turn": turn,
                "step": step,
                "index": index,
                "dt": Array(repeating: 1_000, count: max(0, payload.count - 1)),
                type == "tool-call-chunks" ? "args" : "texts": payload,
            ] as [String: Any],
        ])
    }

    private func assistantMessageData(id: String = "assistant-1") -> [String: Any] {
        ["turn": 1, "step": 1,
         "message": ["id": id, "role": "assistant",
                     "content": [["type": "text", "text": "done"] as [String: Any]],
                     "source": ["kind": "model", "provider": "p", "model": "m"] as [String: Any]
                    ] as [String: Any]]
    }

    private func chunkData(turn: Int = 1, step: Int = 1, chunk: [String: Any]) -> [String: Any] {
        ["turn": turn, "step": step, "chunk": chunk]
    }

    private func userData(id: String = "user-1", text: String = "hello") -> [String: Any] {
        ["id": id, "role": "user",
         "content": [["type": "text", "text": text] as [String: Any]],
         "source": ["kind": "user"] as [String: Any]]
    }

    // MARK: - Strict v1 admission

    func testV1UnknownIgnorableEventIsRefused() throws {
        for ignorable in [false, true] {
            let rows: [DeepSeekHarnessPhysicalRow] = [
                .event(envelope("turn/start", 0, data: ["turn": 1])),
                .event(envelope("x-synth/old", 1, data: ["text": "unknown"], ignorable: ignorable)),
            ]
            XCTAssertThrowsError(try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))) { error in
                guard case .unsupportedMigration(let detail) = error as? DeepSeekHarnessFormatError else {
                    return XCTFail("expected unsupportedMigration, got \(error)")
                }
                XCTAssertTrue(detail.contains("format v1 contains unknown event type"), detail)
                XCTAssertTrue(detail.contains("x-synth/old"), detail)
            }
        }
    }

    // MARK: - Interrupted-turn repair

    private func splicedData(inserted: [[String: Any]]) -> [String: Any] {
        ["target": "next-turn", "start": 0, "inserted": inserted]
    }

    func testV1InterruptedTurnSynthesizesCanonicalEnd() throws {
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("step/end", 2, data: ["turn": 1, "step": 1])),
            .event(envelope("agent/inbox/spliced", 3, data: splicedData(inserted: [userData()]))),
            .event(envelope("turn/start", 4, data: ["turn": 2])),
            .event(envelope("turn/end", 5, data: ["turn": 2, "reason": ["kind": "completed"] as [String: Any]])),
        ]
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))
        XCTAssertEqual(normalized.map(\.canonicalType),
                       ["turn/start", "step/start", "system/message", "step/end", "agent/inbox/spliced",
                        "turn/end", "turn/start", "turn/end"])
        XCTAssertEqual(normalized.map(\.envelope.sequence), Array(0..<8))
        let generated = normalized[5]
        XCTAssertEqual(generated.data["turn"] as? Int, 1)
        XCTAssertEqual((generated.data["reason"] as? [String: Any])?["kind"] as? String, "interrupted")
    }

    func testV1OverlappingTurnWithoutSpliceIsRefused() throws {
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("turn/start", 1, data: ["turn": 2])),
        ]
        XCTAssertThrowsError(try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))) { error in
            guard case .unsupportedMigration(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected unsupportedMigration, got \(error)")
            }
            XCTAssertTrue(detail.contains("does not close the prior turn"), detail)
        }
    }

    func testV1InterruptedPatternWithOpenStepIsRefused() throws {
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("agent/inbox/spliced", 2, data: splicedData(inserted: [userData()]))),
            .event(envelope("turn/start", 3, data: ["turn": 2])),
        ]
        XCTAssertThrowsError(try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))) { error in
            guard case .unsupportedMigration(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected unsupportedMigration, got \(error)")
            }
            XCTAssertTrue(detail.contains("does not close the prior turn"), detail)
        }
    }

    func testV1EmptySpliceInsertIsRefused() throws {
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("step/end", 2, data: ["turn": 1, "step": 1])),
            .event(envelope("agent/inbox/spliced", 3, data: splicedData(inserted: []))),
            .event(envelope("turn/start", 4, data: ["turn": 2])),
        ]
        XCTAssertThrowsError(try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))) { error in
            guard case .unsupportedMigration(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected unsupportedMigration, got \(error)")
            }
            XCTAssertTrue(detail.contains("does not close the prior turn"), detail)
        }
    }

    // MARK: - Assistant-stream coalescing

    func testV1RawChunksPackWithExactCoalescing() throws {
        let t0: Int64 = 1_000_000
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("assistant/chunk", 2, time: t0, data: chunkData(chunk: [
                "type": "text-delta", "index": 0, "text": "hel",
            ]))),
            .event(envelope("assistant/chunk", 3, time: t0 + 6, data: chunkData(chunk: [
                "type": "text-delta", "index": 0, "text": "lo",
            ]))),
            .event(envelope("assistant/chunk", 4, time: t0 + 8, data: chunkData(chunk: [
                "type": "tool-call-delta", "index": 1, "id": "call-1",
                "name": "run_code", "argumentsDelta": "{",
            ]))),
            .event(envelope("assistant/chunk", 5, time: t0 + 11, data: chunkData(chunk: [
                "type": "tool-call-delta", "index": 1, "id": "call-1",
                "name": "run_code", "argumentsDelta": "}",
            ]))),
            .event(envelope("assistant/chunk", 6, time: t0 + 20, data: chunkData(chunk: [
                "type": "finish", "reason": ["kind": "stop"] as [String: Any],
            ]))),
            .event(envelope("assistant/message", 7, data: assistantMessageData(),
                            sourceEventSeqs: [2, 3, 4, 5, 6], surfaceOp: .append)),
            .event(envelope("step/end", 8, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 9, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])),
        ]
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))
        let messages = normalized.filter { $0.canonicalType == "assistant/message" }
        XCTAssertEqual(messages.count, 1)
        let stream = try XCTUnwrap(messages[0].data["stream"] as? [[String: Any]])
        XCTAssertEqual(stream.count, 3)
        XCTAssertEqual(stream[0]["type"] as? String, "text-chunks")
        XCTAssertEqual(stream[0]["time0"] as? Int64, t0)
        XCTAssertEqual(stream[0]["dt"] as? [Int], [6])
        XCTAssertEqual(stream[0]["texts"] as? [String], ["hel", "lo"])
        XCTAssertEqual(stream[1]["type"] as? String, "tool-call-chunks")
        XCTAssertEqual(stream[1]["id"] as? String, "call-1")
        XCTAssertEqual(stream[1]["name"] as? String, "run_code")
        XCTAssertEqual(stream[1]["dt"] as? [Int], [3])
        XCTAssertEqual(stream[1]["args"] as? [String], ["{", "}"])
        XCTAssertEqual(stream[2]["type"] as? String, "chunk")
        XCTAssertEqual((stream[2]["chunk"] as? [String: Any])?["type"] as? String, "finish")
        XCTAssertTrue(normalized.filter { $0.canonicalType == "assistant/attempt" }.isEmpty)
    }

    func testV1MixedPackedAndRawBoundariesStaySeparate() throws {
        let t0: Int64 = 2_000_000
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .packed(try packedRun(type: "text-chunks", sequence: 2, time: t0, payload: ["packed"])),
            .event(envelope("assistant/chunk", 3, time: t0 + 10, data: chunkData(chunk: [
                "type": "text-delta", "index": 1, "text": "a",
            ]))),
            .event(envelope("assistant/chunk", 4, time: t0 + 12, data: chunkData(chunk: [
                "type": "text-delta", "index": 1, "text": "b",
            ]))),
            .packed(try packedRun(type: "reasoning-chunks", sequence: 5, time: t0 + 20, payload: ["flush"])),
            .event(envelope("assistant/message", 6, data: assistantMessageData(),
                            sourceEventSeqs: [2, 3, 4, 5], surfaceOp: .append)),
            .event(envelope("step/end", 7, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 8, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])),
        ]
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))
        let messages = normalized.filter { $0.canonicalType == "assistant/message" }
        XCTAssertEqual(messages.count, 1)
        let stream = try XCTUnwrap(messages[0].data["stream"] as? [[String: Any]])
        XCTAssertEqual(stream.compactMap { $0["type"] as? String },
                       ["text-chunks", "text-chunks", "reasoning-chunks"])
        XCTAssertEqual(stream[0]["texts"] as? [String], ["packed"])
        XCTAssertEqual(stream[1]["texts"] as? [String], ["a", "b"])
        XCTAssertEqual(stream[1]["dt"] as? [Int], [2])
        XCTAssertEqual(stream[2]["texts"] as? [String], ["flush"])
    }

    func testV1IncompatibleToolCallRunsStaySeparate() throws {
        let t0: Int64 = 3_000_000
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("assistant/chunk", 2, time: t0, data: chunkData(chunk: [
                "type": "tool-call-delta", "index": 0, "id": "one", "argumentsDelta": "{",
            ]))),
            .event(envelope("assistant/chunk", 3, time: t0 + 1, data: chunkData(chunk: [
                "type": "tool-call-delta", "index": 0, "id": "one", "argumentsDelta": "}",
            ]))),
            .event(envelope("assistant/chunk", 4, time: t0 + 2, data: chunkData(chunk: [
                "type": "tool-call-delta", "index": 0, "id": "one",
                "name": "read", "argumentsDelta": "",
            ]))),
            .event(envelope("assistant/chunk", 5, time: t0 + 3, data: chunkData(chunk: [
                "type": "finish", "reason": ["kind": "stop"] as [String: Any],
            ]))),
            .event(envelope("assistant/message", 6, data: assistantMessageData(),
                            sourceEventSeqs: [2, 3, 4, 5], surfaceOp: .append)),
            .event(envelope("step/end", 7, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 8, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])),
        ]
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))
        let messages = normalized.filter { $0.canonicalType == "assistant/message" }
        XCTAssertEqual(messages.count, 1)
        let stream = try XCTUnwrap(messages[0].data["stream"] as? [[String: Any]])
        // The nameless run and the named run never coalesce; finish stays raw.
        XCTAssertEqual(stream.compactMap { $0["type"] as? String },
                       ["tool-call-chunks", "tool-call-chunks", "chunk"])
        XCTAssertNil(stream[0]["name"])
        XCTAssertEqual(stream[1]["name"] as? String, "read")
    }

    func testV1TerminalFinishSeparatesAttempts() throws {
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("assistant/chunk", 2, data: chunkData(chunk: [
                "type": "text-delta", "index": 0, "text": "first",
            ]))),
            .event(envelope("assistant/chunk", 3, data: chunkData(chunk: [
                "type": "finish", "reason": ["kind": "stop"] as [String: Any],
            ]))),
            .event(envelope("assistant/chunk", 4, data: chunkData(chunk: [
                "type": "text-delta", "index": 0, "text": "second",
            ]))),
            .event(envelope("assistant/chunk", 5, data: chunkData(chunk: [
                "type": "finish", "reason": ["kind": "stop"] as [String: Any],
            ]))),
            .event(envelope("assistant/message", 6, data: assistantMessageData(),
                            sourceEventSeqs: [4, 5], surfaceOp: .append)),
            .event(envelope("step/end", 7, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 8, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])),
        ]
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))
        let attempts = normalized.filter { $0.canonicalType == "assistant/attempt" }
        XCTAssertEqual(attempts.count, 1)
        let attemptStream = try XCTUnwrap(attempts[0].data["stream"] as? [[String: Any]])
        XCTAssertEqual((attemptStream[0]["texts"] as? [String]), ["first"])
        let messages = normalized.filter { $0.canonicalType == "assistant/message" }
        XCTAssertEqual(messages.count, 1)
        let messageStream = try XCTUnwrap(messages[0].data["stream"] as? [[String: Any]])
        XCTAssertEqual((messageStream[0]["texts"] as? [String]), ["second"])
    }

    // MARK: - End-to-end generated sequencing and remapping

    func testV1InterleavedStreamRemapsSurvivorsEndToEnd() throws {
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("assistant/chunk", 2, data: chunkData(chunk: [
                "type": "text-delta", "index": 0, "text": "hello",
            ]))),
            .event(envelope("feedback/record", 3, data: ["text": "interleaved"])),
            .event(envelope("assistant/chunk", 4, data: chunkData(chunk: [
                "type": "finish", "reason": ["kind": "stop"] as [String: Any],
            ]))),
            .event(envelope("assistant/message", 5, data: assistantMessageData(),
                            sourceEventSeqs: [2, 4], surfaceOp: .append)),
            .event(envelope("step/end", 6, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 7, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])),
            .event(envelope("command/run", 8, data: [
                "commandId": "command-1", "name": "inspect", "source": ["kind": "user"] as [String: Any],
            ])),
            .event(envelope("command/done", 9, data: [
                "commandId": "command-1", "kind": "success", "sourceEventSeq": 5,
            ])),
        ]
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))
        // Consumed chunks vanish; the buffered feedback slides ahead of the
        // settled message; every survivor is dense and remapped.
        XCTAssertEqual(normalized.map(\.canonicalType),
                       ["turn/start", "step/start", "system/message", "feedback/record", "assistant/message",
                        "step/end", "turn/end", "command/run", "command/done"])
        XCTAssertEqual(normalized.map(\.envelope.sequence), Array(0..<9))
        let message = normalized[4]
        let stream = try XCTUnwrap(message.data["stream"] as? [[String: Any]])
        XCTAssertEqual(stream.count, 2)
        XCTAssertEqual(stream[0]["type"] as? String, "text-chunks")
        XCTAssertEqual(stream[0]["texts"] as? [String], ["hello"])
        XCTAssertEqual(stream[1]["type"] as? String, "chunk")
        let done = normalized[8]
        XCTAssertEqual(done.data["sourceEventSeq"] as? Int, 4,
                       "command/done must cite the message at its target sequence")
    }

    func testV1RetryPrefixSeparatesAttemptsEndToEnd() throws {
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("request/header", 2, data: [
                "header": ["config": ["provider": "mock", "model": "mock"] as [String: Any]] as [String: Any],
                "reason": "initial",
            ])),
            .event(envelope("assistant/chunk", 3, data: chunkData(chunk: [
                "type": "text-delta", "index": 0, "text": "partial",
            ]))),
            .event(envelope("llm/retry", 4, data: [
                "retryId": "retry-1", "turn": 1, "step": 1, "provider": "mock",
                "mode": "normal", "policyKey": "default", "retry": 1, "maxRetries": 1,
                "delayMs": 0, "failure": ["code": "SERVER", "message": "retry"] as [String: Any],
            ])),
            .event(envelope("llm/retry-started", 5, data: [
                "retryId": "retry-1", "turn": 1, "step": 1, "retry": 1,
            ])),
            .event(envelope("assistant/chunk", 6, data: chunkData(chunk: [
                "type": "text-delta", "index": 0, "text": "hello",
            ]))),
            .event(envelope("assistant/chunk", 7, data: chunkData(chunk: [
                "type": "finish", "reason": ["kind": "stop"] as [String: Any],
            ]))),
            .event(envelope("assistant/message", 8, data: assistantMessageData(),
                            sourceEventSeqs: [6, 7], surfaceOp: .append)),
            .event(envelope("step/end", 9, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 10, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])),
        ]
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(result(rows: rows))
        let assistants = normalized.filter {
            $0.canonicalType == "assistant/attempt" || $0.canonicalType == "assistant/message"
        }
        XCTAssertEqual(assistants.map(\.canonicalType), ["assistant/attempt", "assistant/message"])
        // The failed prefix settles as a generated attempt at its own target
        // sequence, ahead of the retry markers.
        XCTAssertEqual(assistants[0].envelope.sequence, 4)
        let attemptStream = try XCTUnwrap(assistants[0].data["stream"] as? [[String: Any]])
        XCTAssertEqual(attemptStream[0]["texts"] as? [String], ["partial"])
        let messageStream = try XCTUnwrap(assistants[1].data["stream"] as? [[String: Any]])
        XCTAssertEqual(messageStream[0]["texts"] as? [String], ["hello"])
        XCTAssertEqual(messageStream[1]["type"] as? String, "chunk")
        XCTAssertEqual(normalized.map(\.envelope.sequence), Array(0..<normalized.count))
    }
}
