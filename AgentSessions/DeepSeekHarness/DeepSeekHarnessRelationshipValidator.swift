import Foundation

/// Source-faithful cross-event relationship validation required before v3
/// publication. Ported from staged `v0-to-v1/relationships.ts`
/// (`assertReleasedArtifactRelationships`) with the publication extensions
/// used by the v2 line (`stepEvents: assistant/attempt`,
/// `preservedSourceTitleRequestText`) as wired in staged
/// `v1-to-v2/validation.ts` and `v2-to-v3/validation.ts`.
///
/// The validator runs on final v3 coordinates after migration and v3
/// admission, projecting v3-only shapes onto the frozen relationship view
/// exactly like staged `v2-to-v3/validation.ts` (`relationshipEvent`):
/// PTC dispatch names project back to their `code-dispatch` lifecycle,
/// obsolete ignorable dispatch tags do not participate, `system/message`
/// validates as surface, and `TOOL_NOT_STARTED` repair identities are read
/// against the target sequence.
///
/// All failures are deterministic `.invalidPayload` errors carrying the
/// upstream diagnostic text. Unknown ignorable v3 events never reach this
/// stage: they are skipped here the same way upstream skips events outside
/// the released inventory.
enum DeepSeekHarnessRelationshipValidator {
    static func assertPublishableRelationships(
        _ events: [DeepSeekHarnessEnvelope],
        header: DeepSeekHarnessHeader
    ) throws {
        let cut = try inheritedCut(events: events, header: header)
        var state = State(cut: cut)
        state.staleCompactionStarts = inheritedOrphanCompactionStarts(events)
        for event in events {
            guard let projected = try projectForRelationships(event) else { continue }
            guard DeepSeekHarnessVocabulary.v0Events.contains(projected.type)
                || projected.type == "assistant/attempt" else { continue }
            let data = projected.data
            if DeepSeekHarnessRelationshipValidator.surfaceTypes.contains(projected.type) {
                state.surface = try applySurface(state.surface, event: projected)
            }
            if (projected.type == "turn/start" || projected.type == "turn/end"),
               let open = state.openCompaction,
               !state.staleCompactionStarts.contains(open.startSeq) {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(projected.type) crosses an open compaction")
            }
            if projected.type == "assistant/attempt" {
                try requireOpenStep(projected, data: data,
                                    openTurn: state.openTurn, openStep: state.openStep)
                continue
            }
            switch projected.type {
            case "turn/start":
                guard state.openTurn == nil,
                      DeepSeekHarnessJSON.count(data["turn"]) == state.nextTurn else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "turn/start \(jsonDebug(data["turn"])) does not open expected turn \(state.nextTurn)")
                }
                state.openTurn = DeepSeekHarnessJSON.count(data["turn"])
                state.openStep = nil
                state.toolLifecycles.removeAll()
                state.nextStep = 1
            case "turn/end":
                guard DeepSeekHarnessJSON.count(data["turn"]) == state.openTurn else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "turn/end \(jsonDebug(data["turn"])) has no matching open turn")
                }
                try assertNoUnresolvedTools(state.toolLifecycles, boundary: "turn/end")
                if state.openStep != nil {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "turn/end \(jsonDebug(data["turn"])) crosses an open step")
                }
                state.openTurn = nil
                state.nextTurn += 1
            case "step/start":
                guard DeepSeekHarnessJSON.count(data["turn"]) == state.openTurn,
                      state.openStep == nil,
                      DeepSeekHarnessJSON.count(data["step"]) == state.nextStep else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(projected.type) does not match the open turn and next step")
                }
                state.openStep = DeepSeekHarnessJSON.count(data["step"])
            case "step/end":
                try requireOpenStep(projected, data: data,
                                    openTurn: state.openTurn, openStep: state.openStep)
                try assertNoUnresolvedTools(state.toolLifecycles, boundary: "step/end")
                state.toolLifecycles.removeAll()
                state.openStep = nil
                state.nextStep += 1
            case "assistant/chunk":
                try requireOpenStep(projected, data: data,
                                    openTurn: state.openTurn, openStep: state.openStep)
            case "assistant/message":
                try requireOpenStep(projected, data: data,
                                    openTurn: state.openTurn, openStep: state.openStep)
                guard let message = data["message"] as? [String: Any],
                      let content = message["content"] as? [Any] else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "assistant/message \(projected.sequence) message must carry content")
                }
                for block in content {
                    guard let block = block as? [String: Any] else { continue }
                    guard block["type"] as? String == "tool-call" else { continue }
                    guard let callID = block["id"] as? String,
                          let name = block["name"] as? String,
                          let arguments = block["arguments"] as? String else {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "assistant/message \(projected.sequence) advertises a tool call without identity")
                    }
                    if state.toolLifecycles[callID] != nil {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "assistant/message repeats advertised tool call \(callID)")
                    }
                    state.toolLifecycles[callID] = ToolLifecycle(name: name,
                                                                 arguments: arguments,
                                                                 state: .advertised)
                }
            case "tool/call":
                try requireOpenStep(projected, data: data,
                                    openTurn: state.openTurn, openStep: state.openStep)
                guard let callID = data["callId"] as? String,
                      let lifecycle = state.toolLifecycles[callID],
                      lifecycle.state == .advertised,
                      lifecycle.name == data["name"] as? String,
                      lifecycle.arguments == data["arguments"] as? String else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "tool/call \(data["callId"] as? String ?? "unknown") does not match one advertised tool call")
                }
                state.toolLifecycles[callID]?.state = .started
            case "tool/result":
                if projected.surfaceOp?.isAppend == true {
                    try requireOpenStep(projected, data: data,
                                        openTurn: state.openTurn, openStep: state.openStep)
                    guard let message = data["message"] as? [String: Any],
                          let source = message["source"] as? [String: Any],
                          let callID = source["callId"] as? String,
                          let content = message["content"] as? [Any] else {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "tool/result \(projected.sequence) message must carry tool content")
                    }
                    let error = data["error"] as? [String: Any]
                    guard let lifecycle = state.toolLifecycles[callID] else {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "tool/result \(callID) has no advertised tool lifecycle")
                    }
                    if lifecycle.state == .advertised,
                       !isExactToolNotStartedRepair(projected, content: content, error: error) {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "tool/result \(callID) is not the exact TOOL_NOT_STARTED repair")
                    }
                    state.toolLifecycles.removeValue(forKey: callID)
                } else if state.openTurn == nil {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "tool/result replacement is outside an open turn")
                }
            case "request/header":
                guard state.openTurn != nil else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(projected.type) is outside an open turn")
                }
                let config = (data["header"] as? [String: Any])?["config"] as? [String: Any]
                state.openStepProvider = config?["provider"] as? String
            case "request/context":
                guard state.openTurn != nil else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(projected.type) is outside an open turn")
                }
            case "tool/code-dispatch-start", "tool/code-dispatch":
                guard state.openTurn != nil else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(projected.type) is outside an open turn")
                }
                guard let root = data["rootCallId"] as? String,
                      let parent = data["parentCallId"] as? String,
                      let child = data["subCallId"] as? String,
                      let name = data["name"] as? String else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(projected.type) \(projected.sequence) lacks dispatch identity")
                }
                if let known = state.ptcRoots[child], known != root {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(projected.type) changes its rootCallId")
                }
                if parent != root, state.ptcRoots[parent] != root {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(projected.type) parentCallId does not belong to rootCallId")
                }
                if projected.type == "tool/code-dispatch-start" {
                    if state.ptcStarts[child] != nil {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "tool/code-dispatch-start repeats subCallId")
                    }
                    state.ptcStarts[child] = PtcStart(root: root, parent: parent, name: name,
                                                     arguments: data["arguments"], settled: false)
                } else {
                    guard var start = state.ptcStarts[child], !start.settled else {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "tool/code-dispatch has no unique start")
                    }
                    guard start.root == root, start.parent == parent, start.name == name,
                          canonicalJSON(start.arguments) == canonicalJSON(data["arguments"]) else {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "tool/code-dispatch does not match its start")
                    }
                    start.settled = true
                    state.ptcStarts[child] = start
                }
                state.ptcRoots[child] = root
            case "llm/retry":
                guard let turn = DeepSeekHarnessJSON.count(data["turn"]),
                      turn == state.openTurn,
                      DeepSeekHarnessJSON.count(data["step"]) == (state.openStep ?? state.nextStep - 1),
                      state.openTurn != nil else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "llm/retry does not match the current turn and step")
                }
                guard (data["provider"] as? String) == state.openStepProvider else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "llm/retry provider does not match the open request/header")
                }
                try assertRetryChain(state.retries, data: data)
                state.retries.append(projected)
            case "llm/retry-started":
                let scheduled = state.retries.first { candidate in
                    (candidate.data["retryId"] as? String) == (data["retryId"] as? String)
                        && DeepSeekHarnessJSON.count(candidate.data["retry"])
                        == DeepSeekHarnessJSON.count(data["retry"])
                }
                guard let scheduled else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "llm/retry-started pairs no prior scheduled attempt")
                }
                guard DeepSeekHarnessJSON.count(scheduled.data["turn"])
                    == DeepSeekHarnessJSON.count(data["turn"]),
                      DeepSeekHarnessJSON.count(scheduled.data["step"])
                    == DeepSeekHarnessJSON.count(data["step"]) else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "llm/retry-started does not match its scheduled turn and step")
                }
                let key = "\(jsonDebug(data["retryId"]))\0\(jsonDebug(data["retry"]))"
                if state.retryStarts.contains(key) {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "llm/retry-started repeats one scheduled attempt")
                }
                state.retryStarts.insert(key)
            case "session/title", "session/title-llm-request":
                try assertTitleSources(events: events, event: projected, data: data)
            case "command/run":
                guard let id = data["commandId"] as? String else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "command/run \(projected.sequence) lacks commandId")
                }
                if state.commandRuns.contains(id) {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "command/run repeats commandId \(id)")
                }
                state.commandRuns.insert(id)
            case "command/done":
                guard let id = data["commandId"] as? String else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "command/done \(projected.sequence) lacks commandId")
                }
                guard state.commandRuns.contains(id) else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "command/done \(id) has no prior command/run")
                }
                if let sourceSeq = DeepSeekHarnessJSON.count(data["sourceEventSeq"]) {
                    let source = sourceSeq < events.count ? events[sourceSeq] : nil
                    if (data["kind"] as? String) != "success"
                        || source?.type == "command/run" || source?.type == "command/done" {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "command/done \(id) has invalid sourceEventSeq")
                    }
                }
            case "session-log-deepseek/delivery-accepted":
                let accepted = DeepSeekHarnessJSON.safeInt(data["sessionFormatVersion"]) ?? 0
                if accepted == header.version {
                    let inherited = header.parentSessionID != nil
                        && projected.sequence < state.cut
                    if !inherited, (data["sessionId"] as? String) != header.id {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "current-generation delivery marker names the wrong Session")
                    }
                }
            case "compaction/start":
                if state.openCompaction != nil {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "compaction/start overlaps an open compaction")
                }
                try assertCompactionTurn(compactionTurn(data["turn"]), openTurn: state.openTurn,
                                         type: "compaction/start")
                state.openCompaction = CompactionState(
                    id: data["compactionId"] as? String ?? "",
                    sourceCommandID: data["sourceCommandId"] as? String,
                    turn: compactionTurn(data["turn"]),
                    startSeq: projected.sequence,
                    summarized: false)
            case "compaction/summary":
                try assertCompactionOwner(state.openCompaction, data: data,
                                          type: "compaction/summary")
                try assertCompactionTurn(state.openCompaction?.turn, openTurn: state.openTurn,
                                         type: "compaction/summary")
                if state.openCompaction?.summarized == true {
                    throw DeepSeekHarnessFormatError.invalidPayload("compaction/summary repeats")
                }
                try assertCurrentSurfaceSpan(state.surface, data: data, type: "compaction/summary")
                state.openCompaction?.summarized = true
            case "compaction/end":
                try assertCompactionOwner(state.openCompaction, data: data,
                                          type: "compaction/end")
                if compactionTurn(data["turn"]) != state.openCompaction?.turn {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "compaction/end changes its owner turn")
                }
                try assertCompactionTurn(state.openCompaction?.turn, openTurn: state.openTurn,
                                         type: "compaction/end")
                if data["error"] == nil, state.openCompaction?.summarized != true {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "successful compaction/end requires one summary")
                }
                state.openCompaction = nil
            case "compaction/prune":
                try assertCurrentSurfaceSpan(state.surface, data: data, type: "compaction/prune")
            case "user/message":
                if projected.surfaceOp?.isAppend == false,
                   let source = data["source"] as? [String: Any],
                   source["kind"] as? String == "plugin",
                   source["plugin"] as? String == "compact" {
                    try assertCompactionOwner(state.openCompaction, data: source,
                                              type: "compaction checkpoint at seq \(projected.sequence)")
                }
            case "session/end-seed":
                // An unmatched inherited transaction belongs to the ended
                // source lifecycle.
                state.openCompaction = nil
            default:
                break
            }
        }
    }

    // MARK: - Private state

    private static let surfaceTypes: Set<String> = ["user/message", "assistant/message", "tool/result"]

    private enum ToolState {
        case advertised
        case started
    }

    private struct ToolLifecycle {
        let name: String
        let arguments: String
        var state: ToolState
    }

    private struct PtcStart {
        let root: String
        let parent: String
        let name: String
        let arguments: Any?
        var settled: Bool
    }

    private struct CompactionState {
        let id: String
        let sourceCommandID: String?
        let turn: Int?
        let startSeq: Int
        var summarized: Bool
    }

    private struct State {
        let cut: Int
        var openTurn: Int?
        var openStep: Int?
        var openStepProvider: String?
        var nextTurn = 1
        var nextStep = 1
        var surface: [Int] = []
        var openCompaction: CompactionState?
        var staleCompactionStarts: Set<Int> = []
        var retries: [DeepSeekHarnessEnvelope] = []
        var retryStarts = Set<String>()
        var ptcRoots: [String: String] = [:]
        var ptcStarts: [String: PtcStart] = [:]
        var toolLifecycles: [String: ToolLifecycle] = [:]
        var commandRuns = Set<String>()
    }

    // MARK: - Seed boundary

    private static func inheritedCut(
        events: [DeepSeekHarnessEnvelope],
        header: DeepSeekHarnessHeader
    ) throws -> Int {
        var lastMarker: Int?
        for event in events where event.type == "session/end-seed" {
            if (event.data["inherited"] as? Bool) == true {
                lastMarker = event.sequence
            } else if event.data["inherited"] != nil {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "session/end-seed \(event.sequence) inherited must be true when present")
            }
        }
        if header.isSeeded {
            guard let marker = lastMarker else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "seeded session lacks an inherited end-seed marker")
            }
            return marker
        }
        if lastMarker != nil {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "unseeded session contains an inherited end-seed marker")
        }
        return 0
    }

    // MARK: - v3 relationship projection

    /// Projects one v3 event onto the frozen relationship view, mirroring
    /// staged `relationshipEvent`. Returns nil for obsolete ignorable
    /// dispatch tags, which do not participate in lifecycle validation.
    private static func projectForRelationships(
        _ event: DeepSeekHarnessEnvelope
    ) throws -> DeepSeekHarnessEnvelope? {
        switch event.type {
        case "tool/ptc-dispatch-start":
            return DeepSeekHarnessEnvelope(type: "tool/code-dispatch-start",
                                           sequence: event.sequence,
                                           timeMilliseconds: event.timeMilliseconds,
                                           data: event.data, ignorable: event.ignorable,
                                           sourceEventSeqs: event.sourceEventSeqs,
                                           surfaceOp: event.surfaceOp)
        case "tool/ptc-dispatch":
            return DeepSeekHarnessEnvelope(type: "tool/code-dispatch",
                                           sequence: event.sequence,
                                           timeMilliseconds: event.timeMilliseconds,
                                           data: event.data, ignorable: event.ignorable,
                                           sourceEventSeqs: event.sourceEventSeqs,
                                           surfaceOp: event.surfaceOp)
        case "tool/code-dispatch-start", "tool/code-dispatch":
            // Obsolete required tags fail admission upstream of this stage;
            // obsolete ignorable tags stay opaque and skipped.
            return nil
        case "system/message":
            guard let message = event.data["message"] as? [String: Any] else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "system/message \(event.sequence) message must be an object")
            }
            var projected = message
            projected["role"] = "user"
            return DeepSeekHarnessEnvelope(type: "user/message",
                                           sequence: event.sequence,
                                           timeMilliseconds: event.timeMilliseconds,
                                           data: projected, ignorable: event.ignorable,
                                           sourceEventSeqs: event.sourceEventSeqs,
                                           surfaceOp: event.surfaceOp)
        case "tool/result":
            guard let error = event.data["error"] as? [String: Any],
                  error["code"] as? String == "TOOL_NOT_STARTED",
                  let message = event.data["message"] as? [String: Any],
                  let source = message["source"] as? [String: Any],
                  let callID = source["callId"] as? String,
                  DeepSeekHarnessPayloadValidator.isRepairIdentity(
                    message["id"], callID) else {
                return event
            }
            var data = event.data
            var repaired = message
            // Message identity survives promotion; only this frozen repair
            // check uses the target sequence.
            repaired["id"] = "interrupted-tool-result-\(callID)-\(event.sequence)"
            data["message"] = repaired
            return DeepSeekHarnessEnvelope(type: event.type,
                                           sequence: event.sequence,
                                           timeMilliseconds: event.timeMilliseconds,
                                           data: data, ignorable: event.ignorable,
                                           sourceEventSeqs: event.sourceEventSeqs,
                                           surfaceOp: event.surfaceOp)
        default:
            return event
        }
    }

    // MARK: - Relationship helpers

    private static func inheritedOrphanCompactionStarts(
        _ events: [DeepSeekHarnessEnvelope]
    ) -> Set<Int> {
        var stale = Set<Int>()
        var open: Int?
        for event in events {
            if event.type == "compaction/start" {
                open = event.sequence
            } else if event.type == "compaction/end" {
                open = nil
            } else if event.type == "session/end-seed" {
                if let start = open { stale.insert(start) }
                open = nil
            }
        }
        return stale
    }

    private static func requireOpenStep(
        _ event: DeepSeekHarnessEnvelope,
        data: [String: Any],
        openTurn: Int?,
        openStep: Int?
    ) throws {
        guard DeepSeekHarnessJSON.count(data["turn"]) == openTurn,
              DeepSeekHarnessJSON.count(data["step"]) == openStep,
              openTurn != nil, openStep != nil else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(event.type) does not match an open turn and step")
        }
    }

    private static func assertNoUnresolvedTools(
        _ lifecycles: [String: ToolLifecycle],
        boundary: String
    ) throws {
        if let unresolved = lifecycles.keys.sorted().first {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(boundary) leaves unresolved tool call \(unresolved)")
        }
    }

    private static func assertRetryChain(
        _ retries: [DeepSeekHarnessEnvelope],
        data: [String: Any]
    ) throws {
        let prior = retries.reversed().first { candidate in
            DeepSeekHarnessJSON.count(candidate.data["turn"]) == DeepSeekHarnessJSON.count(data["turn"])
                && DeepSeekHarnessJSON.count(candidate.data["step"]) == DeepSeekHarnessJSON.count(data["step"])
                && (candidate.data["provider"] as? String) == (data["provider"] as? String)
                && (candidate.data["policyKey"] as? String) == (data["policyKey"] as? String)
        }
        let expected = (prior.flatMap { DeepSeekHarnessJSON.count($0.data["retry"]) } ?? 0) + 1
        guard DeepSeekHarnessJSON.count(data["retry"]) == expected else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "llm/retry must use retry \(expected)")
        }
        if let prior,
           (prior.data["retryId"] as? String) != (data["retryId"] as? String) {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "llm/retry must preserve retryId across one policy chain")
        }
        if prior == nil, retries.contains(where: {
            ($0.data["retryId"] as? String) == (data["retryId"] as? String)
        }) {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "llm/retry reuses retryId \(jsonDebug(data["retryId"])) across policy chains")
        }
    }

    /// The exact historical `TOOL_NOT_STARTED` repair shape: a tool error
    /// with the canonical `interrupted-tool-result-<callId>-<seq>` message
    /// identity, no chunk references, and the frozen single-text apology
    /// body. Ported from staged `isExactToolNotStartedRepair`.
    private static func isExactToolNotStartedRepair(
        _ event: DeepSeekHarnessEnvelope,
        content: [Any],
        error: [String: Any]?
    ) -> Bool {
        guard let error, error["name"] as? String == "ToolNotStartedError",
              error["code"] as? String == "TOOL_NOT_STARTED",
              event.sourceEventSeqs == nil,
              let message = event.data["message"] as? [String: Any],
              let source = message["source"] as? [String: Any],
              let callID = source["callId"] as? String,
              message["id"] as? String == "interrupted-tool-result-\(callID)-\(event.sequence)",
              let block = content.first as? [String: Any],
              block["isError"] as? Bool == true,
              let inner = block["content"] as? [Any],
              inner.count == 1,
              let text = inner.first as? [String: Any],
              text["type"] as? String == "text",
              text["text"] as? String
            == "The tool call was interrupted before the Harness recorded it as started. Retry it if it is still needed."
        else {
            return false
        }
        return true
    }

    private static func applySurface(
        _ surface: [Int],
        event: DeepSeekHarnessEnvelope
    ) throws -> [Int] {
        guard let operation = event.surfaceOp else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(event.type) requires a surfaceOp marker")
        }
        if operation.isAppend { return surface + [event.sequence] }
        guard let start = operation.startValue, let end = operation.endValue,
              let startIndex = surface.firstIndex(of: start),
              let endIndex = surface.firstIndex(of: end),
              startIndex <= endIndex else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(event.type) replacement range is not on the current surface")
        }
        let shadowed = Array(surface[startIndex...endIndex])
        let sources = Set(event.sourceEventSeqs ?? [])
        guard shadowed.allSatisfy({ sources.contains($0) }) else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(event.type) replacement sourceEventSeqs omit a shadowed surface node")
        }
        return Array(surface[..<startIndex]) + [event.sequence] + Array(surface[(endIndex + 1)...])
    }

    private static func assertTitleSources(
        events: [DeepSeekHarnessEnvelope],
        event: DeepSeekHarnessEnvelope,
        data: [String: Any]
    ) throws {
        // The publication extension preserves source-validated title-request
        // text across sequence remapping, so only the relationship framing
        // is checked here, never the embedded source coordinates.
        guard let rawSeqs = data["messageSeqs"] as? [Any] else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(event.type) \(event.sequence) messageSeqs must be an array")
        }
        let seqs = try rawSeqs.map { value -> Int in
            guard let seq = DeepSeekHarnessJSON.count(value) else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(event.type) \(event.sequence) messageSeqs must cite sequences")
            }
            return seq
        }
        if event.type == "session/title" {
            guard let source = data["source"] as? [String: Any] else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "session/title \(event.sequence) source must be an object")
            }
            guard seqs.isEmpty == (source["kind"] as? String == "user") else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "session/title \(event.sequence) messageSeqs must be empty exactly for a user title")
            }
        }
        var selected: [(seq: Int, text: String)] = []
        for seq in seqs {
            guard seq < events.count, events[seq].type == "user/message" else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(event.type) \(event.sequence) messageSeqs must cite earlier human user/message events")
            }
            let sourceData = events[seq].data
            guard let messageSource = sourceData["source"] as? [String: Any],
                  messageSource["kind"] as? String == "user",
                  let content = sourceData["content"] as? [Any] else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(event.type) \(event.sequence) messageSeqs must cite earlier human user/message events")
            }
            let text = content.compactMap { $0 as? [String: Any] }
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            selected.append((seq: seq, text: text))
        }
        guard event.type == "session/title-llm-request" else { return }
        guard let messages = data["messages"] as? [Any],
              messages.count == 1,
              let message = messages.first as? [String: Any],
              message["role"] as? String == "user",
              let content = message["content"] as? [Any], content.count == 1,
              let source = message["source"] as? [String: Any],
              source["kind"] as? String == "plugin",
              source["plugin"] as? String == "dsh-session-title-llm",
              let framed = content.first as? [String: Any],
              framed["type"] as? String == "text" else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "session/title-llm-request messages do not represent messageSeqs")
        }
        _ = selected
    }

    private static func compactionTurn(_ value: Any?) -> Int? {
        guard value != nil, !(value is NSNull) else { return nil }
        return DeepSeekHarnessJSON.count(value)
    }

    private static func assertCompactionOwner(
        _ open: CompactionState?,
        data: [String: Any],
        type: String
    ) throws {
        guard let open,
              (data["compactionId"] as? String) == open.id,
              (data["sourceCommandId"] as? String) == open.sourceCommandID else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(type) has no matching compaction/start")
        }
    }

    private static func assertCompactionTurn(
        _ owner: Int?,
        openTurn: Int?,
        type: String
    ) throws {
        if owner == nil ? openTurn != nil : owner != openTurn {
            throw DeepSeekHarnessFormatError.invalidPayload("\(type) does not match the open turn")
        }
    }

    private static func assertCurrentSurfaceSpan(
        _ surface: [Int],
        data: [String: Any],
        type: String
    ) throws {
        guard let range = data["shadowedRange"] as? [String: Any],
              let start = DeepSeekHarnessJSON.count(range["start"]),
              let end = DeepSeekHarnessJSON.count(range["end"]),
              let rawSeqs = data["shadowedSeqs"] as? [Any] else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(type) shadowedSeqs do not name an exact current surface span")
        }
        let seqs = rawSeqs.compactMap { DeepSeekHarnessJSON.count($0) }
        guard seqs.count == rawSeqs.count,
              let startIndex = surface.firstIndex(of: start),
              let endIndex = surface.firstIndex(of: end),
              startIndex <= endIndex else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(type) shadowedSeqs do not name an exact current surface span")
        }
        let expected = Array(surface[startIndex...endIndex])
        guard expected == seqs else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(type) shadowedSeqs do not name an exact current surface span")
        }
    }

    private static func canonicalJSON(_ value: Any?) -> String? {
        guard let value else { return "null" }
        return DeepSeekHarnessJSON.canonicalString(value)
    }

    private static func jsonDebug(_ value: Any?) -> String {
        guard let value, let rendered = DeepSeekHarnessJSON.canonicalString(value) else {
            return "undefined"
        }
        return rendered
    }
}
