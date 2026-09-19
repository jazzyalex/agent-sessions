import Foundation

struct DeepSeekHarnessNormalizedEvent {
    let envelope: DeepSeekHarnessEnvelope
    let canonicalType: String
    let diagnosticOnly: Bool

    var data: [String: Any] { envelope.data }
}

/// Ordered, in-memory-only normalization of released DSH formats. Physical
/// v0/v1 packed rows survive until the v1-to-v2 edge so they are folded once
/// into the embedded Assistant streams used by v2 and v3.
enum DeepSeekHarnessHistoricalNormalizer {
    static func normalizedHeader(_ header: DeepSeekHarnessHeader) -> DeepSeekHarnessHeader {
        guard header.version < 3 else { return header }
        return DeepSeekHarnessHeader(
            version: 3,
            id: header.id,
            createdAtMilliseconds: header.createdAtMilliseconds,
            cwd: header.cwd,
            parentSessionID: header.parentSessionID,
            isSeeded: header.isSeeded,
            origin: header.origin,
            delegationDepth: header.delegationDepth,
            agentPreset: header.agentPreset == "code" ? "ptc" : header.agentPreset
        )
    }

    static func normalize(_ result: DeepSeekHarnessParseResult) throws -> [DeepSeekHarnessNormalizedEvent] {
        var rows = result.rows
        var version = result.header.version

        if version == 0 {
            rows = try migrateV0ToV1(rows, header: result.header,
                                     inheritedEventCount: result.inheritedEventCount)
            version = 1
        }

        var events: [DeepSeekHarnessEnvelope]
        if version == 1 {
            events = try migrateV1ToV2(rows, header: result.header,
                                       inheritedEventCount: result.inheritedEventCount)
            version = 2
        } else {
            events = try rows.map { row in
                guard case .event(let event) = row else {
                    throw DeepSeekHarnessFormatError.unsupportedMigration(
                        "format v\(version) cannot contain released packed Assistant rows")
                }
                return event
            }
        }

        if version == 2 {
            // Strict v2 admission runs before migration so a v2-invalid
            // payload cannot become accepted merely because migration
            // drops or transforms the offending field.
            for event in events {
                try DeepSeekHarnessPayloadValidator.assertV2EventPreMigration(event)
            }
            events = try migrateV2ToV3(events, header: result.header,
                                       inheritedEventCount: result.inheritedEventCount)
            version = 3
        }
        guard version == 3 else { throw DeepSeekHarnessFormatError.unsupportedVersion(version) }

        let v3Header = normalizedHeader(result.header)
        try validateV3(events, header: v3Header)
        try DeepSeekHarnessRelationshipValidator.assertPublishableRelationships(
            events, header: v3Header)
        return events.map { event in
            let unknownIgnorable = !DeepSeekHarnessVocabulary.v3Known.contains(event.type) && event.ignorable
            return DeepSeekHarnessNormalizedEvent(
                envelope: event,
                canonicalType: event.type,
                diagnosticOnly: event.type == "assistant/attempt" || unknownIgnorable
            )
        }
    }

    // MARK: v0 -> v1

    private struct V0State {
        var messageIDs: [Int: String] = [:]
        var retryIDs: [String: String] = [:]
        var compactionID: String?
    }

    private static func migrateV0ToV1(
        _ rows: [DeepSeekHarnessPhysicalRow],
        header: DeepSeekHarnessHeader,
        inheritedEventCount: Int
    ) throws -> [DeepSeekHarnessPhysicalRow] {
        var state = V0State()
        return try rows.map { row in
            guard case .event(let source) = row else { return row }
            var event = source
            switch event.type {
            case "compact/start": event = replacing(event, type: "compaction/start")
            case "compact/summary": event = replacing(event, type: "compaction/summary")
            case "compact/end": event = replacing(event, type: "compaction/end")
            case "compact/prune": event = replacing(event, type: "compaction/prune")
            default: break
            }

            if event.type == "request/header-delta" || event.type == "mode/set" {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "format v0 contains unsupported legacy \(event.type) at seq \(event.sequence)")
            }
            if event.type == "request/header", event.data["reason"] as? String == "fallback" {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "format v0 contains unsupported request/header fallback at seq \(event.sequence)")
            }

            event = try normalizeV0Turn(event, sessionID: header.id)
            event = try normalizeV0Header(event)
            event = try normalizeV0Steering(event, sessionID: header.id)
            event = try normalizeV0Retry(event, sessionID: header.id, state: &state)
            event = try normalizeV0Compaction(event, sessionID: header.id, state: &state)
            event = try normalizeV0Message(event, sessionID: header.id, messageIDs: state.messageIDs)

            // Released v0 admission runs after legacy normalization (except
            // assistant/chunk), ported from `normalizeReleasedV0Event`:
            // extra/missing/wrong-typed members fail here before the
            // normalized shape can flow into the v1 stage.
            if event.type != "assistant/chunk" {
                try DeepSeekHarnessPayloadValidator.assertReleasedV0EventPayload(event, version: 0)
            }

