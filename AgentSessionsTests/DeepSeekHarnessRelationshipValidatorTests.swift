import Foundation
import XCTest
@testable import AgentSessions

/// Focused coverage for `DeepSeekHarnessRelationshipValidator`: the
/// source-faithful cross-event checks required before v3 publication,
/// ported from staged `v0-to-v1/relationships.ts` with the publication
/// extensions (`assistant/attempt` as a step event, preserved
/// title-request text).
final class DeepSeekHarnessRelationshipValidatorTests: XCTestCase {
    private let baseTime: Int64 = 1_700_000_000_000

    private func header(
        id: String = "dsh-rel-test",
        isSeeded: Bool = false,
        parentSessionID: String? = nil
    ) -> DeepSeekHarnessHeader {
        DeepSeekHarnessHeader(
            version: 3, id: id, createdAtMilliseconds: baseTime,
            cwd: "/tmp/dsh-tests", parentSessionID: parentSessionID,
            isSeeded: isSeeded, origin: nil, delegationDepth: 0, agentPreset: nil)
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
            type: type, sequence: sequence,
            timeMilliseconds: baseTime + Int64(sequence * 1_000),
            data: data, ignorable: ignorable,
            sourceEventSeqs: sourceEventSeqs, surfaceOp: surfaceOp)
    }

    private func userData(id: String = "user-1", text: String = "hello",
                          kind: String = "user") -> [String: Any] {
        ["id": id, "role": "user",
         "content": [["type": "text", "text": text] as [String: Any]],
         "source": ["kind": kind] as [String: Any]]
    }

    private func assistantData(id: String = "assistant-1",
                               toolCall: (id: String, name: String, args: String)? = nil) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": "done"]]
        if let toolCall {
            content.append(["type": "tool-call", "id": toolCall.id,
                            "name": toolCall.name, "arguments": toolCall.args])
        }
        return ["turn": 1, "step": 1,
                "message": ["id": id, "role": "assistant", "content": content,
                            "source": ["kind": "model", "provider": "p", "model": "m"] as [String: Any]
                           ] as [String: Any],
                "stream": [] as [Any]]
    }

    private func check(_ events: [DeepSeekHarnessEnvelope],
                       header: DeepSeekHarnessHeader? = nil) throws {
        try DeepSeekHarnessRelationshipValidator.assertPublishableRelationships(
            events, header: header ?? self.header())
    }

    private func requireInvalidPayload(_ events: [DeepSeekHarnessEnvelope],
                                       header: DeepSeekHarnessHeader? = nil,
                                       match: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertThrowsError(try check(events, header: header), file: file, line: line) { error in
            guard case .invalidPayload(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected invalidPayload, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(detail.contains(match), detail, file: file, line: line)
        }
    }

    // MARK: - Turn/step lifecycle

    private func baseSession(extra: [DeepSeekHarnessEnvelope] = []) -> [DeepSeekHarnessEnvelope] {
        [envelope("turn/start", 0, data: ["turn": 1]),
         envelope("step/start", 1, data: ["turn": 1, "step": 1]),
         envelope("user/message", 2, data: userData(), surfaceOp: .append),
         envelope("assistant/message", 3, data: assistantData(), surfaceOp: .append),
         envelope("step/end", 4, data: ["turn": 1, "step": 1]),
         envelope("turn/end", 5, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])]
            + extra
    }

    func testValidSessionPasses() throws {
        try check(baseSession())
    }

    func testTurnStartOutOfOrderFails() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 2]),
        ], match: "does not open expected turn 1")
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("turn/start", 1, data: ["turn": 2]),
        ], match: "does not open expected turn")
    }

    func testStepOutsideTurnFails() {
        requireInvalidPayload([
            envelope("step/start", 0, data: ["turn": 1, "step": 1]),
        ], match: "does not match the open turn and next step")
    }

    func testTurnEndCrossingOpenStepFails() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("turn/end", 2, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ], match: "crosses an open step")
    }

    func testStepEndWithoutOpenStepFails() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/end", 1, data: ["turn": 1, "step": 1]),
        ], match: "does not match an open turn and step")
    }

    func testAttemptRequiresOpenStep() throws {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("assistant/attempt", 1, data: ["turn": 1, "step": 1, "stream": [] as [Any]]),
        ], match: "does not match an open turn and step")
        try check([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("assistant/attempt", 2, data: ["turn": 1, "step": 1, "stream": [] as [Any]]),
            envelope("step/end", 3, data: ["turn": 1, "step": 1]),
            envelope("turn/end", 4, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ])
    }

    // MARK: - Assistant/tool-call lifecycle

    func testToolCallWithoutAdvertisementFails() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("tool/call", 2, data: ["turn": 1, "step": 1, "callId": "call-1",
                                            "name": "read", "arguments": "{}"]),
        ], match: "does not match one advertised tool call")
    }

    func testToolResultWithoutLifecycleFails() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("tool/result", 2, data: ["turn": 1, "step": 1,
                                              "message": ["id": "r-1", "role": "user",
                                                          "content": [["type": "tool-result", "toolCallId": "call-1",
                                                                       "content": [["type": "text", "text": "out"] as [String: Any]],
                                                                       "isError": false] as [String: Any]],
                                                          "source": ["kind": "tool", "callId": "call-1"] as [String: Any]
                                                         ] as [String: Any]],
                     surfaceOp: .append),
        ], match: "has no advertised tool lifecycle")
    }

    func testUnresolvedToolAtStepEndFails() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("assistant/message", 2, data: assistantData(toolCall: (id: "call-1", name: "read", args: "{}")),
                     surfaceOp: .append),
            envelope("step/end", 3, data: ["turn": 1, "step": 1]),
        ], match: "leaves unresolved tool call call-1")
    }

    func testAdvertisedButUnstartedNonRepairFails() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("assistant/message", 2, data: assistantData(toolCall: (id: "call-1", name: "read", args: "{}")),
                     surfaceOp: .append),
            envelope("tool/result", 3, data: ["turn": 1, "step": 1,
                                              "message": ["id": "r-1", "role": "user",
                                                          "content": [["type": "tool-result", "toolCallId": "call-1",
                                                                       "content": [["type": "text", "text": "out"] as [String: Any]],
                                                                       "isError": false] as [String: Any]],
                                                          "source": ["kind": "tool", "callId": "call-1"] as [String: Any]
                                                         ] as [String: Any]],
                     surfaceOp: .append),
        ], match: "is not the exact TOOL_NOT_STARTED repair")
    }

    func testExactToolNotStartedRepairPasses() throws {
        try check([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("assistant/message", 2, data: assistantData(toolCall: (id: "call-9", name: "read", args: "{}")),
                     surfaceOp: .append),
            envelope("tool/result", 3, data: ["turn": 1, "step": 1,
                                              "message": ["id": "interrupted-tool-result-call-9-3", "role": "user",
                                                          "content": [["type": "tool-result", "toolCallId": "call-9",
                                                                       "content": [["type": "text",
                                                                                    "text": "The tool call was interrupted before the Harness recorded it as started. Retry it if it is still needed."] as [String: Any]],
                                                                       "isError": true] as [String: Any]],
                                                          "source": ["kind": "tool", "callId": "call-9"] as [String: Any]
                                                         ] as [String: Any],
                                              "error": ["name": "ToolNotStartedError",
                                                        "code": "TOOL_NOT_STARTED"] as [String: Any]],
                     surfaceOp: .append),
            envelope("step/end", 4, data: ["turn": 1, "step": 1]),
            envelope("turn/end", 5, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ])
    }

    // MARK: - Retry pairing

    private func retrySession(header eventHeader: [String: Any]? = nil) -> [DeepSeekHarnessEnvelope] {
        var events = [
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
        ]
        if let eventHeader {
            events.append(envelope("request/header", 2, data: eventHeader))
        }
        return events
    }

    private func retryData(retry: Int, provider: String = "p",
                           retryID: String = "retry-1") -> [String: Any] {
        ["retryId": retryID, "turn": 1, "step": 1, "provider": provider,
         "mode": "normal", "policyKey": "k", "retry": retry, "delayMs": 0,
         "failure": ["code": "E", "message": "boom"] as [String: Any]]
    }

    private func requestData(provider: String = "p") -> [String: Any] {
        ["header": ["config": ["provider": provider, "model": "m"] as [String: Any]] as [String: Any],
         "reason": "initial"]
    }

    func testRetryRequiresProviderMatchAndChain() throws {
        // Wrong provider fails even with a valid chain shape.
        requireInvalidPayload(
            retrySession(header: requestData(provider: "p"))
                + [envelope("llm/retry", 3, data: retryData(retry: 1, provider: "q"))],
            match: "does not match the open request/header")
        // First retry must be number one.
        requireInvalidPayload(
            retrySession(header: requestData())
                + [envelope("llm/retry", 3, data: retryData(retry: 2))],
            match: "must use retry 1")
        // A valid schedule/start pair passes.
        try check(
            retrySession(header: requestData())
                + [envelope("llm/retry", 3, data: retryData(retry: 1)),
                   envelope("llm/retry-started", 4, data: ["retryId": "retry-1", "turn": 1,
                                                           "step": 1, "retry": 1])])
        // Retry id must be preserved across one policy chain.
        requireInvalidPayload(
            retrySession(header: requestData())
                + [envelope("llm/retry", 3, data: retryData(retry: 1)),
                   envelope("llm/retry", 4, data: retryData(retry: 2, retryID: "retry-2"))],
            match: "must preserve retryId")
        // A repeated start for one scheduled attempt fails.
        requireInvalidPayload(
            retrySession(header: requestData())
                + [envelope("llm/retry", 3, data: retryData(retry: 1)),
                   envelope("llm/retry-started", 4, data: ["retryId": "retry-1", "turn": 1,
                                                           "step": 1, "retry": 1]),
                   envelope("llm/retry-started", 5, data: ["retryId": "retry-1", "turn": 1,
                                                           "step": 1, "retry": 1])],
            match: "repeats one scheduled attempt")
        // A start with no scheduled attempt fails.
        requireInvalidPayload(
            retrySession(header: requestData())
                + [envelope("llm/retry-started", 3, data: ["retryId": "retry-9", "turn": 1,
                                                           "step": 1, "retry": 1])],
            match: "pairs no prior scheduled attempt")
    }

    // MARK: - PTC dispatch hierarchy

    private func ptcStartData(child: String = "sub", parent: String = "root",
                              args: [String: Any] = ["path": "a"]) -> [String: Any] {
        ["rootCallId": "root", "parentCallId": parent, "subCallId": child,
         "name": "read", "arguments": args]
    }

    private func ptcDispatchData(child: String = "sub", parent: String = "root",
                                 args: [String: Any] = ["path": "a"]) -> [String: Any] {
        var data = ptcStartData(child: child, parent: parent, args: args)
        data["isError"] = false
        data["content"] = [["type": "text", "text": "out"] as [String: Any]]
        return data
    }

    func testPTCDispatchHierarchy() throws {
        let prefix = [
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
        ]
        try check(prefix + [
            envelope("tool/ptc-dispatch-start", 2, data: ptcStartData()),
            envelope("tool/ptc-dispatch", 3, data: ptcDispatchData()),
        ])
        requireInvalidPayload(prefix + [
            envelope("tool/ptc-dispatch", 2, data: ptcDispatchData()),
        ], match: "has no unique start")
        requireInvalidPayload(prefix + [
            envelope("tool/ptc-dispatch-start", 2, data: ptcStartData()),
            envelope("tool/ptc-dispatch", 3, data: ptcDispatchData(args: ["path": "b"])),
        ], match: "does not match its start")
        requireInvalidPayload(prefix + [
            envelope("tool/ptc-dispatch-start", 2, data: ptcStartData()),
            envelope("tool/ptc-dispatch-start", 3, data: ptcStartData()),
        ], match: "repeats subCallId")
        requireInvalidPayload(prefix + [
            envelope("tool/ptc-dispatch-start", 2, data: ptcStartData(child: "sub", parent: "root")),
            envelope("tool/ptc-dispatch-start", 3, data: ptcStartData(child: "leaf", parent: "elsewhere")),
        ], match: "does not belong to rootCallId")
    }

    // MARK: - Command references

    func testCommandReferences() throws {
        let prefix = [
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("user/message", 1, data: userData(), surfaceOp: .append),
        ]
        try check(prefix + [
            envelope("command/run", 2, data: ["commandId": "c-1", "name": "inspect",
                                              "source": ["kind": "user"] as [String: Any]]),
            envelope("command/done", 3, data: ["commandId": "c-1", "kind": "success",
                                               "sourceEventSeq": 1]),
        ])
        requireInvalidPayload(prefix + [
            envelope("command/done", 2, data: ["commandId": "c-1", "kind": "success"]),
        ], match: "has no prior command/run")
        requireInvalidPayload(prefix + [
            envelope("command/run", 2, data: ["commandId": "c-1", "name": "inspect",
                                              "source": ["kind": "user"] as [String: Any]]),
            envelope("command/run", 3, data: ["commandId": "c-1", "name": "inspect",
                                              "source": ["kind": "user"] as [String: Any]]),
        ], match: "repeats commandId")
        requireInvalidPayload(prefix + [
            envelope("command/run", 2, data: ["commandId": "c-1", "name": "inspect",
                                              "source": ["kind": "user"] as [String: Any]]),
            envelope("command/done", 3, data: ["commandId": "c-1", "kind": "error",
                                               "sourceEventSeq": 1]),
        ], match: "has invalid sourceEventSeq")
    }

    // MARK: - Delivery identity and seed boundaries

    func testDeliveryIdentity() throws {
        try check([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("session-log-deepseek/delivery-accepted", 1, data: [
                "sessionId": "dsh-rel-test", "throughSeq": 0, "sessionFormatVersion": 3,
            ]),
            envelope("turn/end", 2, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ])
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("session-log-deepseek/delivery-accepted", 1, data: [
                "sessionId": "other", "throughSeq": 0, "sessionFormatVersion": 3,
            ]),
        ], match: "names the wrong Session")
    }

    func testInheritedDeliveryPassesBeforeCut() throws {
        let seeded = header(isSeeded: true, parentSessionID: "parent")
        try check([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("session-log-deepseek/delivery-accepted", 1, data: [
                "sessionId": "parent", "throughSeq": 0, "sessionFormatVersion": 3,
            ]),
            envelope("session/end-seed", 2, data: ["inherited": true]),
            envelope("user/message", 3, data: userData(), surfaceOp: .append),
            envelope("turn/end", 4, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ], header: seeded)
    }

    func testSeedMarkerAgreement() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
        ], header: header(isSeeded: true, parentSessionID: "parent"),
        match: "lacks an inherited end-seed marker")
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("session/end-seed", 1, data: ["inherited": true]),
        ], match: "unseeded session contains an inherited end-seed marker")
    }

    func testStaleCompactionAllowsTurnAcrossSeed() throws {
        let seeded = header(isSeeded: true, parentSessionID: "parent")
        try check([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("compaction/start", 1, data: ["compactionId": "c", "turn": 1]),
            envelope("session/end-seed", 2, data: ["inherited": true]),
            envelope("turn/end", 3, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
            envelope("turn/start", 4, data: ["turn": 2]),
            envelope("step/start", 5, data: ["turn": 2, "step": 1]),
            envelope("step/end", 6, data: ["turn": 2, "step": 1]),
            envelope("turn/end", 7, data: ["turn": 2, "reason": ["kind": "completed"] as [String: Any]]),
        ], header: seeded)
    }

    // MARK: - Compaction ownership and surface spans

    private func compactionSession(summarySeqs: [Int] = [1],
                                   summaryRange: (Int, Int) = (1, 1)) -> [DeepSeekHarnessEnvelope] {
        [envelope("turn/start", 0, data: ["turn": 1]),
         envelope("user/message", 1, data: userData(), surfaceOp: .append),
         envelope("compaction/start", 2, data: ["compactionId": "c", "turn": 1]),
         envelope("compaction/summary", 3, data: [
            "compactionId": "c",
            "summary": [["type": "text", "text": "summary"] as [String: Any]],
            "shadowedRange": ["start": summaryRange.0, "end": summaryRange.1] as [String: Any],
            "shadowedSeqs": summarySeqs,
            "shadowedTokenCount": 1, "provider": "p", "model": "m",
         ]),
         envelope("user/message", 4, data: [
            "id": "compact", "role": "user",
            "content": [["type": "text", "text": "summary"] as [String: Any]],
            "source": ["kind": "plugin", "plugin": "compact", "compactionId": "c"] as [String: Any],
         ], sourceEventSeqs: [1], surfaceOp: .replace(start: 1, end: 1)),
         envelope("compaction/end", 5, data: ["compactionId": "c", "turn": 1]),
         envelope("turn/end", 6, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])]
    }

    func testCompactionLifecycle() throws {
        try check(compactionSession())
        requireInvalidPayload(compactionSession(summarySeqs: [2]),
                              match: "do not name an exact current surface span")
        let missingSummary = [
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("compaction/start", 1, data: ["compactionId": "c", "turn": 1]),
            envelope("compaction/end", 2, data: ["compactionId": "c", "turn": 1]),
        ]
        requireInvalidPayload(missingSummary, match: "requires one summary")
        let orphanSummary = [
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("compaction/summary", 1, data: [
                "compactionId": "c",
                "summary": [["type": "text", "text": "summary"] as [String: Any]],
                "shadowedRange": ["start": 0, "end": 0] as [String: Any],
                "shadowedSeqs": [0], "shadowedTokenCount": 1, "provider": "p", "model": "m",
            ]),
        ]
        requireInvalidPayload(orphanSummary, match: "has no matching compaction/start")
    }

    // MARK: - Surface replacement coverage

    func testSurfaceReplacementCoverage() {
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("user/message", 1, data: userData(), surfaceOp: .append),
            envelope("user/message", 2, data: userData(id: "user-2"), sourceEventSeqs: [1],
                     surfaceOp: .replace(start: 0, end: 0)),
        ], match: "replacement range is not on the current surface")
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("user/message", 1, data: userData(), surfaceOp: .append),
            envelope("user/message", 2, data: userData(id: "user-2"), surfaceOp: .append),
            envelope("user/message", 3, data: userData(id: "user-3"), sourceEventSeqs: [2],
                     surfaceOp: .replace(start: 1, end: 2)),
        ], match: "omit a shadowed surface node")
    }

    func testInvertedReplacementSpanOverReorderedSurfacePasses() throws {
        // Two-stage valid replacement: seq 3 first replaces seq 1 so the
        // live surface becomes [3, 2]; the later span start=3,end=2 is
        // numerically inverted but follows live-surface order. Admission
        // requires both endpoints to be earlier events only; order on the
        // live surface stays enforced by the relationship validator.
        let parseHeader = DeepSeekHarnessHeader(
            version: 3, id: "dsh-rel-reorder", createdAtMilliseconds: baseTime,
            cwd: "/tmp/dsh-tests", parentSessionID: nil, isSeeded: false,
            origin: nil, delegationDepth: 0, agentPreset: nil)
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("user/message", 1, data: userData(), surfaceOp: .append)),
            .event(envelope("user/message", 2, data: userData(id: "user-2"), surfaceOp: .append)),
            .event(envelope("user/message", 3, data: userData(id: "user-3"),
                            sourceEventSeqs: [1],
                            surfaceOp: .replaceV3(startSeq: 1, endSeq: 1))),
            .event(envelope("user/message", 4, data: userData(id: "user-4"),
                            sourceEventSeqs: [3, 2],
                            surfaceOp: .replaceV3(startSeq: 3, endSeq: 2))),
            .event(envelope("turn/end", 5, data: ["turn": 1,
                                                  "reason": ["kind": "completed"] as [String: Any]])),
        ]
        let parsed = DeepSeekHarnessParseResult(
            header: parseHeader, rows: rows, inheritedEventCount: 0,
            skippedIgnorableTypes: [], incompleteTurn: false)
        let normalized = try DeepSeekHarnessHistoricalNormalizer.normalize(parsed)
        XCTAssertEqual(normalized.map(\.canonicalType),
                       ["turn/start", "user/message", "user/message", "user/message",
                        "user/message", "turn/end"])
        XCTAssertEqual(normalized.map(\.envelope.sequence), Array(0..<6))
    }

    // MARK: - Title sources

    func testTitleSources() throws {
        try check([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("user/message", 1, data: userData(), surfaceOp: .append),
            envelope("session/title", 2, data: ["title": "Hello", "messageSeqs": [1],
                                                "source": ["kind": "fallback"] as [String: Any]]),
            envelope("turn/end", 3, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ])
        try check([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("user/message", 1, data: userData(), surfaceOp: .append),
            envelope("session/title-llm-request", 2, data: [
                "titleProvider": "t-1", "messageSeqs": [1],
                "route": ["provider": "p", "model": "m"] as [String: Any],
                "system": "title",
                "messages": [["id": "title-request", "role": "user",
                              "content": [["type": "text", "text": "framed"] as [String: Any]],
                              "source": ["kind": "plugin", "plugin": "dsh-session-title-llm"] as [String: Any]
                             ] as [String: Any]],
                "maxTokens": 20,
            ]),
            envelope("turn/end", 3, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ])
        // Empty messageSeqs is admitted exactly for a user title.
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("session/title", 1, data: ["title": "Hello", "messageSeqs": [] as [Int],
                                                "source": ["kind": "fallback"] as [String: Any]]),
        ], match: "must be empty exactly for a user title")
        // Title requests must cite earlier human messages.
        requireInvalidPayload([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("assistant/message", 2, data: assistantData(), surfaceOp: .append),
            envelope("session/title", 3, data: ["title": "Hello", "messageSeqs": [2],
                                                "source": ["kind": "fallback"] as [String: Any]]),
        ], match: "must cite earlier human user/message events")
    }

    // MARK: - Opaque events and strict publication

    func testOpaqueAndObsoleteEventsAreSkipped() throws {
        try check([
            envelope("turn/start", 0, data: ["turn": 1]),
            envelope("step/start", 1, data: ["turn": 1, "step": 1]),
            envelope("tool/code-dispatch", 2, data: ["note": "old"], ignorable: true),
            envelope("x-test/future", 3, data: ["anything": true], ignorable: true),
            envelope("step/end", 4, data: ["turn": 1, "step": 1]),
            envelope("turn/end", 5, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]]),
        ])
    }

    func testV3UnadvertisedToolCallRefusesPublication() throws {
        let parseHeader = DeepSeekHarnessHeader(
            version: 3, id: "dsh-rel-native", createdAtMilliseconds: baseTime,
            cwd: "/tmp/dsh-tests", parentSessionID: nil, isSeeded: false,
            origin: nil, delegationDepth: 0, agentPreset: nil)
        let rows: [DeepSeekHarnessPhysicalRow] = [
            .event(envelope("turn/start", 0, data: ["turn": 1])),
            .event(envelope("step/start", 1, data: ["turn": 1, "step": 1])),
            .event(envelope("tool/call", 2, data: ["turn": 1, "step": 1, "callId": "call-1",
                                                   "name": "read", "arguments": "{}"])),
            .event(envelope("step/end", 3, data: ["turn": 1, "step": 1])),
            .event(envelope("turn/end", 4, data: ["turn": 1, "reason": ["kind": "completed"] as [String: Any]])),
        ]
        let result = DeepSeekHarnessParseResult(
            header: parseHeader, rows: rows, inheritedEventCount: 0,
            skippedIgnorableTypes: [], incompleteTurn: false)
        XCTAssertThrowsError(try DeepSeekHarnessHistoricalNormalizer.normalize(result)) { error in
            guard case .invalidPayload(let detail) = error as? DeepSeekHarnessFormatError else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
            XCTAssertTrue(detail.contains("does not match one advertised tool call"), detail)
        }
    }
}