            if event.type == "session-log-deepseek/delivery-accepted" {
                let acceptedVersion = DeepSeekHarnessJSON.safeInt(event.data["sessionFormatVersion"]) ?? 0
                let inherited = header.parentSessionID != nil && event.sequence < inheritedEventCount
                if acceptedVersion == 0 && !inherited && event.data["sessionId"] as? String != header.id {
                    throw DeepSeekHarnessFormatError.invalidReference(
                        "current-generation delivery marker names the wrong session")
                }
            }
            if let id = messageID(in: event) { state.messageIDs[event.sequence] = id }
            return .event(event)
        }
    }

    private static func normalizeV0Turn(
        _ event: DeepSeekHarnessEnvelope,
        sessionID: String
    ) throws -> DeepSeekHarnessEnvelope {
        if event.type == "turn/start", event.data["trigger"] != nil {
            // Exact pre-transform admission: a smuggled extra member must
            // fail here because the lossy rewrite below drops `trigger`.
            try DeepSeekHarnessPayloadValidator.keys(
                event.data, required: ["turn", "trigger"], optional: [],
                label: "turn/start \(event.sequence) data")
            guard let turn = positiveCoordinate(event.data["turn"]),
                  let trigger = event.data["trigger"] as? [String: Any],
                  let kind = trigger["kind"] as? String, !kind.isEmpty else {
                throw malformedLegacy(sessionID, event)
            }
            return replacing(event, data: ["turn": turn])
        }
        guard event.type == "turn/end" else { return event }
        try DeepSeekHarnessPayloadValidator.keys(
            event.data, required: ["turn", "reason"], optional: [],
            label: "turn/end \(event.sequence) data")
        guard let turn = positiveCoordinate(event.data["turn"]),
              let reason = event.data["reason"] as? [String: Any],
              let kind = reason["kind"] as? String else {
            throw malformedLegacy(sessionID, event)
        }
        var normalized = reason
        switch kind {
        case "completed", "blocked", "max-tokens", "interrupted":
            try DeepSeekHarnessPayloadValidator.keys(
                reason, required: ["kind"], optional: [],
                label: "turn/end \(event.sequence) reason")
            return event
        case "aborted" where reason["reason"] != nil:
            return event
        case "aborted" where reason["reason"] == nil:
            try DeepSeekHarnessPayloadValidator.keys(
                reason, required: ["kind"], optional: [],
                label: "turn/end \(event.sequence) reason")
            normalized = ["kind": "aborted", "reason": ["kind": "legacy"]]
        case "disposed":
            try DeepSeekHarnessPayloadValidator.keys(
                reason, required: ["kind"], optional: [],
                label: "turn/end \(event.sequence) reason")
            normalized = ["kind": "aborted", "reason": ["kind": "disposed"]]
        case "error" where reason["error"] != nil:
            return event
        case "error" where reason["error"] == nil:
            normalized = try normalizeV0ErrorReason(reason, event: event, sessionID: sessionID)
        default: break
        }
        var data = event.data
        data["turn"] = turn
        data["reason"] = normalized
        return replacing(event, data: data)
    }

    /// Ports `normalizeLegacyErrorReason`: exact key admission for both the
    /// failure and message variants before the lossy `step` drop.
    private static func normalizeV0ErrorReason(
        _ reason: [String: Any],
        event: DeepSeekHarnessEnvelope,
        sessionID: String
    ) throws -> [String: Any] {
        guard DeepSeekHarnessJSON.count(reason["step"]) != nil else {
            throw malformedLegacy(sessionID, event)
        }
        if reason["failure"] != nil {
            try DeepSeekHarnessPayloadValidator.keys(
                reason, required: ["kind", "step", "failure"], optional: [],
                label: "turn/end \(event.sequence) reason")
            guard let failure = reason["failure"] as? [String: Any] else {
                throw malformedLegacy(sessionID, event)
            }
            try DeepSeekHarnessPayloadValidator.keys(
                failure, required: ["message", "code"],
                optional: ["status", "providerRetryAfterMs", "requestId"],
                label: "turn/end \(event.sequence) failure")
            guard failure["message"] is String, failure["code"] is String else {
                throw malformedLegacy(sessionID, event)
            }
            return ["kind": "error", "error": failure]
        }
        try DeepSeekHarnessPayloadValidator.keys(
            reason, required: ["kind", "step", "message"], optional: ["code"],
            label: "turn/end \(event.sequence) reason")
        guard let message = reason["message"] as? String,
              reason["code"] == nil || reason["code"] is String else {
            throw malformedLegacy(sessionID, event)
        }
        return [
            "kind": "error",
            "error": ["message": message, "code": reason["code"] as? String ?? "UNKNOWN"]
        ]
    }

    private static func normalizeV0Header(_ event: DeepSeekHarnessEnvelope) throws -> DeepSeekHarnessEnvelope {
        guard event.type == "request/header",
              var header = event.data["header"] as? [String: Any],
              header["messagePrefix"] != nil else { return event }
        guard header["messagePrefix"] is [Any] else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "request/header \(event.sequence) messagePrefix must be an array")
        }
        header.removeValue(forKey: "messagePrefix")
        var data = event.data
        data["header"] = header
        return replacing(event, data: data)
    }

    private static func normalizeV0Steering(
        _ event: DeepSeekHarnessEnvelope,
        sessionID: String
    ) throws -> DeepSeekHarnessEnvelope {
        guard event.type == "steering/message" else { return event }
        if event.data["message"] != nil {
            // Exact pre-transform admission: the lossy rewrite keeps only
            // `message`, so any other member must fail before it is dropped.
            guard let wrapped = event.data["message"] as? [String: Any] else {
                throw malformedLegacy(sessionID, event)
            }
            try DeepSeekHarnessPayloadValidator.keys(
                event.data, required: ["turn", "message"], optional: [],
                label: "steering/message \(event.sequence) data")
            guard DeepSeekHarnessJSON.count(event.data["turn"]) != nil else {
                throw malformedLegacy(sessionID, event)
            }
            return replacing(event, type: "user/message", data: wrapped)
        }
        try DeepSeekHarnessPayloadValidator.keys(
            event.data, required: ["turn", "content", "source"], optional: [],
            label: "steering/message \(event.sequence) data")
        guard DeepSeekHarnessJSON.count(event.data["turn"]) != nil,
              event.data["content"] != nil, event.data["source"] != nil else {
            throw malformedLegacy(sessionID, event)
        }
        var message = event.data
        message.removeValue(forKey: "turn")
        message["id"] = "legacy-message:\(sessionID):\(event.sequence)"
        message["role"] = "user"
        return replacing(event, type: "user/message", data: message)
    }

    private static func normalizeV0Retry(
        _ event: DeepSeekHarnessEnvelope,
        sessionID: String,
        state: inout V0State
    ) throws -> DeepSeekHarnessEnvelope {
        guard event.type == "llm/retry" else { return event }
        let values = ["turn", "step", "provider", "policyKey"].map { event.data[$0] ?? NSNull() }
        guard let chain = DeepSeekHarnessJSON.canonicalString(values) else {
            throw DeepSeekHarnessFormatError.invalidPayload("llm/retry chain is not JSON")
        }
        if let existing = event.data["retryId"] as? String, !existing.isEmpty {
            state.retryIDs[chain] = existing
            return event
        }
        if event.data.keys.contains("retryId") { return event }
        let id = state.retryIDs[chain] ?? "legacy-retry:\(sessionID):\(event.sequence)"
        state.retryIDs[chain] = id
        var data = event.data
        data["retryId"] = id
        return replacing(event, data: data)
    }

    private static func normalizeV0Compaction(
        _ event: DeepSeekHarnessEnvelope,
        sessionID: String,
        state: inout V0State
    ) throws -> DeepSeekHarnessEnvelope {
        if event.type == "session/end-seed" {
            state.compactionID = nil
            return event
        }
        if event.type == "compaction/start" {
            if let id = event.data["compactionId"] as? String, !id.isEmpty {
                state.compactionID = id
                return event
            }
            if event.data.keys.contains("compactionId") { return event }
            let id = "legacy-compaction:\(sessionID):\(event.sequence)"
            state.compactionID = id
            var data = event.data
            data["compactionId"] = id
            return replacing(event, data: data)
        }
        guard let id = state.compactionID else { return event }
        if event.type == "compaction/summary" || event.type == "compaction/end" {
            var data = event.data
            if data["compactionId"] == nil { data["compactionId"] = id }
            if event.type == "compaction/end" { state.compactionID = nil }
            return replacing(event, data: data)
        }
        guard event.type == "user/message",
              var source = event.data["source"] as? [String: Any],
              source["kind"] as? String == "plugin",
              source["plugin"] as? String == "compact",
              source["compactionId"] == nil else { return event }
        source["compactionId"] = id
        var data = event.data
        data["source"] = source
        return replacing(event, data: data)
    }

    private static func normalizeV0Message(
        _ event: DeepSeekHarnessEnvelope,
        sessionID: String,
        messageIDs: [Int: String]
    ) throws -> DeepSeekHarnessEnvelope {
        switch event.type {
        case "user/message":
            guard event.data["id"] == nil, event.data["role"] == nil,
                  event.data["message"] == nil,
                  event.data["content"] != nil, event.data["source"] != nil else { return event }
            var data = event.data
            data["id"] = "legacy-message:\(sessionID):\(event.sequence)"
            data["role"] = "user"
            return replacing(event, data: data)
        case "assistant/message":
            guard event.data["message"] == nil,
                  let content = event.data["content"],
                  let provenance = event.data["provenance"] as? [String: Any] else { return event }
            var data = event.data
            data.removeValue(forKey: "content")
            data.removeValue(forKey: "provenance")
            var source = provenance
            source["kind"] = "model"
            data["message"] = [
                "id": "legacy-message:\(sessionID):\(event.sequence)",
                "role": "assistant", "content": content, "source": source
            ]
            return replacing(event, data: data)
        case "tool/result":
            guard event.data["message"] == nil,
                  let callID = event.data["callId"] as? String,
                  let content = event.data["content"],
                  let isError = event.data["isError"] as? Bool else { return event }
            let id: String
            if let start = event.surfaceOp?.startValue {
                guard let prior = messageIDs[start] else {
                    throw DeepSeekHarnessFormatError.invalidReference(
                        "tool/result replacement cites a message without identity")
                }
                id = prior
            } else {
                id = "legacy-message:\(sessionID):\(event.sequence)"
            }
            var data = event.data
            data.removeValue(forKey: "callId")
            data.removeValue(forKey: "content")
            data.removeValue(forKey: "isError")
            data["message"] = [
                "id": id, "role": "user",
                "content": [["type": "tool-result", "toolCallId": callID,
                             "content": content, "isError": isError]],
                "source": ["kind": "tool", "callId": callID]
            ]
            return replacing(event, data: data)
        default: return event
        }
    }

    // MARK: v1 -> v2

    /// Compact assistant-stream accumulator ported from staged
    /// `llm/assistant-stream.ts` (`AssistantStreamAccumulator`).
    ///
    /// Raw v1 `assistant/chunk` payloads fold into packed `text-chunks`,
    /// `reasoning-chunks`, and `tool-call-chunks` runs with the exact
    /// upstream coalescing rules (same record type, same index, safe time
    /// gap; tool-call runs additionally require the same call id and the
    /// same name presence/value). Empty tool-call identities, block
    /// boundaries, usage, and finish payloads stay raw `chunk` records.
    private struct AssistantStreamAccumulator {
        private struct Record {
            var type: String
            var time0: Int64
            var index: Int
            var dt: [Int]
            var texts: [String]
            var id: String?
            var name: String?
            var hasName: Bool
            var chunk: [String: Any]?
            var lastTime: Int64
        }

        private var records: [Record] = []

        mutating func push(time: Int64, chunk: [String: Any]) throws {
            guard let chunkType = chunk["type"] as? String else {
                throw DeepSeekHarnessFormatError.invalidPayload("assistant stream chunk lacks a type")
            }
            switch chunkType {
            case "text-delta", "reasoning-delta":
                guard let index = DeepSeekHarnessJSON.count(chunk["index"]) else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(chunkType) index must be a non-negative safe integer")
                }
                guard let text = chunk["text"] as? String else {
                    throw DeepSeekHarnessFormatError.invalidPayload("\(chunkType) text must be a string")
                }
                let type = chunkType == "text-delta" ? "text-chunks" : "reasoning-chunks"
                let previous = records.last
                let gap = previous.flatMap {
                    $0.type == type ? safeStreamGap($0.lastTime, time) : nil
                }
                if let previous, previous.type == type, previous.index == index, let gap {
                    records[records.count - 1].dt.append(gap)
                    records[records.count - 1].texts.append(text)
                    records[records.count - 1].lastTime = time
                } else {
                    records.append(Record(type: type, time0: time, index: index, dt: [],
                                          texts: [text], id: nil, name: nil, hasName: false,
                                          chunk: nil, lastTime: time))
                }
            case "tool-call-delta":
                guard let index = DeepSeekHarnessJSON.count(chunk["index"]) else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "tool-call-delta index must be a non-negative safe integer")
                }
                guard let id = chunk["id"] as? String else {
                    throw DeepSeekHarnessFormatError.invalidPayload("tool-call-delta id must be a string")
                }
                if chunk.keys.contains("name"), chunk["name"] as? String == nil {
                    throw DeepSeekHarnessFormatError.invalidPayload("tool-call-delta name must be a string")
                }
                guard let delta = chunk["argumentsDelta"] as? String else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "tool-call-delta argumentsDelta must be a string")
                }
                let hasName = chunk.keys.contains("name")
                let name = chunk["name"] as? String
                if id.isEmpty || (hasName && name?.isEmpty != false) {
                    records.append(Record(type: "chunk", time0: time, index: 0, dt: [],
                                          texts: [], id: nil, name: nil, hasName: false,
                                          chunk: chunk, lastTime: time))
                    return
                }
                let previous = records.last
                let gap = previous.flatMap {
                    $0.type == "tool-call-chunks" ? safeStreamGap($0.lastTime, time) : nil
                }
                let previousName: String? = previous?.name ?? nil
                let sameName = previous?.type == "tool-call-chunks"
                    && previous?.hasName == hasName && previousName == name
                if let previous, previous.type == "tool-call-chunks",
                   previous.index == index, previous.id == id, sameName, let gap {
                    records[records.count - 1].dt.append(gap)
                    records[records.count - 1].texts.append(delta)
                    records[records.count - 1].lastTime = time
                } else {
                    records.append(Record(type: "tool-call-chunks", time0: time, index: index,
                                          dt: [], texts: [delta], id: id, name: name,
                                          hasName: hasName, chunk: nil, lastTime: time))
                }
            case "block-start", "block-end", "usage", "finish":
                records.append(Record(type: "chunk", time0: time, index: 0, dt: [],
                                      texts: [], id: nil, name: nil, hasName: false,
                                      chunk: chunk, lastTime: time))
            default:
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "unsupported assistant stream chunk type \(chunkType)")
            }
        }

        func snapshot() -> [[String: Any]] {
            records.map { record in
                switch record.type {
                case "chunk":
                    return ["type": "chunk", "time": record.time0, "chunk": record.chunk ?? [:]]
                case "tool-call-chunks":
                    var result: [String: Any] = ["type": record.type, "time0": record.time0,
                                                 "index": record.index, "dt": record.dt,
                                                 "id": record.id ?? "", "args": record.texts]
                    if record.hasName, let name = record.name { result["name"] = name }
                    return result
                default:
                    return ["type": record.type, "time0": record.time0, "index": record.index,
                            "dt": record.dt, "texts": record.texts]
                }
            }
        }
    }

    private struct StreamEntry {
        var record: [String: Any]
        var lastTime: Int64
    }

    /// One in-progress assistant attempt: coalesced packed stream records
    /// plus the chunk spans they cover. Ported from staged
    /// `v1-to-v2/migration.ts` (`AttemptGroup`).
    private struct AttemptGroup {
        let turn: Int
        let step: Int
        var spans: [(firstSeq: Int, eventCount: Int)] = []
        var stream: [StreamEntry] = []
        var accumulator: AssistantStreamAccumulator?
        var chunkCount = 0
        var lastChunkSeq: Int?
        var lastChunkTime: Int64?
        var terminal = false
    }

    private struct StreamingAttempt {
        var group: AttemptGroup
        var afterLastChunk: [DeepSeekHarnessEnvelope] = []
    }

    /// Legacy v1 turn/step lifecycle observed while migrating. Ported from
    /// staged `v1-to-v2/migration.ts` (`LegacyTurnState`).
    private struct LegacyTurnState {
        var openTurn: Int?
        var openStep: Int?
        var previousType: String?
        var previousData: [String: Any]?
    }

    private struct V1State {
        let header: DeepSeekHarnessHeader
        let sourceCut: Int
        var mapping: [Int: Int] = [:]
        var output: [DeepSeekHarnessEnvelope] = []
        var pending: StreamingAttempt?
        var legacyTurns = LegacyTurnState()
        var targetCut: Int?
        var lastTime: Int64
    }

    private static func migrateV1ToV2(
        _ rows: [DeepSeekHarnessPhysicalRow],
        header: DeepSeekHarnessHeader,
        inheritedEventCount: Int
    ) throws -> [DeepSeekHarnessEnvelope] {
        var state = V1State(
            header: header,
            sourceCut: inheritedEventCount,
            targetCut: header.isSeeded ? nil : 0,
            lastTime: header.createdAtMilliseconds
        )
        for row in rows {
            switch row {
            case .packed(let run): try appendPackedRun(run, state: &state)
            case .event(let event): try consumeV1(event, state: &state)
            }
        }
        try finishAttempt(state: &state)
        if header.isSeeded && state.targetCut == nil {
            state.targetCut = state.output.count
            state.output.append(DeepSeekHarnessEnvelope(
                type: "session/end-seed", sequence: state.output.count,
                timeMilliseconds: state.lastTime, data: ["inherited": true]
            ))
        }
        return state.output
    }

    private static func appendPackedRun(
        _ run: DeepSeekHarnessPackedRun,
        state: inout V1State
    ) throws {
        // Packed runs never participate in the legacy turn pattern: like
        // upstream, a run clears the previous-event witness.
        state.legacyTurns.previousType = nil
        state.legacyTurns.previousData = nil
        state.lastTime = Int64(run.lastTime)
        try rotateAttemptIfNeeded(turn: run.turn, step: run.step, state: &state)
        if state.pending == nil {
            state.pending = StreamingAttempt(group: attemptGroup(turn: run.turn, step: run.step))
        }
        guard var pending = state.pending else { return }
        if (run.firstSeq < state.sourceCut) != (run.lastSeq < state.sourceCut) {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "inherited cut \(state.sourceCut) splits one Assistant attempt")
        }
        flushAccumulator(&pending.group)
        appendStreamRecord(&pending.group, source: run.streamRecord, lastTime: Int64(run.lastTime))
        recordChunkSpan(&pending.group, firstSeq: run.firstSeq,
                        eventCount: run.eventCount, lastTime: Int64(run.lastTime))
        state.pending = pending
    }

    private static func consumeV1(
        _ event: DeepSeekHarnessEnvelope,
        state: inout V1State
    ) throws {
        // Released v1 admission runs before transformation (except
        // assistant/chunk), ported from the decoded v1-to-v2 stage: only
        // released known dispositions are validated, with the v1 payload
        // generation and never the v2 rules.
        if event.type != "assistant/chunk",
           DeepSeekHarnessPayloadValidator.v0Dispositions[event.type] != nil {
            try DeepSeekHarnessPayloadValidator.assertReleasedV0EventPayload(event, version: 1)
        }
        // Released v1 refuses every event absent from the released v1
        // inventory, even when marked ignorable. Unknown-ignorable
        // retention exists only for native/current v3, where the released
        // catalog permits it.
        guard DeepSeekHarnessVocabulary.v0Events.contains(event.type) else {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "format v1 contains unknown event type \"\(event.type)\" at seq \(event.sequence)")
        }
        let interrupted = legacyInterruptedTurn(state.legacyTurns, event)
        if event.type == "turn/start", state.legacyTurns.openTurn != nil, interrupted == nil {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "turn/start \(jsonDebug(event.data["turn"])) does not close the prior turn")
        }
        try assertSourceDeliveryMarker(event, state: state)
        observeLegacyTurn(&state.legacyTurns, event)
        state.lastTime = event.timeMilliseconds
        if let interrupted {
            try finishAttempt(state: &state)
            try emitGenerated(interrupted, origin: event.sequence, state: &state)
        }
        if event.type == "assistant/chunk" {
            try transformChunk(event, state: &state)
            return
        }
        if event.type == "assistant/message" {
            try transformMessage(event, state: &state)
            return
        }
        if event.type == "user/message",
           let source = event.data["source"] as? [String: Any],
           source["kind"] as? String == "goal",
           let change = source["change"] as? [String: Any] {
            try emitGenerated(
                DeepSeekHarnessEnvelope(type: "goal/change", sequence: event.sequence,
                                        timeMilliseconds: event.timeMilliseconds, data: change),
                origin: event.sequence, state: &state
            )
            var messageData = event.data
            messageData["source"] = ["kind": "plugin", "plugin": "goal"]
            try emitSource(replacing(event, data: messageData), state: &state)
            return
        }
        if closesAttempt(event.type) { try finishAttempt(state: &state) }
        if state.pending != nil {
            state.pending?.afterLastChunk.append(event)
            return
        }
        try emitSource(event, state: &state)
    }

    /// Settles or flushes the pending attempt when a new turn/step member
    /// arrives. Ported from the turnover prelude shared by staged
    /// `transformChunk` and `transformReleasedRun`.
    private static func rotateAttemptIfNeeded(
        turn: Int,
        step: Int,
        state: inout V1State
    ) throws {
        guard state.pending != nil else { return }
        if state.pending?.group.terminal == true
            || state.pending?.group.turn != turn || state.pending?.group.step != step {
            try finishAttempt(state: &state)
        } else {
            try flushBuffered(state: &state)
        }
    }

    private static func transformChunk(
        _ event: DeepSeekHarnessEnvelope,
        state: inout V1State
    ) throws {
        guard let turn = positiveCoordinate(event.data["turn"]),
              let step = positiveCoordinate(event.data["step"]),
              let chunk = event.data["chunk"] as? [String: Any] else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "assistant/chunk \(event.sequence) is malformed")
        }
        try rotateAttemptIfNeeded(turn: turn, step: step, state: &state)
        if state.pending == nil {
            state.pending = StreamingAttempt(group: attemptGroup(turn: turn, step: step))
        }
        guard var pending = state.pending else { return }
        let first = pending.group.spans.first?.firstSeq ?? event.sequence
        if (first < state.sourceCut) != (event.sequence < state.sourceCut) {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "inherited cut \(state.sourceCut) splits one Assistant attempt")
        }
        var accumulator = pending.group.accumulator ?? AssistantStreamAccumulator()
        try accumulator.push(time: event.timeMilliseconds, chunk: chunk)
        pending.group.accumulator = accumulator
        recordChunkSpan(&pending.group, firstSeq: event.sequence,
                        eventCount: 1, lastTime: event.timeMilliseconds)
        if chunk["type"] as? String == "finish" { pending.group.terminal = true }
        state.pending = pending
    }

    private static func transformMessage(
        _ event: DeepSeekHarnessEnvelope,
        state: inout V1State
    ) throws {
        guard let turn = positiveCoordinate(event.data["turn"]),
              let step = positiveCoordinate(event.data["step"]) else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "assistant/message \(event.sequence) lacks positive turn/step")
        }
        if let pending = state.pending,
           pending.group.turn != turn || pending.group.step != step {
            // A message from another attempt settles the pending one and is
            // emitted with an empty embedded stream; the complete target
            // validation then refuses its turn/step mismatch.
            try finishAttempt(state: &state)
            var fresh = attemptGroup(turn: turn, step: step)
            try emitSource(messageEvent(event, group: &fresh), state: &state)
            return
        }
        guard var pending = state.pending else {
            if let cited = event.sourceEventSeqs, !cited.isEmpty {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "assistant/message \(event.sequence) chunk references are not one complete ordered attempt")
            }
            var fresh = attemptGroup(turn: turn, step: step)
            try emitSource(messageEvent(event, group: &fresh), state: &state)
            return
        }
        guard let cited = event.sourceEventSeqs else {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "assistant/message \(event.sequence) does not cite its complete v1 chunk attempt")
        }
        if cited.isEmpty {
            try finishAttempt(state: &state)
            var fresh = attemptGroup(turn: turn, step: step)
            try emitSource(messageEvent(event, group: &fresh), state: &state)
            return
        }
        guard matchesChunkSources(pending.group, cited) else {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "assistant/message \(event.sequence) chunk references are not one complete ordered attempt")
        }
        let first = pending.group.spans.first?.firstSeq ?? event.sequence
        if (first < state.sourceCut) != (event.sequence < state.sourceCut) {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "inherited cut \(state.sourceCut) splits one Assistant attempt")
        }
        pending.group.terminal = true
        state.pending = pending
        try flushBuffered(state: &state)
        guard var flushed = state.pending else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "assistant/message \(event.sequence) lost its chunk attempt")
        }
        let message = messageEvent(event, group: &flushed.group)
        try emitSource(message, state: &state)
        state.pending = nil
    }

    /// Synthesizes the canonical interrupted `turn/end` only for the
    /// released resume pattern: an unclosed turn, no open step, a next-turn
    /// `turn/start` for exactly the following turn, and a preceding
    /// `agent/inbox/spliced` targeting `next-turn` with a non-empty insert.
    /// Ported from staged `legacyInterruptedTurn`.
    private static func legacyInterruptedTurn(
        _ turns: LegacyTurnState,
        _ event: DeepSeekHarnessEnvelope
    ) -> DeepSeekHarnessEnvelope? {
        guard event.type == "turn/start",
              let openTurn = turns.openTurn,
              turns.openStep == nil,
              DeepSeekHarnessJSON.count(event.data["turn"]) == openTurn + 1,
              turns.previousType == "agent/inbox/spliced",
              let splice = turns.previousData,
              splice["target"] as? String == "next-turn",
              let inserted = splice["inserted"] as? [Any], !inserted.isEmpty else {
            return nil
        }
        return DeepSeekHarnessEnvelope(
            type: "turn/end", sequence: event.sequence,
            timeMilliseconds: event.timeMilliseconds,
            data: ["turn": openTurn, "reason": ["kind": "interrupted"] as [String: Any]]
        )
    }

    private static func observeLegacyTurn(_ turns: inout LegacyTurnState, _ event: DeepSeekHarnessEnvelope) {
        switch event.type {
        case "turn/start":
            turns.openTurn = DeepSeekHarnessJSON.count(event.data["turn"])
            turns.openStep = nil
        case "turn/end":
            turns.openTurn = nil
            turns.openStep = nil
        case "step/start":
            turns.openStep = DeepSeekHarnessJSON.count(event.data["step"])
        case "step/end":
            turns.openStep = nil
        default:
            break
        }
        turns.previousType = event.type
        turns.previousData = event.data
    }

    private static func assertSourceDeliveryMarker(
        _ event: DeepSeekHarnessEnvelope,
        state: V1State
    ) throws {
        guard event.type == "session-log-deepseek/delivery-accepted" else { return }
        let inherited = state.header.parentSessionID != nil && event.sequence < state.sourceCut
        let accepted = DeepSeekHarnessJSON.safeInt(event.data["sessionFormatVersion"])
        if accepted == 1, !inherited, event.data["sessionId"] as? String != state.header.id {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "current-generation delivery marker names the wrong Session")
        }
    }

    private static func attemptGroup(turn: Int, step: Int) -> AttemptGroup {
        AttemptGroup(turn: turn, step: step)
    }

    private static func recordChunkSpan(
        _ group: inout AttemptGroup,
        firstSeq: Int,
        eventCount: Int,
        lastTime: Int64
    ) {
        if let last = group.spans.last,
           last.firstSeq + last.eventCount == firstSeq {
            group.spans[group.spans.count - 1].eventCount += eventCount
        } else {
            group.spans.append((firstSeq: firstSeq, eventCount: eventCount))
        }
        group.chunkCount += eventCount
        group.lastChunkSeq = firstSeq + eventCount - 1
        group.lastChunkTime = lastTime
    }

    private static func matchesChunkSources(_ group: AttemptGroup, _ sources: [Int]) -> Bool {
        guard sources.count == group.chunkCount else { return false }
        var index = 0
        for span in group.spans {
            for offset in 0..<span.eventCount {
                guard index < sources.count, sources[index] == span.firstSeq + offset else {
                    return false
                }
                index += 1
            }
        }
        return true
    }

    /// Appends one packed stream record with the exact upstream coalescing
    /// rules: a raw `chunk` never merges, and packed runs merge only with
    /// the same record type, same index, a safe time gap, and (for
    /// tool-call runs) the same call identity and name presence/value.
    /// Swift value semantics give each group its own copy, matching the
    /// upstream detached-copy flush of accumulator records behind an owned
    /// packed prefix. Ported from staged `appendStreamRecord`.
    private static func appendStreamRecord(
        _ group: inout AttemptGroup,
        source: [String: Any],
        lastTime: Int64
    ) {
        let sourceType = source["type"] as? String
        if group.stream.isEmpty || sourceType == "chunk"
            || group.stream[group.stream.count - 1].record["type"] as? String != sourceType {
            group.stream.append(StreamEntry(record: source, lastTime: lastTime))
            return
        }
        var previous = group.stream[group.stream.count - 1]
        guard let previousIndex = DeepSeekHarnessJSON.count(previous.record["index"]),
              let sourceIndex = DeepSeekHarnessJSON.count(source["index"]),
              previousIndex == sourceIndex,
              let sourceTime = DeepSeekHarnessJSON.safeInt(source["time0"]),
              let gap = safeStreamGap(previous.lastTime, Int64(sourceTime)) else {
            group.stream.append(StreamEntry(record: source, lastTime: lastTime))
            return
        }
        if sourceType == "tool-call-chunks" {
            let previousHasName = previous.record.keys.contains("name")
            let sourceHasName = source.keys.contains("name")
            guard (previous.record["id"] as? String) == (source["id"] as? String),
                  previousHasName == sourceHasName,
                  (previous.record["name"] as? String) == (source["name"] as? String) else {
                group.stream.append(StreamEntry(record: source, lastTime: lastTime))
                return
            }
            var dt = (previous.record["dt"] as? [Any] ?? []).compactMap { DeepSeekHarnessJSON.safeInt($0) }
            dt.append(gap)
            dt.append(contentsOf: (source["dt"] as? [Any] ?? []).compactMap { DeepSeekHarnessJSON.safeInt($0) })
            var args = (previous.record["args"] as? [Any] ?? []).compactMap { $0 as? String }
            args.append(contentsOf: (source["args"] as? [Any] ?? []).compactMap { $0 as? String })
            previous.record["dt"] = dt
            previous.record["args"] = args
        } else {
            var dt = (previous.record["dt"] as? [Any] ?? []).compactMap { DeepSeekHarnessJSON.safeInt($0) }
            dt.append(gap)
            dt.append(contentsOf: (source["dt"] as? [Any] ?? []).compactMap { DeepSeekHarnessJSON.safeInt($0) })
            var texts = (previous.record["texts"] as? [Any] ?? []).compactMap { $0 as? String }
            texts.append(contentsOf: (source["texts"] as? [Any] ?? []).compactMap { $0 as? String })
            previous.record["dt"] = dt
            previous.record["texts"] = texts
        }
        previous.lastTime = lastTime
        group.stream[group.stream.count - 1] = previous
    }

    private static func flushAccumulator(_ group: inout AttemptGroup) {
        guard let accumulator = group.accumulator else { return }
        for record in accumulator.snapshot() {
            appendStreamRecord(&group, source: record, lastTime: recordLastTime(record))
        }
        group.accumulator = nil
    }

    private static func streamOf(_ group: inout AttemptGroup) -> [[String: Any]] {
        flushAccumulator(&group)
        return group.stream.map(\.record)
    }

    private static func messageEvent(
        _ source: DeepSeekHarnessEnvelope,
        group: inout AttemptGroup
    ) -> DeepSeekHarnessEnvelope {
        var data = source.data
        data["stream"] = streamOf(&group)
        return replacing(source, data: data, dropSourceEventSeqs: true)
    }

    private static func attemptEvent(_ group: inout AttemptGroup) -> DeepSeekHarnessEnvelope {
        guard let lastChunkSeq = group.lastChunkSeq, let lastChunkTime = group.lastChunkTime else {
            // Unreachable: a pending group always covers at least one chunk.
            return DeepSeekHarnessEnvelope(
                type: "assistant/attempt", sequence: 0, timeMilliseconds: 0,
                data: ["turn": group.turn, "step": group.step, "stream": streamOf(&group)])
        }
        return DeepSeekHarnessEnvelope(
            type: "assistant/attempt", sequence: lastChunkSeq,
            timeMilliseconds: lastChunkTime,
            data: ["turn": group.turn, "step": group.step, "stream": streamOf(&group)]
        )
    }

    private static func recordLastTime(_ record: [String: Any]) -> Int64 {
        guard (record["type"] as? String) != "chunk" else {
            return Int64(DeepSeekHarnessJSON.safeInt(record["time"]) ?? 0)
        }
        var time = Int64(DeepSeekHarnessJSON.safeInt(record["time0"]) ?? 0)
        for gap in (record["dt"] as? [Any] ?? []).compactMap({ DeepSeekHarnessJSON.safeInt($0) }) {
            time = time &+ Int64(gap)
        }
        return time
    }

    private static func safeStreamGap(_ previous: Int64, _ next: Int64) -> Int? {
        let (gap, overflow) = next.subtractingReportingOverflow(previous)
        guard !overflow, gap >= Int64(-DeepSeekHarnessJSON.maxSafeInteger),
              gap <= Int64(DeepSeekHarnessJSON.maxSafeInteger) else { return nil }
        return Int(gap)
    }

    private static func jsonDebug(_ value: Any?) -> String {
        guard let value, let rendered = DeepSeekHarnessJSON.canonicalString(value) else {
            return "undefined"
        }
        return rendered
    }

    private static func finishAttempt(state: inout V1State) throws {
        guard let pending = state.pending else { return }
        var group = pending.group
        guard let origin = group.lastChunkSeq else {
            throw DeepSeekHarnessFormatError.invalidPayload("assistant attempt covers no chunks")
        }
        let attempt = attemptEvent(&group)
        try emitGenerated(attempt, origin: origin, state: &state)
        try flushBuffered(state: &state)
        state.pending = nil
    }

    private static func flushBuffered(state: inout V1State) throws {
        guard var pending = state.pending else { return }
        let buffered = pending.afterLastChunk
        pending.afterLastChunk.removeAll(keepingCapacity: true)
        state.pending = pending
        for event in buffered { try emitSource(event, state: &state) }
    }

    private static func emitSource(
        _ source: DeepSeekHarnessEnvelope,
        state: inout V1State
    ) throws {
        var event = source
        if state.header.isSeeded,
           source.sequence == state.sourceCut,
           source.type == "session/end-seed" {
            var data = source.data
            data["inherited"] = true
            event = replacing(source, data: data)
        }
        try ensureTargetCut(origin: source.sequence, time: source.timeMilliseconds,
                            type: source.type, state: &state)
        state.mapping[source.sequence] = state.output.count
        state.output.append(try remap(event, targetSequence: state.output.count,
                                      mapping: state.mapping, surfaceVersion: 2))
    }

    private static func emitGenerated(
        _ event: DeepSeekHarnessEnvelope,
        origin: Int,
        state: inout V1State
    ) throws {
        try ensureTargetCut(origin: origin, time: event.timeMilliseconds,
                            type: event.type, state: &state)
        state.output.append(try remap(event, targetSequence: state.output.count,
                                      mapping: state.mapping, surfaceVersion: 2))
    }

    private static func ensureTargetCut(
        origin: Int,
        time: Int64,
        type: String,
        state: inout V1State
    ) throws {
        guard state.header.isSeeded, state.targetCut == nil, origin >= state.sourceCut else { return }
        state.targetCut = state.output.count
        if origin == state.sourceCut && type == "session/end-seed" { return }
        state.output.append(DeepSeekHarnessEnvelope(
            type: "session/end-seed", sequence: state.output.count,
            timeMilliseconds: time, data: ["inherited": true]
        ))
    }

    // MARK: v2 -> v3

    private struct V2State {
        let header: DeepSeekHarnessHeader
        var mapping: [Int: Int] = [:]
        var output: [DeepSeekHarnessEnvelope] = []
        var sourceCut: Int?
        var targetCut: Int?
        var lastForeignDeliverySequence: Int?
        var openStep: (turn: Int, step: Int)?
        var systemHead: Int?
        var prompt = ""
        var originalMessageIDs: Set<String> = []
        var generatedMessageIDs: Set<String> = []
    }

    private static func migrateV2ToV3(
        _ events: [DeepSeekHarnessEnvelope],
        header: DeepSeekHarnessHeader,
        inheritedEventCount: Int
    ) throws -> [DeepSeekHarnessEnvelope] {
        var state = V2State(
            header: header,
            sourceCut: header.isSeeded ? nil : 0,
            targetCut: header.isSeeded ? nil : 0
        )
        for event in events {
            guard event.sequence == state.mapping.count else {
                throw DeepSeekHarnessFormatError.sequence(
                    expected: state.mapping.count, actual: event.sequence)
            }
            guard DeepSeekHarnessVocabulary.v0Events.contains(event.type) ||
                    event.type == "assistant/attempt" ||
                    event.type == "feedback/message-put" ||
                    event.type == "feedback/message-delete" else {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "format v2 to v3 cannot safely transform unclassified event \(event.type)")
            }
            try observeMessageIDs(event, state: &state)
            var source = event

            if event.type == "request/header" {
                guard var requestHeader = event.data["header"] as? [String: Any] else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "request/header \(event.sequence) header must be an object")
                }
                let prompt = requestHeader.removeValue(forKey: "system") as? String ?? ""
                if prompt != state.prompt { try emitSystem(prompt: prompt, anchor: event, state: &state) }
                if let tools = requestHeader["tools"] as? [Any], tools.isEmpty {
                    requestHeader.removeValue(forKey: "tools")
                }
                if let defaults = requestHeader["adapterDefaults"] as? [String: Any], defaults.isEmpty {
                    requestHeader.removeValue(forKey: "adapterDefaults")
                }
                var data = event.data
                data["header"] = requestHeader
                source = replacing(event, data: data)
            }

            if DeepSeekHarnessVocabulary.surfaceV0.contains(event.type), state.systemHead == nil {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "format v2 surface before first step cannot acquire a system head without changing chronology")
            }
            if event.type == "session/end-seed", event.data["inherited"] as? Bool == true {
                guard header.isSeeded else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "unseeded format v2 session contains an inherited end-seed marker")
                }
                state.sourceCut = event.sequence
                state.targetCut = state.output.count
            }
            if event.type == "session-log-deepseek/delivery-accepted" {
                let accepted = DeepSeekHarnessJSON.safeInt(event.data["sessionFormatVersion"])
                if accepted == 3 {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "format v2 delivery marker claims target format v3")
                }
                if accepted == 2, event.data["sessionId"] as? String != header.id {
                    state.lastForeignDeliverySequence = event.sequence
                }
            }

            source = renamePTC(source)
            state.mapping[event.sequence] = state.output.count
            state.output.append(try remap(source, targetSequence: state.output.count,
                                          mapping: state.mapping, surfaceVersion: 3))

            if event.type == "step/start" {
                guard let turn = positiveCoordinate(event.data["turn"]),
                      let step = positiveCoordinate(event.data["step"]) else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "step/start \(event.sequence) lacks positive turn/step")
                }
                state.openStep = (turn, step)
                if state.systemHead == nil { try emitSystem(prompt: "", anchor: event, state: &state) }
            } else if event.type == "step/end" || event.type == "turn/end" {
                state.openStep = nil
            }
        }

        guard let sourceCut = state.sourceCut else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "seeded format v2 session lacks an inherited end-seed marker")
        }
        guard sourceCut == inheritedEventCount else {
            throw DeepSeekHarnessFormatError.invalidReference(
                "format v2 inherited marker disagrees with its source cut")
        }
        if let foreign = state.lastForeignDeliverySequence,
           header.parentSessionID == nil || foreign >= sourceCut {
            throw DeepSeekHarnessFormatError.invalidReference(
                "current-generation delivery marker names the wrong session")
        }
        return state.output
    }

    private static func emitSystem(
        prompt: String,
        anchor: DeepSeekHarnessEnvelope,
        state: inout V2State
    ) throws {
        guard let step = state.openStep else {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "format v2 changed request prompt outside an open step")
        }
        let identity = DeepSeekHarnessJSON.canonicalString([
            "session-format-v2-to-v3", state.header.id, anchor.sequence, anchor.type
        ]) ?? ""
        let id = "v2-to-v3-system-" + DeepSeekHarnessJSON.sha256Hex(identity)
        guard !state.originalMessageIDs.contains(id), !state.generatedMessageIDs.contains(id) else {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "generated system message id collides with an existing message id")
        }
        state.generatedMessageIDs.insert(id)
        let sequence = state.output.count
        let operation: DeepSeekHarnessSurfaceOp
        var sources: [Int]?
        if let head = state.systemHead {
            operation = .replaceV3(startSeq: head, endSeq: head)
            sources = [head]
        } else {
            operation = .append
        }
        state.output.append(DeepSeekHarnessEnvelope(
            type: "system/message", sequence: sequence,
            timeMilliseconds: anchor.timeMilliseconds,
            data: [
                "turn": step.turn, "step": step.step,
                "message": [
                    "id": id, "role": "system",
                    "source": ["kind": "plugin", "plugin": "@deepseek-ai/dsh-system-prompt"],
                    "content": prompt.isEmpty ? [] : [["type": "text", "text": prompt]]
                ]
            ],
            sourceEventSeqs: sources,
            surfaceOp: operation
        ))
        state.systemHead = sequence
        state.prompt = prompt
    }

    private static func observeMessageIDs(
        _ event: DeepSeekHarnessEnvelope,
        state: inout V2State
    ) throws {
        var messages: [[String: Any]] = []
        if event.type == "user/message" {
            messages = [event.data]
        } else if event.type == "assistant/message" || event.type == "tool/result" {
            if let message = event.data["message"] as? [String: Any] { messages = [message] }
        } else if event.type == "agent/inbox/spliced" {
            messages = event.data["inserted"] as? [[String: Any]] ?? []
        } else if event.type == "session/title-llm-request" {
            messages = event.data["messages"] as? [[String: Any]] ?? []
        }
        for message in messages {
            guard let id = message["id"] as? String, !id.isEmpty else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(event.type) \(event.sequence) contains a message without identity")
            }
            if state.generatedMessageIDs.contains(id) {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "source message id collides with a generated system message id")
            }
            state.originalMessageIDs.insert(id)
        }
    }

    private static func renamePTC(_ event: DeepSeekHarnessEnvelope) -> DeepSeekHarnessEnvelope {
        switch event.type {
        case "agent-preset/selected":
            guard event.data["agentPreset"] as? String == "code" else { return event }
            var data = event.data
            data["agentPreset"] = "ptc"
            return replacing(event, data: data)
        case "tool/code-dispatch-start": return replacing(event, type: "tool/ptc-dispatch-start")
        case "tool/code-dispatch": return replacing(event, type: "tool/ptc-dispatch")
        case "user/message": return replacing(event, data: renameMessageSource(event.data))
        case "agent/inbox/spliced", "session/title-llm-request":
            let key = event.type == "agent/inbox/spliced" ? "inserted" : "messages"
            guard let messages = event.data[key] as? [[String: Any]] else { return event }
            var data = event.data
            data[key] = messages.map(renameMessageSource)
            return replacing(event, data: data)
        default: return event
        }
    }

    private static func renameMessageSource(_ message: [String: Any]) -> [String: Any] {
        guard var source = message["source"] as? [String: Any],
              source["kind"] as? String == "plugin",
              source["plugin"] as? String == "tools-code-mode" else { return message }
        source["plugin"] = "tools-ptc"
        var result = message
        result["source"] = source
        return result
    }

    // MARK: Shared reference remapping and v3 validation

    private static func remap(
        _ source: DeepSeekHarnessEnvelope,
        targetSequence: Int,
        mapping: [Int: Int],
        surfaceVersion: Int
    ) throws -> DeepSeekHarnessEnvelope {
        func one(_ value: Int, _ label: String) throws -> Int {
            guard value < source.sequence, let target = mapping[value] else {
                throw DeepSeekHarnessFormatError.invalidReference(
                    "\(label) targets consumed or non-earlier event \(value)")
            }
            return target
        }

        var sources: [Int]?
        if let values = source.sourceEventSeqs {
            sources = try values.map {
                try one($0, "\(source.type) \(source.sequence) sourceEventSeqs")
            }
        }
        var operation = source.surfaceOp
        if let start = operation?.startValue, let end = operation?.endValue {
            let mappedStart = try one(start, "\(source.type) \(source.sequence) surface start")
            let mappedEnd = try one(end, "\(source.type) \(source.sequence) surface end")
            operation = surfaceVersion == 3
                ? .replaceV3(startSeq: mappedStart, endSeq: mappedEnd)
                : .replace(start: mappedStart, end: mappedEnd)
        }

        var data = source.data
        if source.type == "command/done", let value = DeepSeekHarnessJSON.count(data["sourceEventSeq"]) {
            data["sourceEventSeq"] = try one(value, "command/done sourceEventSeq")
        }
        if source.type == "compaction/prune" || source.type == "compaction/summary" {
            guard let range = data["shadowedRange"] as? [String: Any],
                  let start = DeepSeekHarnessJSON.count(range["start"]),
                  let end = DeepSeekHarnessJSON.count(range["end"]),
                  let seqs = data["shadowedSeqs"] as? [Any] else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(source.type) \(source.sequence) has malformed shadow references")
            }
            data["shadowedRange"] = [
                "start": try one(start, "\(source.type) shadowedRange start"),
                "end": try one(end, "\(source.type) shadowedRange end")
            ]
            data["shadowedSeqs"] = try seqs.map { value in
                guard let seq = DeepSeekHarnessJSON.count(value) else {
                    throw DeepSeekHarnessFormatError.invalidReference(
                        "\(source.type) shadowedSeqs contains a non-sequence")
                }
                return try one(seq, "\(source.type) shadowedSeqs")
            }
        }
        if source.type == "session/title" || source.type == "session/title-llm-request" {
            guard let seqs = data["messageSeqs"] as? [Any] else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(source.type) \(source.sequence) messageSeqs must be an array")
            }
            data["messageSeqs"] = try seqs.map { value in
                guard let seq = DeepSeekHarnessJSON.count(value) else {
                    throw DeepSeekHarnessFormatError.invalidReference(
                        "\(source.type) messageSeqs contains a non-sequence")
                }
                return try one(seq, "\(source.type) messageSeqs")
            }
        }
        return DeepSeekHarnessEnvelope(
            type: source.type, sequence: targetSequence,
            timeMilliseconds: source.timeMilliseconds, data: data,
            ignorable: source.ignorable, sourceEventSeqs: sources, surfaceOp: operation
        )
    }

    private static func validateV3(
        _ events: [DeepSeekHarnessEnvelope],
        header: DeepSeekHarnessHeader
    ) throws {
        var openStep: (turn: Int, step: Int)?
        var systemHead: Int?
        var hasSurface = false
        for (index, event) in events.enumerated() {
            guard event.sequence == index else {
                throw DeepSeekHarnessFormatError.sequence(expected: index, actual: event.sequence)
            }
            // Canonical v3 admission runs after migration: envelope keys,
            // surface/source shapes, system/header structure, and canonical
            // omissions. Unknown ignorable events pass as diagnostic-only.
            try DeepSeekHarnessPayloadValidator.assertV3EventPostMigration(event)
            if !DeepSeekHarnessVocabulary.v3Known.contains(event.type) {
                if event.ignorable { continue }
                throw DeepSeekHarnessFormatError.unknownRequiredEvent(event.type)
            }
            if (event.type == "tool/code-dispatch" || event.type == "tool/code-dispatch-start"),
               !event.ignorable {
                throw DeepSeekHarnessFormatError.unknownRequiredEvent(event.type)
            }
            try validateEarlierReferences(event)
            if event.type == "request/header",
               let requestHeader = event.data["header"] as? [String: Any],
               requestHeader.keys.contains("system") {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "format v3 request/header rejects retired header.system")
            }
            if event.type == "step/start" {
                guard let turn = positiveCoordinate(event.data["turn"]),
                      let step = positiveCoordinate(event.data["step"]) else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "step/start \(event.sequence) lacks positive turn/step")
                }
                openStep = (turn, step)
            } else if event.type == "step/end" || event.type == "turn/end" {
                openStep = nil
            }

            if event.type == "system/message" {
                guard let step = openStep,
                      DeepSeekHarnessJSON.safeInt(event.data["turn"]) == step.turn,
                      DeepSeekHarnessJSON.safeInt(event.data["step"]) == step.step else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "system/message \(event.sequence) does not match an open step")
                }
                if hasSurface && systemHead == nil {
                    throw DeepSeekHarnessFormatError.invalidReference(
                        "system/message requires a protected first surface head")
                }
                switch event.surfaceOp {
                case .append:
                    if !hasSurface { systemHead = event.sequence }
                case .replaceV3(let start, let end):
                    if start == systemHead || end == systemHead {
                        guard start == systemHead, end == systemHead else {
                            throw DeepSeekHarnessFormatError.invalidReference(
                                "system/message must replace exactly the current system head")
                        }
                        systemHead = event.sequence
                    }
                default:
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "system/message requires canonical v3 surface metadata")
                }
            } else if DeepSeekHarnessVocabulary.surfaceV3.contains(event.type) {
                guard let operation = event.surfaceOp else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(event.type) \(event.sequence) requires surfaceOp")
                }
                if !operation.isAppend,
                   operation.startValue == systemHead || operation.endValue == systemHead {
                    throw DeepSeekHarnessFormatError.invalidReference(
                        "surface replacement cannot shadow the protected system head")
                }
                if event.type == "assistant/message", event.sourceEventSeqs != nil {
                    throw DeepSeekHarnessFormatError.invalidReference(
                        "assistant/message embeds its stream and cannot carry sourceEventSeqs")
                }
            }
            if event.type == "compaction/prune" || event.type == "compaction/summary",
               let head = systemHead,
               let seqs = event.data["shadowedSeqs"] as? [Int], seqs.contains(head) {
                throw DeepSeekHarnessFormatError.invalidReference(
                    "compaction cannot shadow the protected system head")
            }
            if DeepSeekHarnessVocabulary.surfaceV3.contains(event.type) { hasSurface = true }
        }
        if header.origin == "subagent", header.parentSessionID == nil {
            throw DeepSeekHarnessFormatError.invalidHeader
        }
    }

    private static func validateEarlierReferences(_ event: DeepSeekHarnessEnvelope) throws {
        if let sources = event.sourceEventSeqs {
            guard !sources.isEmpty, Set(sources).count == sources.count,
                  sources.allSatisfy({ $0 >= 0 && $0 < event.sequence }) else {
                throw DeepSeekHarnessFormatError.invalidReference(
                    "\(event.type) \(event.sequence) sourceEventSeqs must be unique earlier events")
            }
        }
        if let start = event.surfaceOp?.startValue, let end = event.surfaceOp?.endValue {
            // Both endpoints must be non-negative and earlier than the
            // event. No numeric start <= end ordering is required here:
            // live-surface order is enforced by the relationship
            // `applySurface`, which compares positions on the current
            // surface, so a span such as start=3,end=2 over surface
            // [3,2] is valid.
            guard start >= 0, start < event.sequence,
                  end >= 0, end < event.sequence else {
                throw DeepSeekHarnessFormatError.invalidReference(
                    "\(event.type) \(event.sequence) replacement endpoints must be earlier events")
            }
        }
    }

    // MARK: Small value helpers

    private static func replacing(
        _ event: DeepSeekHarnessEnvelope,
        type: String? = nil,
        data: [String: Any]? = nil,
        dropSourceEventSeqs: Bool = false
    ) -> DeepSeekHarnessEnvelope {
        DeepSeekHarnessEnvelope(
            type: type ?? event.type, sequence: event.sequence,
            timeMilliseconds: event.timeMilliseconds, data: data ?? event.data,
            ignorable: event.ignorable,
            sourceEventSeqs: dropSourceEventSeqs ? nil : event.sourceEventSeqs,
            surfaceOp: event.surfaceOp
        )
    }

    private static func positiveCoordinate(_ value: Any?) -> Int? {
        guard let value = DeepSeekHarnessJSON.count(value), value > 0 else { return nil }
        return value
    }

    private static func closesAttempt(_ type: String) -> Bool {
        type == "turn/end" || type == "step/end" ||
            type == "llm/retry" || type == "llm/retry-started"
    }

    private static func messageID(in event: DeepSeekHarnessEnvelope) -> String? {
        if event.type == "user/message" { return event.data["id"] as? String }
        return (event.data["message"] as? [String: Any])?["id"] as? String
    }

    private static func malformedLegacy(
        _ sessionID: String,
        _ event: DeepSeekHarnessEnvelope
    ) -> DeepSeekHarnessFormatError {
        .invalidPayload(
            "session \(sessionID) contains malformed legacy \(event.type) at seq \(event.sequence)")
    }
}
