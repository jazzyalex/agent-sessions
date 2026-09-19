import Foundation

/// Strict, source-faithful payload admission for the v2 and v3 format
/// boundaries, ported from the frozen DSH reference at
/// `ddefc45fbc7f8e46dd73185e68295696d1297887`.
///
/// Staging (mirrors the upstream codec/migration split):
/// - `assertV2EventPreMigration` runs on every v2 event BEFORE v2-to-v3
///   migration. It ports `assertEvent(event, 2)` from
///   `session-format-v2-to-v3/src/payload.ts`, including the released v2
///   disposition inventory from `session-format-v1-to-v2/dispositions.ts`
///   (which retains the v0 inventory from
///   `session-format-v0-to-v1/dispositions.ts`) and the nested payload
///   semantics from `session-format-v0-to-v1/payload-validation.ts`.
///   A v2-invalid payload must fail here even when migration would
///   drop or transform the offending field (for example a non-string
///   `request/header` system prompt that migration strips).
/// - `assertV3EventPostMigration` runs on every v3 event AFTER migration
///   (and on native v3 rows). It ports `assertV3Event`,
///   `assertV3EventAdmission`, `assertV3StructuralRow`, and
///   `assertCanonicalPayload` from the same `payload.ts`, plus the
///   admission half of `validation.ts`. Cross-event system-head protection
///   stays in `DeepSeekHarnessHistoricalNormalizer.validateV3`.
///
/// Error taxonomy (mirrors upstream error classes):
/// - `.invalidPayload` for `SessionFormatError` structural/payload faults.
/// - `.unsupportedMigration` for `SessionFormatUnsupportedMigrationError`
///   vocabulary refusals (unclassified events, sources, content kinds).
/// - `.unknownRequiredEvent` for unknown required v3 events, preserving
///   the strict-publication policy: unknown ignorable v3 events pass
///   admission and are retained as diagnostic-only by the normalizer.
///
/// All messages are deterministic and stage-specific: they carry the
/// `format v2/v3 <type> at seq <n>` subject used upstream.
enum DeepSeekHarnessPayloadValidator {
    // MARK: - Released v2 disposition inventory

    /// Exact top-level payload-member inventory frozen for released v2:
    /// the retained v0 dispositions plus the v2 edge shapes.
    struct Disposition {
        let required: [String]
        let optional: [String]
        /// Members retained as lossless JSON without nested inspection.
        let opaque: [String]
    }

    static let v2Dispositions: [String: Disposition] = [
        "agent-preset/selected": Disposition(required: ["agentPreset"], optional: [], opaque: []),
        "agent/inbox/spliced": Disposition(
            required: ["target", "start", "inserted"],
            optional: ["removedCount", "outcome"], opaque: []),
        "approval/asked": Disposition(
            required: ["id", "toolName"], optional: ["callId", "reason"], opaque: []),
        "approval/decided": Disposition(required: ["id", "outcome"], optional: [], opaque: []),
        "approval/policy": Disposition(required: ["policy"], optional: ["source"], opaque: []),
        "assistant/attempt": Disposition(required: ["turn", "step", "stream"], optional: [], opaque: []),
        "assistant/message": Disposition(
            required: ["turn", "step", "message", "stream"],
            optional: ["usage", "interrupted"], opaque: []),
        "command/done": Disposition(
            required: ["commandId", "kind"], optional: ["text", "sourceEventSeq"], opaque: []),
        "command/run": Disposition(
            required: ["commandId", "name", "source"], optional: ["args"], opaque: []),
        "compaction/end": Disposition(
            required: ["compactionId", "turn"],
            optional: ["sourceCommandId", "error"], opaque: []),
        "compaction/prune": Disposition(
            required: ["shadowedRange", "shadowedSeqs", "shadowedTokenCount"],
            optional: [], opaque: []),
        "compaction/start": Disposition(
            required: ["compactionId", "turn"], optional: ["sourceCommandId"], opaque: []),
        "compaction/summary": Disposition(
            required: ["compactionId", "summary", "shadowedRange", "shadowedSeqs",
                       "shadowedTokenCount", "provider", "model"],
            optional: ["sourceCommandId", "maxTokens", "usage", "rawOutput", "llmStreamCall"],
            opaque: []),
        "feedback/record": Disposition(required: ["text"], optional: [], opaque: []),
        "goal/change": Disposition(
            required: ["kind", "version", "operation"],
            optional: ["goal", "roundsStarted", "createdAt", "updatedAt", "cleared", "clearedAt"],
            opaque: []),
        "hook/invoked": Disposition(
            required: ["turn", "point", "dialect", "handlerId"],
            optional: ["matcher"], opaque: []),
        "hook/result": Disposition(
            required: ["turn", "point", "handlerId", "decision", "durationMs"],
            optional: ["exitCode", "stderrSummary"], opaque: []),
        "llm/retry": Disposition(
            required: ["retryId", "turn", "step", "provider", "mode", "policyKey",
                       "retry", "delayMs", "failure"],
            optional: ["maxRetries"], opaque: []),
        "llm/retry-started": Disposition(
            required: ["retryId", "turn", "step", "retry"], optional: [], opaque: []),
        "model/selection": Disposition(
            required: ["provider", "model"], optional: ["reasoningEffort"], opaque: []),
        "permission/preset": Disposition(required: ["preset"], optional: [], opaque: []),
        "plan/mode": Disposition(required: ["active"], optional: [], opaque: []),
        "request/context": Disposition(
            required: ["provider", "model"], optional: ["contextWindow"], opaque: []),
        "request/header": Disposition(
            required: ["header", "reason"], optional: ["startsSeries"], opaque: []),
        "sandbox/mode": Disposition(required: ["mode"], optional: ["source"], opaque: []),
        "schedule/change": Disposition(
            required: ["version", "operation"],
            optional: ["schedule", "id", "acceptedAt"], opaque: []),
        "session-log-deepseek/delivery-accepted": Disposition(
            required: ["sessionId", "throughSeq"],
            optional: ["sessionFormatVersion"], opaque: []),
        "session/end-seed": Disposition(required: [], optional: ["inherited"], opaque: []),
        "session/title": Disposition(
            required: ["title", "messageSeqs", "source"], optional: [], opaque: []),
        "session/title-llm-request": Disposition(
            required: ["titleProvider", "messageSeqs", "route", "system", "messages", "maxTokens"],
            optional: [], opaque: []),
        "step/end": Disposition(required: ["turn", "step"], optional: [], opaque: []),
        "step/start": Disposition(required: ["turn", "step"], optional: [], opaque: []),
        "subagent/descriptor": Disposition(
            required: ["mode", "version", "provider"],
            optional: ["label", "agentProvider", "agentModel", "agentReasoningEffort",
                       "persona", "toolFilter"],
            opaque: []),
        "subagent/model-selection-policy": Disposition(
            required: ["allowedModels"], optional: [], opaque: []),
        "team/member": Disposition(
            required: ["version", "teamId", "member"], optional: [], opaque: []),
        "team/message/delivered": Disposition(
            required: ["version", "teamId", "messageId", "targetId"], optional: [], opaque: []),
        "team/message/queued": Disposition(
            required: ["version", "teamId", "message"], optional: [], opaque: []),
        "team/task": Disposition(
            required: ["version", "teamId", "task"], optional: [], opaque: []),
        "todo/write": Disposition(required: ["todos"], optional: [], opaque: []),
        "tool-workflow/agent-end": Disposition(
            required: ["runId", "seq", "outcome"], optional: [], opaque: []),
        "tool-workflow/agent-start": Disposition(
            required: ["runId", "seq", "label", "childId"], optional: ["phase"], opaque: []),
        "tool-workflow/run-end": Disposition(
            required: ["runId", "stopReason"], optional: [], opaque: []),
        "tool-workflow/run-start": Disposition(
            required: ["runId", "name"], optional: [], opaque: []),
        "tool/call": Disposition(
            required: ["turn", "step", "callId", "name", "arguments"], optional: [], opaque: []),
        "tool/code-dispatch": Disposition(
            required: ["rootCallId", "parentCallId", "subCallId", "name", "arguments",
                       "isError", "content"],
            optional: [], opaque: ["arguments"]),
        "tool/code-dispatch-start": Disposition(
            required: ["rootCallId", "parentCallId", "subCallId", "name", "arguments"],
            optional: [], opaque: ["arguments"]),
        "tool/result": Disposition(
            required: ["turn", "step", "message"],
            optional: ["error", "meta"], opaque: ["meta"]),
        "turn/end": Disposition(required: ["turn", "reason"], optional: [], opaque: []),
        "turn/start": Disposition(required: ["turn"], optional: [], opaque: []),
        "user/message": Disposition(
            required: ["role", "id", "content", "source"], optional: [], opaque: []),
        "web/deepseek-search-llm-request": Disposition(
            required: ["endpoint", "apiVersion", "body"], optional: [], opaque: []),
    ]

    static let v2SurfaceTypes: Set<String> = ["user/message", "assistant/message", "tool/result"]

    // MARK: - Released v0/v1 disposition inventory

    /// Exact top-level payload-member inventory frozen for released v0/v1,
    /// ported from `session-format-v0-to-v1/src/dispositions.ts`
    /// (`RELEASED_V0_EVENT_DISPOSITIONS`). Released v1 shares this table;
    /// the only v1 delta is the optional `sessionFormatVersion` on the
    /// delivery marker, applied in `assertReleasedV0EventPayload`.
    /// Never use `v2Dispositions` for v0/v1 admission: v2 requires the
    /// embedded `stream` on `assistant/message` and the `throughSeq` marker
    /// shape, neither of which exists at v0/v1.
    static let v0Dispositions: [String: Disposition] = [
        "agent-preset/selected": Disposition(required: ["agentPreset"], optional: [], opaque: []),
        "agent/inbox/spliced": Disposition(
            required: ["target", "start", "inserted"],
            optional: ["removedCount", "outcome"], opaque: []),
        "approval/asked": Disposition(
            required: ["id", "toolName"], optional: ["callId", "reason"], opaque: []),
        "approval/decided": Disposition(required: ["id", "outcome"], optional: [], opaque: []),
        "approval/policy": Disposition(required: ["policy"], optional: ["source"], opaque: []),
        "assistant/chunk": Disposition(required: ["turn", "step", "chunk"], optional: [], opaque: []),
        "assistant/message": Disposition(
            required: ["turn", "step", "message"],
            optional: ["usage", "interrupted"], opaque: []),
        "command/done": Disposition(
            required: ["commandId", "kind"], optional: ["text", "sourceEventSeq"], opaque: []),
        "command/run": Disposition(
            required: ["commandId", "name", "source"], optional: ["args"], opaque: []),
        "compaction/end": Disposition(
            required: ["compactionId", "turn"],
            optional: ["sourceCommandId", "error"], opaque: []),
        "compaction/prune": Disposition(
            required: ["shadowedRange", "shadowedSeqs", "shadowedTokenCount"],
            optional: [], opaque: []),
        "compaction/start": Disposition(
            required: ["compactionId", "turn"], optional: ["sourceCommandId"], opaque: []),
        "compaction/summary": Disposition(
            required: ["compactionId", "summary", "shadowedRange", "shadowedSeqs",
                       "shadowedTokenCount", "provider", "model"],
            optional: ["sourceCommandId", "maxTokens", "usage", "rawOutput", "llmStreamCall"],
            opaque: []),
        "feedback/record": Disposition(required: ["text"], optional: [], opaque: []),
        "goal/change": Disposition(
            required: ["kind", "version", "operation"],
            optional: ["goal", "roundsStarted", "createdAt", "updatedAt", "cleared", "clearedAt"],
            opaque: []),
        "hook/invoked": Disposition(
            required: ["turn", "point", "dialect", "handlerId"],
            optional: ["matcher"], opaque: []),
        "hook/result": Disposition(
            required: ["turn", "point", "handlerId", "decision", "durationMs"],
            optional: ["exitCode", "stderrSummary"], opaque: []),
        "llm/retry": Disposition(
            required: ["retryId", "turn", "step", "provider", "mode", "policyKey",
                       "retry", "delayMs", "failure"],
            optional: ["maxRetries"], opaque: []),
        "llm/retry-started": Disposition(
            required: ["retryId", "turn", "step", "retry"], optional: [], opaque: []),
        "model/selection": Disposition(
            required: ["provider", "model"], optional: ["reasoningEffort"], opaque: []),
        "permission/preset": Disposition(required: ["preset"], optional: [], opaque: []),
        "plan/mode": Disposition(required: ["active"], optional: [], opaque: []),
        "request/context": Disposition(
            required: ["provider", "model"], optional: ["contextWindow"], opaque: []),
        "request/header": Disposition(
            required: ["header", "reason"], optional: ["startsSeries"], opaque: []),
        "sandbox/mode": Disposition(required: ["mode"], optional: ["source"], opaque: []),
        "schedule/change": Disposition(
            required: ["version", "operation"],
            optional: ["schedule", "id", "acceptedAt"], opaque: []),
        "session-log-deepseek/delivery-accepted": Disposition(
            required: ["sessionId", "throughSeq"], optional: [], opaque: []),
        "session/end-seed": Disposition(required: [], optional: [], opaque: []),
        "session/title": Disposition(
            required: ["title", "messageSeqs", "source"], optional: [], opaque: []),
        "session/title-llm-request": Disposition(
            required: ["titleProvider", "messageSeqs", "route", "system", "messages", "maxTokens"],
            optional: [], opaque: []),
        "step/end": Disposition(required: ["turn", "step"], optional: [], opaque: []),
        "step/start": Disposition(required: ["turn", "step"], optional: [], opaque: []),
        "subagent/descriptor": Disposition(
            required: ["mode", "version", "provider"],
            optional: ["label", "agentProvider", "agentModel", "agentReasoningEffort",
                       "persona", "toolFilter"],
            opaque: []),
        "subagent/model-selection-policy": Disposition(
            required: ["allowedModels"], optional: [], opaque: []),
        "team/member": Disposition(
            required: ["version", "teamId", "member"], optional: [], opaque: []),
        "team/message/delivered": Disposition(
            required: ["version", "teamId", "messageId", "targetId"], optional: [], opaque: []),
        "team/message/queued": Disposition(
            required: ["version", "teamId", "message"], optional: [], opaque: []),
        "team/task": Disposition(
            required: ["version", "teamId", "task"], optional: [], opaque: []),
        "todo/write": Disposition(required: ["todos"], optional: [], opaque: []),
        "tool-workflow/agent-end": Disposition(
            required: ["runId", "seq", "outcome"], optional: [], opaque: []),
        "tool-workflow/agent-start": Disposition(
            required: ["runId", "seq", "label", "childId"], optional: ["phase"], opaque: []),
        "tool-workflow/run-end": Disposition(
            required: ["runId", "stopReason"], optional: [], opaque: []),
        "tool-workflow/run-start": Disposition(
            required: ["runId", "name"], optional: [], opaque: []),
        "tool/call": Disposition(
            required: ["turn", "step", "callId", "name", "arguments"], optional: [], opaque: []),
        "tool/code-dispatch": Disposition(
            required: ["rootCallId", "parentCallId", "subCallId", "name", "arguments",
                       "isError", "content"],
            optional: [], opaque: ["arguments"]),
        "tool/code-dispatch-start": Disposition(
            required: ["rootCallId", "parentCallId", "subCallId", "name", "arguments"],
            optional: [], opaque: ["arguments"]),
        "tool/result": Disposition(
            required: ["turn", "step", "message"],
            optional: ["error", "meta"], opaque: ["meta"]),
        "turn/end": Disposition(required: ["turn", "reason"], optional: [], opaque: []),
        "turn/start": Disposition(required: ["turn"], optional: [], opaque: []),
        "user/message": Disposition(
            required: ["role", "id", "content", "source"], optional: [], opaque: []),
        "web/deepseek-search-llm-request": Disposition(
            required: ["endpoint", "apiVersion", "body"], optional: [], opaque: []),
    ]

    static let v2SourceKinds: Set<String> = [
        "user", "plugin", "model", "tool", "agent-instructions", "session-reference",
        "team-message", "goal", "skill-invocation", "skill-catalog", "coordinator",
        "subagent-report", "subagent-settled", "webhook", "agent-message",
    ]

    static let v2ContentKinds: Set<String> = [
        "text", "reasoning", "image", "file", "tool-call", "tool-result",
    ]

    // MARK: - V0/V1 released payload admission

    /// Ports `assertReleasedEventPayload(event, version)` from
    /// `session-format-v0-to-v1/src/validation.ts`: exact disposition key
    /// admission, opaque lossless-JSON retention, and nested payload
    /// semantics for one known event after (v0) or before (v1) legacy
    /// transformation. `version` is the payload generation (0 or 1).
    ///
    /// Callers skip `assistant/chunk`: v0 skips it after legacy
    /// normalization and v1 skips it before transformation, matching
    /// upstream (`normalizeReleasedV0Event` and the decoded v1-to-v2
    /// stage). Unknown types fail closed even when ignorable.
    static func assertReleasedV0EventPayload(
        _ event: DeepSeekHarnessEnvelope,
        version: Int
    ) throws {
        guard let admitted = v0Dispositions[event.type] else {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "format v0 contains unknown historical event type \"\(event.type)\"" +
                " at seq \(event.sequence);" +
                " migration refuses unknown historical events even when ignorable")
        }
        let data = try record(event.data, "\(event.type) \(event.sequence) data")
        if event.type == "subagent/descriptor", DeepSeekHarnessJSON.count(data["version"]) != 3 {
            let descriptorVersion = try countValue(
                data["version"], "\(event.type) \(event.sequence) version")
            if version == 0 {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "\(event.type) \(event.sequence)" +
                    " uses unsupported descriptor version \(descriptorVersion)")
            }
            return
        }
        var optional = admitted.optional
        if version == 1, event.type == "session-log-deepseek/delivery-accepted" {
            optional += ["sessionFormatVersion"]
        }
        try keys(data, required: admitted.required, optional: optional,
                 label: "\(event.type) \(event.sequence) data")
        for key in admitted.opaque {
            if let value = data[key], !isLosslessJSON(value) {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(event.type) \(event.sequence) opaque \(key) is not lossless JSON")
            }
        }
        try assertReleasedPayloadSemantics(
            event, data: data,
            subject: "\(event.type) \(event.sequence)", version: version)
    }

    // MARK: - V2 pre-migration admission

    /// Ports `assertEvent(event, 2)`: envelope admission, disposition key
    /// admission, owned-content checks, nested payload semantics, and the
    /// v2-only source/identity rules. Unknown events are refused even when
    /// marked ignorable, matching upstream migration behavior.
    static func assertV2EventPreMigration(_ event: DeepSeekHarnessEnvelope) throws {
        let subject = "format v2 \(event.type) at seq \(event.sequence)"
        let isFeedback = event.type == "feedback/message-put" || event.type == "feedback/message-delete"
        guard let admitted = v2Dispositions[event.type] else {
            if !isFeedback {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "format v2 to v3 cannot safely transform unclassified event \(event.type)")
            }
            try assertV2Envelope(event, subject: subject, surface: false, raw: event.rawObject)
            try assertFeedback(event.type, event.data, subject: subject)
            return
        }
        let surface = v2SurfaceTypes.contains(event.type)
        try assertV2Envelope(event, subject: subject, surface: surface, raw: event.rawObject)
        if surface {
            try assertV2SurfaceMetadata(event, subject: subject)
            guard event.surfaceOp != nil else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) requires surfaceOp")
            }
        }
        let data = try record(event.data, "\(subject) data")
        try keys(data, required: admitted.required, optional: admitted.optional,
                 label: "\(subject) data")
        for key in admitted.opaque {
            if let value = data[key], !isLosslessJSON(value) {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) opaque \(key) is not lossless JSON")
            }
        }
        try assertV2OwnedContent(event, data: data, subject: subject)
        // Assistant attempts are introduced by v2; the shared semantic
        // helper has no case for them.
        if event.type != "assistant/attempt" {
            try assertReleasedPayloadSemantics(event, data: data, subject: subject, version: 2)
        }
        if event.type == "assistant/message" || event.type == "assistant/attempt" {
            for coordinate in ["turn", "step"] {
                guard let value = DeepSeekHarnessJSON.count(data[coordinate]), value > 0 else {
                    throw DeepSeekHarnessFormatError.invalidPayload("\(coordinate) must be positive")
                }
            }
        }
        if event.type == "session/end-seed",
           let inherited = data["inherited"], strictBool(inherited) != true {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "session/end-seed inherited must be true")
        }
        if event.type == "user/message" { try assertV2Source(data, subject: subject) }
        if event.type == "assistant/message" || event.type == "tool/result" {
            try assertV2Source(try record(data["message"], "\(subject) message"), subject: subject)
        }
        if event.type == "tool/result",
           let error = data["error"] as? [String: Any],
           error["code"] as? String == "TOOL_NOT_STARTED" {
            let message = try record(data["message"], "\(subject) message")
            let source = try record(message["source"], "\(subject) source")
            guard isRepairIdentity(message["id"], source["callId"]) else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) TOOL_NOT_STARTED repair requires its canonical historical message id")
            }
        }
        if event.type == "agent/inbox/spliced" || event.type == "session/title-llm-request" {
            let field = event.type == "agent/inbox/spliced" ? "inserted" : "messages"
            guard let messages = data[field] as? [Any] else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) \(field) must be an array")
            }
            for message in messages {
                guard let object = message as? [String: Any] else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(subject) \(field) must contain objects")
                }
                try assertV2Source(object, subject: subject)
            }
        }
    }

    /// Envelope admission for v2: strict `ignorable` identity (a JSON
    /// number such as 1 must not pass as true), surface-only
    /// `sourceEventSeqs`/`surfaceOp`, and dense scalar checks.
    private static func assertV2Envelope(
        _ event: DeepSeekHarnessEnvelope,
        subject: String,
        surface: Bool,
        raw: [String: Any]
    ) throws {
        if let rawIgnorable = raw["ignorable"], strictBool(rawIgnorable) != true {
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) ignorable must be true")
        }
        if !surface, event.sourceEventSeqs != nil || event.surfaceOp != nil {
            let field = event.sourceEventSeqs != nil ? "sourceEventSeqs" : "surfaceOp"
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) has unexpected field \(field)")
        }
        guard DeepSeekHarnessJSON.count(event.rawObject["seq"]) != nil,
              DeepSeekHarnessJSON.safeInt(event.rawObject["time"]) != nil else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) has non-numeric coordinates")
        }
    }

    /// Ports `assertReleasedSurfaceMetadata` with `forbid-assistant`: an
    /// `assistant/message` must embed its stream and cannot carry chunk
    /// references; other surface sources must be non-empty unique earlier
    /// seqs and replacements must reference earlier events.
    private static func assertV2SurfaceMetadata(
        _ event: DeepSeekHarnessEnvelope,
        subject: String
    ) throws {
        if event.type == "assistant/message", event.sourceEventSeqs != nil {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(subject) retains obsolete chunk references")
        }
        if let sources = event.sourceEventSeqs {
            guard !sources.isEmpty else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) sourceEventSeqs must be non-empty")
            }
            var seen = Set<Int>()
            for source in sources {
                guard source >= 0, source < event.sequence, !seen.contains(source) else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(subject) sourceEventSeqs must be unique earlier seqs")
                }
                seen.insert(source)
            }
        }
        if let start = event.surfaceOp?.startValue, let end = event.surfaceOp?.endValue {
            guard start < event.sequence, end < event.sequence else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) has an invalid surface replacement")
            }
        }
    }

    /// Ports the v2 `assertSource` inventory: exactly the released source
    /// kinds, with the relay shape required for `agent-message`.
    private static func assertV2Source(_ message: [String: Any], subject: String) throws {
        let source = try record(message["source"], "\(subject) message source")
        guard let kind = source["kind"] as? String, v2SourceKinds.contains(kind) else {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "\(subject) cannot safely transform unclassified message source")
        }
        if kind == "agent-message" {
            try keys(source, required: ["kind", "form", "senderSessionId"], optional: [],
                     label: "\(subject) agent-message source")
            guard source["form"] as? String == "relay",
                  let sender = source["senderSessionId"] as? String, !sender.isEmpty else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) agent-message source requires relay form and senderSessionId")
            }
        }
    }

    /// Ports `isRepairIdentity`: the canonical historical
    /// `interrupted-tool-result-<callId>-<seq>` message identity.
    static func isRepairIdentity(_ id: Any?, _ callID: Any?) -> Bool {
        guard let callID = callID as? String,
              let id = id as? String else { return false }
        let prefix = "interrupted-tool-result-\(callID)-"
        guard id.hasPrefix(prefix) else { return false }
        let suffix = String(id.dropFirst(prefix.count))
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        if suffix.count > 1, suffix.hasPrefix("0") { return false }
        guard let value = Int(suffix),
              value <= DeepSeekHarnessJSON.maxSafeInteger else { return false }
        return true
    }

    // MARK: - V2 owned content

    /// Ports `assertOwnedContent`: per-event content-kind admission,
    /// including file attachments and embedded assistant stream chunks.
    /// Only raw `chunk` stream entries carry blocks; packed deltas and
    /// other chunk payloads remain opaque.
    private static func assertV2OwnedContent(
        _ event: DeepSeekHarnessEnvelope,
        data: [String: Any],
        subject: String
    ) throws {
        switch event.type {
        case "user/message", "tool/code-dispatch":
            try assertContentKinds(data["content"], label: "\(subject) data.content")
        case "tool/code-dispatch-start":
            // Start records advertise arguments only; settled dispatch records
            // own the result content.
            break
        case "assistant/message", "tool/result", "team/message/queued":
            let message = try record(data["message"], "\(subject) data.message")
            try assertContentKinds(message["content"], label: "\(subject) data.message.content")
        case "agent/inbox/spliced", "session/title-llm-request":
            let field = event.type == "agent/inbox/spliced" ? "inserted" : "messages"
            let members = try contentArray(data[field], label: "\(subject) data.\(field)")
            for (index, value) in members.enumerated() {
                let path = "\(subject) data.\(field)[\(index)]"
                let message = try record(value, path)
                try assertContentKinds(message["content"], label: "\(path).content")
            }
        case "compaction/summary":
            try assertContentKinds(data["summary"], label: "\(subject) data.summary")
            if data["rawOutput"] != nil {
                try assertContentKinds(data["rawOutput"], label: "\(subject) data.rawOutput")
            }
        default: break
        }
        if event.type == "assistant/message" || event.type == "assistant/attempt" {
            let stream = try contentArray(data["stream"], label: "\(subject) data.stream")
            for (index, value) in stream.enumerated() {
                let path = "\(subject) data.stream[\(index)]"
                let entry = try record(value, path)
                guard entry["type"] as? String == "chunk" else { continue }
                let chunk = try record(entry["chunk"], "\(path).chunk")
                if chunk["type"] as? String == "block-end" {
                    try assertContentBlock(chunk["block"], label: "\(path).chunk.block")
                }
                if chunk["type"] as? String == "block-start" {
                    try assertContentKind(chunk["blockType"], label: "\(path).chunk.blockType")
                }
            }
        }
    }

    private static func assertContentKind(_ kind: Any?, label: String) throws {
        guard let kind = kind as? String, v2ContentKinds.contains(kind) else {
            throw DeepSeekHarnessFormatError.unsupportedMigration(
                "\(label): cannot safely transform unclassified message content kind")
        }
    }

    private static func assertContentKinds(_ content: Any?, label: String) throws {
        for (index, value) in try contentArray(content, label: label).enumerated() {
            try assertContentBlock(value, label: "\(label)[\(index)]")
        }
    }

    private static func assertContentBlock(_ value: Any?, label: String) throws {
        let block = try record(value, label)
        try assertContentKind(block["type"], label: label)
        if block["type"] as? String == "tool-result" {
            guard let nested = block["content"] as? [Any] else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label).content: invalid message content kind \"tool-result\": content must be an array")
            }
            try assertContentKinds(nested, label: "\(label).content")
        }
        if block["type"] as? String == "file" {
            try keys(block, required: ["type", "attachment"], optional: [],
                     label: "\(label) kind \"file\"")
            let attachment = try record(block["attachment"], "\(label) kind \"file\" attachment")
            try keys(attachment, required: ["attachmentId", "name", "bytes"], optional: [],
                     label: "\(label) kind \"file\" attachment")
            guard let attachmentID = attachment["attachmentId"] as? String, !attachmentID.isEmpty,
                  attachment["name"] is String else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label) kind \"file\": file attachment requires attachmentId and name")
            }
            guard DeepSeekHarnessJSON.count(attachment["bytes"]) != nil else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label) kind \"file\" attachment bytes must be a count")
            }
            return
        }
        // Reuse the frozen field rules without recursively revisiting
        // tool-result children: probe the leaf through the shared
        // message-content semantics.
        let leaf: [String: Any]
        if block["type"] as? String == "tool-result" {
            var copy = block
            copy["content"] = [] as [Any]
            leaf = copy
        } else {
            leaf = block
        }
        let probe = DeepSeekHarnessEnvelope(
            type: "user/message", sequence: 0, timeMilliseconds: 0,
            data: ["id": "content-admission", "role": "user",
                   "source": ["kind": "user"] as [String: Any],
                   "content": [leaf] as [Any]])
        do {
            try assertReleasedPayloadSemantics(
                probe, data: probe.data, subject: "format v2 user/message at seq 0",
                version: 2)
        } catch {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label): invalid message content: \(error)")
        }
    }

    // MARK: - V3 post-migration admission

    /// Ports `assertV3Event` with `assertV3EventAdmission`,
    /// `assertV3StructuralRow`, and `assertCanonicalPayload`. Unknown
    /// required events (including non-ignorable obsolete `code-dispatch`
    /// tags) fail closed; unknown ignorable events pass envelope admission
    /// and remain diagnostic-only upstream of this function.
    /// - Parameter knownTypes: additional installed event types whose
    ///   envelopes are interpreted (upstream `knownEventTypes`).
    static func assertV3EventPostMigration(
        _ event: DeepSeekHarnessEnvelope,
        knownTypes: Set<String> = []
    ) throws {
        let subject = "format v3 \(event.type) at seq \(event.sequence)"
        let obsolete = event.type == "tool/code-dispatch-start" || event.type == "tool/code-dispatch"
        let known = !obsolete && (DeepSeekHarnessVocabulary.v3Known.contains(event.type)
            || knownTypes.contains(event.type))
        let surface = DeepSeekHarnessVocabulary.surfaceV3.contains(event.type)
        if obsolete, !event.ignorable {
            throw DeepSeekHarnessFormatError.unknownRequiredEvent(event.type)
        }
        if !known, !event.ignorable {
            throw DeepSeekHarnessFormatError.unknownRequiredEvent(event.type)
        }
        // Envelope key admission: surface and opaque-unknown events admit
        // surfaceOp/sourceEventSeqs; known log events admit only ignorable.
        let opaque = !known
        if surface || opaque {
            for key in event.rawObject.keys where !["type", "seq", "time", "data", "ignorable",
                                                    "surfaceOp", "sourceEventSeqs"].contains(key) {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) has unexpected field \(key)")
            }
        } else if event.sourceEventSeqs != nil || event.surfaceOp != nil {
            let field = event.sourceEventSeqs != nil ? "sourceEventSeqs" : "surfaceOp"
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) has unexpected field \(field)")
        }
        if let rawIgnorable = event.rawObject["ignorable"], strictBool(rawIgnorable) != true {
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) ignorable must be true when present")
        }
        if opaque { return }
        if surface {
            guard let operation = event.rawObject["surfaceOp"] else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) requires a surfaceOp marker")
            }
            if let text = operation as? String {
                guard text == "append" else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(subject) requires exact replace fields op/startSeq/endSeq")
                }
            } else {
                guard let replace = operation as? [String: Any],
                      Set(replace.keys) == ["op", "startSeq", "endSeq"],
                      replace["op"] as? String == "replace" else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(subject) requires exact replace fields op/startSeq/endSeq")
                }
                for key in ["startSeq", "endSeq"] {
                    guard let endpoint = DeepSeekHarnessJSON.count(replace[key]),
                          endpoint < event.sequence else {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "\(subject) replacement endpoints must reference earlier events")
                    }
                }
            }
            if event.type == "assistant/message", event.sourceEventSeqs != nil {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) embeds its stream and cannot carry sourceEventSeqs")
            }
            if let sources = event.sourceEventSeqs {
                guard !sources.isEmpty else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(subject) sourceEventSeqs must be a non-empty array")
                }
                var seen = Set<Int>()
                for source in sources {
                    guard source >= 0, source < event.sequence, !seen.contains(source) else {
                        throw DeepSeekHarnessFormatError.invalidPayload(
                            "\(subject) sourceEventSeqs must be unique earlier seqs")
                    }
                    seen.insert(source)
                }
            }
        }
        try assertV3StructuralRow(event, subject: subject)
        try assertV3CanonicalPayload(event, subject: subject)
    }

    /// Ports `assertV3StructuralRow`: native v3 system/header shapes are
    /// rejected even beyond a recoverable physical-row failure.
    private static func assertV3StructuralRow(_ event: DeepSeekHarnessEnvelope, subject: String) throws {
        if event.type == "request/header" {
            let data = try record(event.data, "\(subject) data")
            let header = try record(data["header"], "\(subject) header")
            if header["system"] != nil {
                throw DeepSeekHarnessFormatError.unsupportedMigration(
                    "format v3 request/header rejects retired header.system")
            }
        } else if event.type == "system/message" {
            try assertV3System(event, subject: subject)
        }
    }

    /// Ports the v3 `assertSystem` helper: exact system data keys,
    /// positive coordinates, a non-empty id with the system role, plugin
    /// source, and frozen content semantics.
    private static func assertV3System(_ event: DeepSeekHarnessEnvelope, subject: String) throws {
        let data = try record(event.data, "\(subject) data")
        try keys(data, required: ["turn", "step", "message"], optional: [],
                 label: "\(subject) data")
        for coordinate in ["turn", "step"] {
            guard let value = DeepSeekHarnessJSON.count(data[coordinate]), value > 0 else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(coordinate) must be positive")
            }
        }
        let message = try record(data["message"], "\(subject) message")
        try keys(message, required: ["id", "role", "source", "content"], optional: [],
                 label: "\(subject) message")
        guard let id = message["id"] as? String, !id.isEmpty,
              message["role"] as? String == "system" else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(subject) system message requires an id and system role")
        }
        let source = try record(message["source"], "\(subject) source")
        guard source["kind"] as? String == "plugin",
              let plugin = source["plugin"] as? String, !plugin.isEmpty else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(subject) system message requires plugin source")
        }
        var content = message
        content["role"] = "user"
        let probe = DeepSeekHarnessEnvelope(
            type: "user/message", sequence: 0, timeMilliseconds: 0, data: content)
        do {
            try assertReleasedPayloadSemantics(
                probe, data: probe.data, subject: "format v3 user/message at seq 0",
                version: 3)
        } catch {
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) system content: \(error)")
        }
    }

    /// Ports `assertCanonicalPayload`: empty optional header fields must be
    /// omitted in v3, and error metadata is admitted only on error results.
    private static func assertV3CanonicalPayload(
        _ event: DeepSeekHarnessEnvelope,
        subject: String
    ) throws {
        if event.type == "request/header" {
            let data = try record(event.data, "\(subject) data")
            let header = try record(data["header"], "\(subject) header")
            if let tools = header["tools"] as? [Any], tools.isEmpty {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) empty optional header fields must be omitted")
            }
            if let defaults = header["adapterDefaults"] as? [String: Any], defaults.isEmpty {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) empty optional header fields must be omitted")
            }
        }
        if event.type != "tool/result" { return }
        let data = try record(event.data, "\(subject) data")
        if data["error"] == nil { return }
        let message = try record(data["message"], "\(subject) message")
        guard let content = message["content"] as? [Any], content.count == 1,
              let block = content[0] as? [String: Any],
              block["type"] as? String == "tool-result",
              strictBool(block["isError"]) == true else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(subject) carries error metadata for a non-error tool result")
        }
    }

    /// Ports `assertFeedback`: exact put/delete shapes with string
    /// identities, a closed rating enum, and count timestamps.
    private static func assertFeedback(_ type: String, _ data: Any?, subject: String) throws {
        let payload = try record(data, "\(subject) data")
        if type == "feedback/message-delete" {
            try keys(payload, required: ["sessionId", "messageId"], optional: [], label: subject)
            guard payload["sessionId"] is String else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) feedback sessionId must be a string")
            }
            guard payload["messageId"] is String else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) feedback messageId must be a string")
            }
            return
        }
        try keys(payload, required: ["sessionId", "item"], optional: [], label: subject)
        guard payload["sessionId"] is String else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) feedback sessionId must be a string")
        }
        let item = try record(payload["item"], "\(subject) feedback item")
        try keys(item, required: ["messageId", "rating", "version", "createdAt", "updatedAt"],
                 optional: ["note"], label: "\(subject) feedback item")
        for key in ["messageId", "version"] {
            guard item[key] is String else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) feedback \(key) must be a string")
            }
        }
        guard item["rating"] as? String == "positive" || item["rating"] as? String == "negative" else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) invalid feedback rating")
        }
        if let note = item["note"], !(note is String) {
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) feedback note must be a string")
        }
        guard DeepSeekHarnessJSON.count(item["createdAt"]) != nil,
              DeepSeekHarnessJSON.count(item["updatedAt"]) != nil else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(subject) feedback timestamps must be counts")
        }
    }

    // MARK: - Released nested payload semantics

    /// Ports `assertReleasedPayloadSemantics` for one known event with
    /// exact top-level members. `version` selects the versioned members
    /// (session-reference captures, legacy goal content, block versions).
    static func assertReleasedPayloadSemantics(
        _ event: DeepSeekHarnessEnvelope,
        data: [String: Any],
        subject: String,
        version: Int
    ) throws {
        switch event.type {
        case "agent-preset/selected":
            _ = try stringValue(data["agentPreset"], "\(subject) agentPreset")
        case "agent/inbox/spliced":
            try literalStrings(data["target"], allowed: ["next-turn", "next-step"],
                               label: "\(subject) target")
            _ = try countValue(data["start"], "\(subject) start")
            if data["removedCount"] != nil {
                _ = try countValue(data["removedCount"], "\(subject) removedCount")
            }
            try arrayValue(data["inserted"], "\(subject) inserted") { value, label in
                try messageValue(value, label, version: version, expected: "user")
            }
            if let outcome = data["outcome"] {
                try literalStrings(outcome, allowed: ["canceled"], label: "\(subject) outcome")
            }
        case "approval/asked":
            try nonEmptyString(data["id"], "\(subject) id")
            try nonEmptyString(data["toolName"], "\(subject) toolName")
            if let callID = data["callId"] { try nonEmptyString(callID, "\(subject) callId") }
            if let reason = data["reason"] { _ = try stringValue(reason, "\(subject) reason") }
        case "approval/decided":
            try nonEmptyString(data["id"], "\(subject) id")
            try literalStrings(data["outcome"],
                               allowed: ["allowed-once", "rejected", "cancelled", "unavailable"],
                               label: "\(subject) outcome")
        case "approval/policy":
            try literalStrings(data["policy"], allowed: ["ask", "never"], label: "\(subject) policy")
            if let source = data["source"] {
                try literalStrings(source, allowed: ["delegation"], label: "\(subject) source")
            }
        case "assistant/chunk":
            try coordinatePair(data, subject: subject)
            try streamChunkValue(data["chunk"], "\(subject) chunk")
        case "assistant/message":
            try coordinatePair(data, subject: subject)
            try messageValue(data["message"], "\(subject) message", version: version,
                             expected: "assistant")
            if let usage = data["usage"] { try tokenUsageValue(usage, "\(subject) usage") }
            if let interrupted = data["interrupted"] { try literalTrue(interrupted, "\(subject) interrupted") }
        case "command/done":
            try nonEmptyString(data["commandId"], "\(subject) commandId")
            try literalStrings(data["kind"], allowed: ["success", "error"], label: "\(subject) kind")
            if let text = data["text"] { _ = try stringValue(text, "\(subject) text") }
            if let seq = data["sourceEventSeq"] {
                _ = try earlierSeq(seq, event.sequence, "\(subject) sourceEventSeq")
            }
        case "command/run":
            try nonEmptyString(data["commandId"], "\(subject) commandId")
            try nonEmptyString(data["name"], "\(subject) name")
            if let args = data["args"] { _ = try stringValue(args, "\(subject) args") }
            let source = try exactRecord(data["source"], "\(subject) source", required: ["kind"])
            try literalStrings(source["kind"], allowed: ["user"], label: "\(subject) source kind")
        case "compaction/start", "compaction/end":
            try nonEmptyString(data["compactionId"], "\(subject) compactionId")
            if let commandID = data["sourceCommandId"] {
                try nonEmptyString(commandID, "\(subject) sourceCommandId")
            }
            try nullableValue(data["turn"], "\(subject) turn") { value, label in
                _ = try countValue(value, label)
            }
            if let error = data["error"] { _ = try stringValue(error, "\(subject) error") }
        case "compaction/prune":
            try shadowedValue(data, eventSeq: event.sequence, subject: subject)
        case "compaction/summary":
            if data["llmStreamCall"] as? Bool == true, data["rawOutput"] == nil {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) llmStreamCall requires rawOutput")
            }
            try nonEmptyString(data["compactionId"], "\(subject) compactionId")
            if let commandID = data["sourceCommandId"] {
                try nonEmptyString(commandID, "\(subject) sourceCommandId")
            }
            try contentBlocksValue(data["summary"], "\(subject) summary", version: version)
            try shadowedValue(data, eventSeq: event.sequence, subject: subject)
            try nonEmptyString(data["provider"], "\(subject) provider")
            try nonEmptyString(data["model"], "\(subject) model")
            if let maxTokens = data["maxTokens"] {
                _ = try countValue(maxTokens, "\(subject) maxTokens")
            }
            if let usage = data["usage"] { try tokenUsageValue(usage, "\(subject) usage") }
            if let raw = data["rawOutput"] {
                try contentBlocksValue(raw, "\(subject) rawOutput", version: version)
            }
            if let streamCall = data["llmStreamCall"] {
                try literalTrue(streamCall, "\(subject) llmStreamCall")
            }
        case "feedback/record":
            try nonEmptyString(data["text"], "\(subject) text")
        case "goal/change":
            try goalChangeValue(data, subject: subject)
        case "hook/invoked":
            _ = try countValue(data["turn"], "\(subject) turn")
            try nonEmptyString(data["point"], "\(subject) point")
            try literalStrings(data["dialect"], allowed: ["claude-code", "codex"],
                               label: "\(subject) dialect")
            if let matcher = data["matcher"] { _ = try stringValue(matcher, "\(subject) matcher") }
            try nonEmptyString(data["handlerId"], "\(subject) handlerId")
        case "hook/result":
            _ = try countValue(data["turn"], "\(subject) turn")
            try nonEmptyString(data["point"], "\(subject) point")
            try nonEmptyString(data["handlerId"], "\(subject) handlerId")
            try nonEmptyString(data["decision"], "\(subject) decision")
            if let code = data["exitCode"] {
                _ = try safeIntegerValue(code, "\(subject) exitCode")
            }
            if let stderr = data["stderrSummary"] {
                _ = try stringValue(stderr, "\(subject) stderrSummary")
            }
            if try finiteNumberValue(data["durationMs"], "\(subject) durationMs") < 0 {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) durationMs must be non-negative")
            }
        case "llm/retry":
            try nonEmptyString(data["retryId"], "\(subject) retryId")
            try coordinatePair(data, subject: subject)
            try nonEmptyString(data["provider"], "\(subject) provider")
            try literalStrings(data["mode"], allowed: ["normal", "always"], label: "\(subject) mode")
            try nonEmptyString(data["policyKey"], "\(subject) policyKey")
            let retry = try positiveIntegerValue(data["retry"], "\(subject) retry")
            if data["mode"] as? String == "normal" {
                let maxRetries = try positiveIntegerValue(data["maxRetries"], "\(subject) maxRetries")
                if retry > maxRetries {
                    throw DeepSeekHarnessFormatError.invalidPayload("\(subject) retry exceeds maxRetries")
                }
            } else if data["maxRetries"] != nil {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) always mode must omit maxRetries")
            }
            let delayMs = try finiteNumberValue(data["delayMs"], "\(subject) delayMs")
            if delayMs < 0 {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) delayMs must be non-negative")
            }
            if delayMs > 2_147_483_647 {
                throw DeepSeekHarnessFormatError.invalidPayload("\(subject) delayMs exceeds the timer range")
            }
            try llmFailureValue(data["failure"], "\(subject) failure")
        case "llm/retry-started":
            try nonEmptyString(data["retryId"], "\(subject) retryId")
            try coordinatePair(data, subject: subject)
            _ = try positiveIntegerValue(data["retry"], "\(subject) retry")
        case "model/selection":
            try nonEmptyString(data["provider"], "\(subject) provider")
            try nonEmptyString(data["model"], "\(subject) model")
            if let effort = data["reasoningEffort"] {
                try nonEmptyString(effort, "\(subject) reasoningEffort")
            }
        case "permission/preset":
            try nonEmptyString(data["preset"], "\(subject) preset")
        case "plan/mode":
            _ = try booleanValue(data["active"], "\(subject) active")
        case "request/context":
            try nonEmptyString(data["provider"], "\(subject) provider")
            try nonEmptyString(data["model"], "\(subject) model")
            if let window = data["contextWindow"] {
                _ = try positiveIntegerValue(window, "\(subject) contextWindow")
            }
        case "request/header":
            try requestHeaderValue(data["header"], "\(subject) header")
            try literalStrings(data["reason"], allowed: ["initial", "resume", "change", "series"],
                               label: "\(subject) reason")
            if let starts = data["startsSeries"] {
                try literalTrue(starts, "\(subject) startsSeries")
            }
        case "sandbox/mode":
            try literalStrings(data["mode"],
                               allowed: ["read-only", "workspace-write", "danger-full-access"],
                               label: "\(subject) mode")
            if let source = data["source"] {
                try literalStrings(source, allowed: ["delegation"], label: "\(subject) source")
            }
        case "schedule/change":
            try scheduleChangeValue(data, subject: subject)
        case "session-log-deepseek/delivery-accepted":
            let acceptedVersion = data["sessionFormatVersion"] == nil
                ? 0 : try countValue(data["sessionFormatVersion"], "\(subject) sessionFormatVersion")
            if acceptedVersion != version { return }
            try nonEmptyString(data["sessionId"], "\(subject) sessionId")
            _ = try earlierSeq(data["throughSeq"], event.sequence, "\(subject) throughSeq")
        case "session/end-seed":
            return
        case "session/title":
            try nonEmptyString(data["title"], "\(subject) title")
            _ = try seqArray(data["messageSeqs"], eventSeq: event.sequence,
                             label: "\(subject) messageSeqs", requireNonEmpty: false)
            try titleSourceValue(data["source"], "\(subject) source")
        case "session/title-llm-request":
            try nonEmptyString(data["titleProvider"], "\(subject) titleProvider")
            _ = try seqArray(data["messageSeqs"], eventSeq: event.sequence,
                             label: "\(subject) messageSeqs", requireNonEmpty: true)
            try modelRouteValue(data["route"], "\(subject) route")
            _ = try stringValue(data["system"], "\(subject) system")
            try arrayValue(data["messages"], "\(subject) messages") { value, label in
                try messageValue(value, label, version: version, expected: nil)
            }
            _ = try positiveIntegerValue(data["maxTokens"], "\(subject) maxTokens")
        case "step/end", "step/start":
            try coordinatePair(data, subject: subject)
        case "subagent/descriptor":
            try subagentDescriptorValue(data, subject: subject)
        case "subagent/model-selection-policy":
            try allowedModelsValue(data["allowedModels"], "\(subject) allowedModels")
        case "team/member":
            try teamSelector(data, subject: subject)
            try teamMemberValue(data["member"], "\(subject) member")
        case "team/message/delivered":
            try teamSelector(data, subject: subject)
            try nonEmptyString(data["messageId"], "\(subject) messageId")
            try nonEmptyString(data["targetId"], "\(subject) targetId")
        case "team/message/queued":
            try teamSelector(data, subject: subject)
            try teamMessageValue(data["message"], "\(subject) message", version: version)
        case "team/task":
            try teamSelector(data, subject: subject)
            try teamTaskValue(data["task"], "\(subject) task")
        case "todo/write":
            try arrayValue(data["todos"], "\(subject) todos") { value, label in
                let item = try exactRecord(value, label, required: ["content", "status"])
                _ = try stringValue(item["content"], "\(label) content")
                try literalStrings(item["status"], allowed: ["pending", "in_progress", "completed"],
                                   label: "\(label) status")
            }
        case "tool-workflow/agent-end":
            try workflowIdentity(data, subject: subject)
            try literalStrings(data["outcome"], allowed: ["completed", "failed", "cancelled"],
                               label: "\(subject) outcome")
        case "tool-workflow/agent-start":
            try workflowIdentity(data, subject: subject)
            _ = try stringValue(data["label"], "\(subject) label")
            if let phase = data["phase"] { _ = try stringValue(phase, "\(subject) phase") }
            try nonEmptyString(data["childId"], "\(subject) childId")
        case "tool-workflow/run-end":
            try nonEmptyString(data["runId"], "\(subject) runId")
            try literalStrings(data["stopReason"], allowed: ["completed", "cancelled", "error"],
                               label: "\(subject) stopReason")
        case "tool-workflow/run-start":
            try nonEmptyString(data["runId"], "\(subject) runId")
            try nonEmptyString(data["name"], "\(subject) name")
        case "tool/call":
            try coordinatePair(data, subject: subject)
            try nonEmptyString(data["callId"], "\(subject) callId")
            try nonEmptyString(data["name"], "\(subject) name")
            _ = try stringValue(data["arguments"], "\(subject) arguments")
        case "tool/code-dispatch", "tool/code-dispatch-start":
            try nonEmptyString(data["rootCallId"], "\(subject) rootCallId")
            try nonEmptyString(data["parentCallId"], "\(subject) parentCallId")
            try nonEmptyString(data["subCallId"], "\(subject) subCallId")
            try nonEmptyString(data["name"], "\(subject) name")
            if event.type == "tool/code-dispatch" {
                _ = try booleanValue(data["isError"], "\(subject) isError")
                try contentBlocksValue(data["content"], "\(subject) content", version: version)
            }
        case "tool/result":
            try coordinatePair(data, subject: subject)
            try messageValue(data["message"], "\(subject) message", version: version, expected: "tool")
            if let error = data["error"] {
                let record = try exactRecord(error, "\(subject) error", required: ["name", "code"])
                try nonEmptyString(record["name"], "\(subject) error name")
                try nonEmptyString(record["code"], "\(subject) error code")
            }
        case "turn/end":
            _ = try countValue(data["turn"], "\(subject) turn")
            try turnEndReasonValue(data["reason"], "\(subject) reason")
        case "turn/start":
            _ = try countValue(data["turn"], "\(subject) turn")
        case "user/message":
            try messageValue(data, subject, version: version, expected: "user")
        case "web/deepseek-search-llm-request":
            try nonEmptyString(data["endpoint"], "\(subject) endpoint")
            try nonEmptyString(data["apiVersion"], "\(subject) apiVersion")
            try deepSeekSearchBodyValue(data["body"], "\(subject) body")
        default:
            throw DeepSeekHarnessFormatError.invalidPayload(
                "released payload validator is missing event \(event.type)")
        }
    }

    // MARK: - Scalar and structural helpers

    /// Strict JSON boolean identity: numeric 0/1 must never read as false/true.
    static func strictBool(_ value: Any?) -> Bool? {
        DeepSeekHarnessJSON.bool(value)
    }

    static func record(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be an object")
        }
        return object
    }

    static func exactRecord(
        _ value: Any?,
        _ label: String,
        required: [String],
        optional: [String] = []
    ) throws -> [String: Any] {
        let object = try record(value, label)
        try keys(object, required: required, optional: optional, label: label)
        return object
    }

    static func keys(
        _ value: [String: Any],
        required: [String],
        optional: [String],
        label: String
    ) throws {
        let allowed = Set(required + optional)
        if let unexpected = value.keys.first(where: { !allowed.contains($0) }) {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) has unexpected field \(unexpected)")
        }
        if let missing = required.first(where: { value[$0] == nil }) {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) lacks required field \(missing)")
        }
    }

    static func isLosslessJSON(_ value: Any) -> Bool {
        if value is String || value is NSNull { return true }
        if DeepSeekHarnessJSON.bool(value) != nil { return true }
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite
        }
        if let array = value as? [Any] { return array.allSatisfy(isLosslessJSON) }
        if let object = value as? [String: Any] {
            return object.values.allSatisfy(isLosslessJSON)
        }
        return false
    }

    @discardableResult
    static func stringValue(_ value: Any?, _ label: String) throws -> String {
        guard let text = value as? String else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be a string")
        }
        return text
    }

    @discardableResult
    static func nonEmptyString(_ value: Any?, _ label: String) throws -> String {
        guard let text = value as? String, !text.isEmpty else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be a non-empty string")
        }
        return text
    }

    @discardableResult
    static func booleanValue(_ value: Any?, _ label: String) throws -> Bool {
        guard let flag = strictBool(value) else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be a boolean")
        }
        return flag
    }

    @discardableResult
    static func countValue(_ value: Any?, _ label: String) throws -> Int {
        guard let count = DeepSeekHarnessJSON.count(value) else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be a count")
        }
        return count
    }

    @discardableResult
    static func safeIntegerValue(_ value: Any?, _ label: String) throws -> Int {
        guard let integer = DeepSeekHarnessJSON.safeInt(value) else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be a safe integer")
        }
        return integer
    }

    @discardableResult
    static func positiveIntegerValue(_ value: Any?, _ label: String) throws -> Int {
        let result = try countValue(value, label)
        guard result > 0 else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be positive")
        }
        return result
    }

    @discardableResult
    static func finiteNumberValue(_ value: Any?, _ label: String) throws -> Double {
        guard let number = value as? NSNumber, strictBool(value) == nil else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be a finite number")
        }
        let raw = number.doubleValue
        guard raw.isFinite, !(raw == 0 && raw.sign == .minus) else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be a finite number")
        }
        return raw
    }

    static func literalStrings(_ value: Any?, allowed: [String], label: String) throws {
        guard let text = value as? String, allowed.contains(text) else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) must be one of \(allowed.joined(separator: ", "))")
        }
    }

    static func literalTrue(_ value: Any?, _ label: String) throws {
        guard strictBool(value) == true else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be true")
        }
    }

    static func literalInt(_ value: Any?, allowed: [Int], label: String) throws {
        guard let integer = DeepSeekHarnessJSON.safeInt(value), allowed.contains(integer) else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) must be one of \(allowed.map { String($0) }.joined(separator: ", "))")
        }
    }

    static func nullableValue(
        _ value: Any?,
        _ label: String,
        _ validate: (Any?, String) throws -> Void
    ) throws {
        if value == nil || value is NSNull { return }
        try validate(value, label)
    }

    @discardableResult
    static func arrayValue(
        _ value: Any?,
        _ label: String,
        _ validate: (Any, String) throws -> Void
    ) throws -> [Any] {
        guard let members = value as? [Any] else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be an array")
        }
        for (index, member) in members.enumerated() {
            try validate(member, "\(label)[\(index)]")
        }
        return members
    }

    static func contentArray(_ value: Any?, label: String) throws -> [Any] {
        guard let members = value as? [Any] else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label): content must be an array")
        }
        return members
    }

    static func coordinatePair(_ data: [String: Any], subject: String) throws {
        _ = try countValue(data["turn"], "\(subject) turn")
        _ = try countValue(data["step"], "\(subject) step")
    }

    @discardableResult
    static func earlierSeq(_ value: Any?, _ eventSeq: Int, _ label: String) throws -> Int {
        let seq = try countValue(value, label)
        guard seq < eventSeq else {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must identify an earlier event")
        }
        return seq
    }

    @discardableResult
    static func seqArray(
        _ value: Any?,
        eventSeq: Int,
        label: String,
        requireNonEmpty: Bool
    ) throws -> [Any] {
        var seen = Set<Int>()
        let values = try arrayValue(value, label) { member, memberLabel in
            let seq = try earlierSeq(member, eventSeq, memberLabel)
            guard !seen.contains(seq) else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(label) repeats seq \(seq)")
            }
            seen.insert(seq)
        }
        if requireNonEmpty, values.isEmpty {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be non-empty")
        }
        return values
    }

    // MARK: - Content, messages, sources

    static func contentBlocksValue(_ value: Any?, _ label: String, version: Int) throws {
        try arrayValue(value, label) { member, memberLabel in
            try contentBlockValue(member, memberLabel, version: version)
        }
    }

    static func contentBlockValue(_ value: Any?, _ label: String, version: Int) throws {
        let block = try record(value, label)
        switch block["type"] as? String {
        case "text", "reasoning":
            try keys(block, required: ["type", "text"], optional: [], label: label)
            _ = try stringValue(block["text"], "\(label) text")
        case "image":
            try keys(block, required: ["type", "attachment"], optional: [], label: label)
            try imageAttachmentValue(block["attachment"], "\(label) attachment")
        case "tool-call":
            try keys(block, required: ["type", "id", "name", "arguments"], optional: [], label: label)
            try nonEmptyString(block["id"], "\(label) id")
            try nonEmptyString(block["name"], "\(label) name")
            _ = try stringValue(block["arguments"], "\(label) arguments")
        case "tool-result":
            try keys(block, required: ["type", "toolCallId", "content"], optional: ["isError"],
                     label: label)
            try nonEmptyString(block["toolCallId"], "\(label) toolCallId")
            try contentBlocksValue(block["content"], "\(label) content", version: version)
            if let isError = block["isError"] {
                _ = try booleanValue(isError, "\(label) isError")
            }
        default:
            try nonEmptyString(block["type"], "\(label) type")
        }
    }

    static func imageAttachmentValue(_ value: Any?, _ label: String) throws {
        let attachment = try exactRecord(
            value, label,
            required: ["attachmentId", "mediaType", "bytes", "width", "height"],
            optional: ["name", "originalDimensions"])
        try nonEmptyString(attachment["attachmentId"], "\(label) attachmentId")
        try literalStrings(attachment["mediaType"],
                           allowed: ["image/png", "image/jpeg", "image/webp", "image/gif"],
                           label: "\(label) mediaType")
        _ = try countValue(attachment["bytes"], "\(label) bytes")
        _ = try positiveIntegerValue(attachment["width"], "\(label) width")
        _ = try positiveIntegerValue(attachment["height"], "\(label) height")
        if let name = attachment["name"] { _ = try stringValue(name, "\(label) name") }
        if let dimensions = attachment["originalDimensions"] {
            let record = try exactRecord(dimensions, "\(label) originalDimensions",
                                         required: ["width", "height"])
            _ = try positiveIntegerValue(record["width"], "\(label) original width")
            _ = try positiveIntegerValue(record["height"], "\(label) original height")
        }
    }

    /// Ports `messageValue`: exact id/role/content/source, role pinned to
    /// the expected surface role, frozen content, versioned source, and the
    /// single-block tool-result identity check.
    static func messageValue(
        _ value: Any?,
        _ label: String,
        version: Int,
        expected: String?
    ) throws {
        let message = try exactRecord(value, label,
                                      required: ["id", "role", "content", "source"])
        try nonEmptyString(message["id"], "\(label) id")
        if let expected {
            let role = expected == "assistant" ? "assistant" : "user"
            try literalStrings(message["role"], allowed: [role], label: "\(label) role")
        } else {
            try literalStrings(message["role"], allowed: ["system", "user", "assistant"],
                               label: "\(label) role")
        }
        try contentBlocksValue(message["content"], "\(label) content", version: version)
        let source = try record(message["source"], "\(label) source")
        if version < 2, expected == "user",
           source["kind"] as? String == "goal", source["change"] != nil {
            try legacyGoalMessageValue(message, source: source, label: label)
        } else {
            try messageSourceValue(source, "\(label) source", version: version, expected: expected)
        }
        if expected == "tool" {
            guard let content = message["content"] as? [Any], content.count == 1,
                  let block = content[0] as? [String: Any],
                  block["type"] as? String == "tool-result",
                  block["toolCallId"] as? String == source["callId"] as? String,
                  source["callId"] is String else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label) must contain exactly one tool-result block")
            }
        }
    }

    /// Ports the v0 legacy goal message shape (versioned out at v2 but
    /// kept for source fidelity): the goal source must match its change
    /// and the text frame must carry the exact goal-state payload.
    private static func legacyGoalMessageValue(
        _ message: [String: Any],
        source: [String: Any],
        label: String
    ) throws {
        try keys(source, required: ["kind", "goalId", "revision", "round", "change"],
                 optional: [], label: "\(label) source")
        try nonEmptyString(source["goalId"], "\(label) source goalId")
        _ = try positiveIntegerValue(source["revision"], "\(label) source revision")
        guard let round = DeepSeekHarnessJSON.count(source["round"]), round == 0 else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) legacy goal source round must be 0")
        }
        let change = try record(source["change"], "\(label) source change")
        try goalChangeValue(change, subject: "\(label) source change")
        let ref = try record(
            change["operation"] as? String == "clear" ? change["cleared"] : change["goal"],
            "\(label) source change ref")
        guard source["goalId"] as? String == ref["id"] as? String,
              DeepSeekHarnessJSON.count(source["revision"]) == DeepSeekHarnessJSON.count(ref["revision"]) else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) legacy goal source does not match its change")
        }
    }

    /// Ports `messageSourceValue`: the frozen per-kind source shapes.
    /// Unlisted kinds pass with a non-empty kind here; the released-kind
    /// inventory itself is enforced by `assertV2Source`.
    static func messageSourceValue(
        _ value: Any?,
        _ label: String,
        version: Int,
        expected: String?
    ) throws {
        let source = try record(value, label)
        if expected == "assistant", source["kind"] as? String != "model" {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be model source")
        }
        if expected == "tool", source["kind"] as? String != "tool" {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be tool source")
        }
        switch source["kind"] as? String {
        case "user":
            try keys(source, required: ["kind"], optional: ["rpcId", "clientTimeZone"], label: label)
            if let rpcID = source["rpcId"] { try nonEmptyString(rpcID, "\(label) rpcId") }
            if let zone = source["clientTimeZone"] {
                try nonEmptyString(zone, "\(label) clientTimeZone")
            }
        case "plugin":
            try pluginSourceValue(source, label: label)
        case "model":
            try keys(source, required: ["kind", "provider", "model"], optional: ["replayState"],
                     label: label)
            try nonEmptyString(source["provider"], "\(label) provider")
            try nonEmptyString(source["model"], "\(label) model")
        case "tool":
            try keys(source, required: ["kind", "callId"], optional: [], label: label)
            try nonEmptyString(source["callId"], "\(label) callId")
        case "agent-instructions":
            try keys(source, required: ["kind", "form", "changes"],
                     optional: ["baseline", "baselineIdentity"], label: label)
            try literalStrings(source["form"], allowed: ["instructions"], label: "\(label) form")
            if let baseline = source["baseline"] { try literalTrue(baseline, "\(label) baseline") }
            if let identity = source["baselineIdentity"] {
                try nonEmptyString(identity, "\(label) baselineIdentity")
            }
            try arrayValue(source["changes"], "\(label) changes") { member, memberLabel in
                let change = try exactRecord(member, memberLabel,
                                             required: ["action", "scope", "path"],
                                             optional: ["digest"])
                try literalStrings(change["action"], allowed: ["set", "replace", "remove"],
                                   label: "\(memberLabel) action")
                _ = try stringValue(change["scope"], "\(memberLabel) scope")
                _ = try stringValue(change["path"], "\(memberLabel) path")
                if let digest = change["digest"] {
                    _ = try stringValue(digest, "\(memberLabel) digest")
                }
            }
        case "session-reference":
            try sessionReferenceSourceValue(source, label: label, version: version)
        case "team-message":
            try keys(source, required: ["kind", "teamId", "messageId", "senderId", "senderName"],
                     optional: [], label: label)
            for key in ["teamId", "messageId", "senderId"] {
                try nonEmptyString(source[key], "\(label) \(key)")
            }
            _ = try stringValue(source["senderName"], "\(label) senderName")
        case "goal":
            try keys(source, required: ["kind", "goalId", "revision", "round"],
                     optional: [], label: label)
            try nonEmptyString(source["goalId"], "\(label) goalId")
            _ = try positiveIntegerValue(source["revision"], "\(label) revision")
            _ = try positiveIntegerValue(source["round"], "\(label) round")
        case "skill-invocation":
            try keys(source, required: ["kind", "name", "form"], optional: [], label: label)
            try nonEmptyString(source["name"], "\(label) name")
            try literalStrings(source["form"], allowed: ["instructions"], label: "\(label) form")
        case "skill-catalog":
            try keys(source, required: ["kind", "form", "entries"], optional: ["update"],
                     label: label)
            try literalStrings(source["form"], allowed: ["catalog"], label: "\(label) form")
            if let update = source["update"] { try literalTrue(update, "\(label) update") }
            try arrayValue(source["entries"], "\(label) entries") { member, memberLabel in
                let entry = try exactRecord(member, memberLabel,
                                            required: ["name", "description"])
                try nonEmptyString(entry["name"], "\(memberLabel) name")
                _ = try stringValue(entry["description"], "\(memberLabel) description")
            }
        case "coordinator", "subagent-report":
            try keys(source, required: ["kind", "form", "senderSessionId"], optional: [],
                     label: label)
            try literalStrings(source["form"], allowed: ["relay"], label: "\(label) form")
            try nonEmptyString(source["senderSessionId"], "\(label) senderSessionId")
        case "subagent-settled":
            try keys(source, required: ["kind", "form", "summary", "senderSessionId"],
                     optional: [], label: label)
            try literalStrings(source["form"], allowed: ["notice"], label: "\(label) form")
            _ = try stringValue(source["summary"], "\(label) summary")
            try nonEmptyString(source["senderSessionId"], "\(label) senderSessionId")
        case "webhook":
            try keys(source,
                     required: ["kind", "provider", "source", "deliveryId", "ruleId", "form", "summary"],
                     optional: [], label: label)
            for key in ["provider", "source", "deliveryId", "ruleId"] {
                try nonEmptyString(source[key], "\(label) \(key)")
            }
            try literalStrings(source["form"], allowed: ["notice"], label: "\(label) form")
            _ = try stringValue(source["summary"], "\(label) summary")
        default:
            try nonEmptyString(source["kind"], "\(label) kind")
        }
    }

    private static func pluginSourceValue(_ source: [String: Any], label: String) throws {
        var optional = ["form", "sections", "summary"]
        if source["plugin"] as? String == "compact" {
            optional += ["compactionId", "sourceCommandId"]
        }
        try keys(source, required: ["kind", "plugin"], optional: optional, label: label)
        try nonEmptyString(source["plugin"], "\(label) plugin")
        if source["plugin"] as? String == "compact" {
            // The frozen reference requires compactionId here even though it
            // is optional in the key admission above.
            try nonEmptyString(source["compactionId"], "\(label) compactionId")
            if let commandID = source["sourceCommandId"] {
                try nonEmptyString(commandID, "\(label) sourceCommandId")
            }
        }
        guard let form = source["form"] else { return }
        try literalStrings(form,
                           allowed: ["instructions", "catalog", "snapshot", "notice", "relay", "recall"],
                           label: "\(label) form")
        if form as? String == "snapshot" {
            try arrayValue(source["sections"], "\(label) sections") { member, memberLabel in
                let section = try exactRecord(member, memberLabel, required: ["name", "text"])
                try nonEmptyString(section["name"], "\(memberLabel) name")
                _ = try stringValue(section["text"], "\(memberLabel) text")
            }
        } else if source["sections"] != nil {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) sections require snapshot form")
        }
        if form as? String == "notice" {
            _ = try stringValue(source["summary"], "\(label) summary")
        } else if source["summary"] != nil {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) summary requires notice form")
        }
    }

    private static func sessionReferenceSourceValue(
        _ source: [String: Any],
        label: String,
        version: Int
    ) throws {
        try keys(source, required: ["kind", "form", "version", "references"],
                 optional: [], label: label)
        try literalStrings(source["form"], allowed: ["recall"], label: "\(label) form")
        try literalInt(source["version"], allowed: [1], label: "\(label) version")
        var expectedInputIndex = 0
        var sessionIDs = Set<String>()
        let references = try arrayValue(source["references"], "\(label) references") {
            member, memberLabel in
            let reference = try exactRecord(
                member, memberLabel,
                required: ["sessionId", "label", "capturedThroughSeq", "compacted",
                           "originalMessages", "retainedMessages", "omittedMessages",
                           "omittedBytes", "truncated", "inputIndex"],
                optional: version >= 1 ? ["capturedFormatVersion"] : [])
            try nonEmptyString(reference["sessionId"], "\(memberLabel) sessionId")
            _ = try stringValue(reference["label"], "\(memberLabel) label")
            if reference["capturedThroughSeq"] != nil, !(reference["capturedThroughSeq"] is NSNull) {
                _ = try countValue(reference["capturedThroughSeq"],
                                   "\(memberLabel) capturedThroughSeq")
            }
            if let captured = reference["capturedFormatVersion"] {
                let capturedVersion = try countValue(captured, "\(memberLabel) capturedFormatVersion")
                guard capturedVersion >= 1, capturedVersion <= version else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(memberLabel) capturedFormatVersion must be between 1 and \(version)")
                }
            }
            _ = try booleanValue(reference["compacted"], "\(memberLabel) compacted")
            let original = try countValue(reference["originalMessages"], "\(memberLabel) originalMessages")
            let retained = try countValue(reference["retainedMessages"], "\(memberLabel) retainedMessages")
            let omitted = try countValue(reference["omittedMessages"], "\(memberLabel) omittedMessages")
            let omittedBytes = try countValue(reference["omittedBytes"], "\(memberLabel) omittedBytes")
            let inputIndex = try countValue(reference["inputIndex"], "\(memberLabel) inputIndex")
            let truncated = try booleanValue(reference["truncated"], "\(memberLabel) truncated")
            guard retained <= original, omitted == original - retained else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(memberLabel) message counts are inconsistent")
            }
            guard truncated == (omitted > 0 || omittedBytes > 0) else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(memberLabel) truncated disagrees with omitted content")
            }
            guard inputIndex == expectedInputIndex else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label) inputIndex must match reference position")
            }
            expectedInputIndex += 1
            guard let sessionID = reference["sessionId"] as? String, !sessionIDs.contains(sessionID) else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label) repeats sessionId \(reference["sessionId"] ?? "")")
            }
            sessionIDs.insert(sessionID)
        }
        if references.isEmpty {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) references must be non-empty")
        }
    }

    // MARK: - Streams, usage, failures, reasons

    static func streamChunkValue(_ value: Any?, _ label: String) throws {
        let chunk = try record(value, label)
        switch chunk["type"] as? String {
        case "block-start":
            try keys(chunk, required: ["type", "index", "blockType"], optional: [], label: label)
            _ = try countValue(chunk["index"], "\(label) index")
            try nonEmptyString(chunk["blockType"], "\(label) blockType")
        case "text-delta", "reasoning-delta":
            try keys(chunk, required: ["type", "index", "text"], optional: [], label: label)
            _ = try countValue(chunk["index"], "\(label) index")
            _ = try stringValue(chunk["text"], "\(label) text")
        case "tool-call-delta":
            try keys(chunk, required: ["type", "index", "id", "argumentsDelta"],
                     optional: ["name"], label: label)
            _ = try countValue(chunk["index"], "\(label) index")
            try nonEmptyString(chunk["id"], "\(label) id")
            if let name = chunk["name"] { _ = try stringValue(name, "\(label) name") }
            _ = try stringValue(chunk["argumentsDelta"], "\(label) argumentsDelta")
        case "block-end":
            try keys(chunk, required: ["type", "index", "block"], optional: [], label: label)
            _ = try countValue(chunk["index"], "\(label) index")
            // The frozen reference pins block validation to generation 1.
            try contentBlockValue(chunk["block"], "\(label) block", version: 1)
        case "usage":
            try keys(chunk, required: ["type", "usage"], optional: [], label: label)
            try tokenUsageValue(chunk["usage"], "\(label) usage")
        case "finish":
            try keys(chunk, required: ["type", "reason"], optional: ["replayState"], label: label)
            try finishReasonValue(chunk["reason"], "\(label) reason")
            if let replay = chunk["replayState"] {
                try replayEnvelopeValue(replay, "\(label) replayState")
            }
        default:
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) has unknown stream chunk type")
        }
    }

    private static func finishReasonValue(_ value: Any?, _ label: String) throws {
        let reason = try record(value, label)
        if reason["kind"] as? String == "aborted" || reason["kind"] as? String == "error" {
            try keys(reason, required: ["kind", "failure"], optional: [], label: label)
            try llmFailureValue(reason["failure"], "\(label) failure")
            return
        }
        if ["stop", "tool-calls", "max-tokens"].contains(reason["kind"] as? String) {
            try keys(reason, required: ["kind"], optional: [], label: label)
        }
        try nonEmptyString(reason["kind"], "\(label) kind")
    }

    private static func replayEnvelopeValue(_ value: Any?, _ label: String) throws {
        let replay = try exactRecord(value, label, required: ["response"], optional: ["blocks"])
        if let blocks = replay["blocks"], !(blocks is [Any]) {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) blocks must be an array")
        }
    }

    private static func turnEndReasonValue(_ value: Any?, _ label: String) throws {
        let reason = try record(value, label)
        switch reason["kind"] as? String {
        case "completed", "blocked", "max-tokens", "interrupted":
            try keys(reason, required: ["kind"], optional: [], label: label)
        case "aborted":
            try keys(reason, required: ["kind", "reason"], optional: [], label: label)
            let cause = try record(reason["reason"], "\(label) abort cause")
            if cause["kind"] as? String == "hook" {
                try keys(cause, required: ["kind", "reason"], optional: [],
                         label: "\(label) abort cause")
                _ = try stringValue(cause["reason"], "\(label) abort reason")
            } else {
                try keys(cause, required: ["kind"], optional: [], label: "\(label) abort cause")
                try literalStrings(cause["kind"], allowed: ["user", "parent", "disposed", "legacy"],
                                   label: "\(label) abort kind")
            }
        case "error":
            try keys(reason, required: ["kind", "error"], optional: [], label: label)
            try llmFailureValue(reason["error"], "\(label) error")
        default:
            try nonEmptyString(reason["kind"], "\(label) kind")
        }
    }

    static func tokenUsageValue(_ value: Any?, _ label: String) throws {
        let usage = try exactRecord(
            value, label,
            required: ["inputTokens", "outputTokens"],
            optional: ["totalTokens", "cacheReadTokens", "cacheWriteTokens", "reasoningTokens"])
        for key in usage.keys {
            _ = try countValue(usage[key], "\(label) \(key)")
        }
    }

    static func llmFailureValue(_ value: Any?, _ label: String) throws {
        let failure = try exactRecord(
            value, label,
            required: ["message", "code"],
            optional: ["status", "providerRetryAfterMs", "requestId"])
        try nonEmptyString(failure["message"], "\(label) message")
        try nonEmptyString(failure["code"], "\(label) code")
        if let status = failure["status"] {
            let code = try safeIntegerValue(status, "\(label) status")
            guard code >= 100, code <= 599 else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label) status must be 100 through 599")
            }
        }
        if let retryAfter = failure["providerRetryAfterMs"] {
            guard try finiteNumberValue(retryAfter, "\(label) providerRetryAfterMs") > 0 else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label) providerRetryAfterMs must be positive")
            }
        }
        if let requestID = failure["requestId"] {
            try nonEmptyString(requestID, "\(label) requestId")
        }
    }

    // MARK: - Headers, compaction, goals, schedules, titles, teams, search

    static func requestHeaderValue(_ value: Any?, _ label: String) throws {
        let header = try exactRecord(value, label, required: ["config"],
                                     optional: ["adapterDefaults", "system", "tools"])
        let config = try exactRecord(header["config"], "\(label) config",
                                     required: ["provider", "model"],
                                     optional: ["reasoningEffort", "temperature", "maxTokens", "stop"])
        try nonEmptyString(config["provider"], "\(label) provider")
        try nonEmptyString(config["model"], "\(label) model")
        if let effort = config["reasoningEffort"] {
            try nonEmptyString(effort, "\(label) reasoningEffort")
        }
        if let temperature = config["temperature"] {
            _ = try finiteNumberValue(temperature, "\(label) temperature")
        }
        if let maxTokens = config["maxTokens"] {
            _ = try positiveIntegerValue(maxTokens, "\(label) maxTokens")
        }
        if let stop = config["stop"] {
            try arrayValue(stop, "\(label) stop") { member, memberLabel in
                _ = try stringValue(member, memberLabel)
            }
        }
        if let defaults = header["adapterDefaults"] {
            let record = try exactRecord(defaults, "\(label) adapterDefaults", required: [],
                                         optional: ["reasoningEffort", "maxTokens"])
            for (key, marker) in record {
                guard strictBool(marker) == true else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(label) adapterDefaults \(key) must be true")
                }
                guard config[key] != nil else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "\(label) adapter default \(key) lacks config value")
                }
            }
        }
        if let system = header["system"] { _ = try stringValue(system, "\(label) system") }
        if let tools = header["tools"] {
            try arrayValue(tools, "\(label) tools") { member, memberLabel in
                try toolSchemaValue(member, label: memberLabel)
            }
        }
    }

    private static func toolSchemaValue(_ value: Any, label: String) throws {
        let schema = try exactRecord(value, label,
                                     required: ["name", "description", "parameters"])
        try nonEmptyString(schema["name"], "\(label) name")
        _ = try stringValue(schema["description"], "\(label) description")
        _ = try record(schema["parameters"], "\(label) parameters")
    }

    static func shadowedValue(_ data: [String: Any], eventSeq: Int, subject: String) throws {
        let range = try exactRecord(data["shadowedRange"], "\(subject) shadowedRange",
                                    required: ["start", "end"])
        let start = try earlierSeq(range["start"], eventSeq, "\(subject) shadowedRange start")
        let end = try earlierSeq(range["end"], eventSeq, "\(subject) shadowedRange end")
        let seqs = try seqArray(data["shadowedSeqs"], eventSeq: eventSeq,
                                label: "\(subject) shadowedSeqs", requireNonEmpty: true)
        let endpoints = seqs.compactMap { DeepSeekHarnessJSON.count($0) }
        guard endpoints.first == start, endpoints.last == end else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(subject) shadowedRange must match shadowedSeqs endpoints")
        }
        _ = try countValue(data["shadowedTokenCount"], "\(subject) shadowedTokenCount")
    }

    static func goalChangeValue(_ data: [String: Any], subject: String) throws {
        try literalStrings(data["kind"], allowed: ["goal/change"], label: "\(subject) kind")
        try literalInt(data["version"], allowed: [1], label: "\(subject) version")
        if data["operation"] as? String == "clear" {
            try keys(data, required: ["kind", "version", "operation", "cleared", "clearedAt"],
                     optional: [], label: "\(subject) data")
            try goalRefValue(data["cleared"], "\(subject) cleared")
            _ = try countValue(data["clearedAt"], "\(subject) clearedAt")
            return
        }
        try keys(data,
                 required: ["kind", "version", "operation", "goal", "roundsStarted",
                            "createdAt", "updatedAt"],
                 optional: [], label: "\(subject) data")
        try literalStrings(data["operation"],
                           allowed: ["create", "edit", "pause", "resume", "complete", "block"],
                           label: "\(subject) operation")
        try goalSnapshotValue(data["goal"], "\(subject) goal")
        _ = try countValue(data["roundsStarted"], "\(subject) roundsStarted")
        _ = try countValue(data["createdAt"], "\(subject) createdAt")
        _ = try countValue(data["updatedAt"], "\(subject) updatedAt")
    }

    private static func goalRefValue(_ value: Any?, _ label: String) throws {
        let ref = try exactRecord(value, label, required: ["id", "revision"])
        try nonEmptyString(ref["id"], "\(label) id")
        _ = try positiveIntegerValue(ref["revision"], "\(label) revision")
    }

    private static func goalSnapshotValue(_ value: Any?, _ label: String) throws {
        let goal = try exactRecord(value, label,
                                   required: ["id", "revision", "objective", "phase", "maxGoalRounds"],
                                   optional: ["blockedReason"])
        try nonEmptyString(goal["id"], "\(label) id")
        _ = try positiveIntegerValue(goal["revision"], "\(label) revision")
        try nonEmptyString(goal["objective"], "\(label) objective")
        try literalStrings(goal["phase"], allowed: ["active", "paused", "blocked", "complete"],
                           label: "\(label) phase")
        _ = try positiveIntegerValue(goal["maxGoalRounds"], "\(label) maxGoalRounds")
        if goal["phase"] as? String == "blocked" {
            let reason = try exactRecord(goal["blockedReason"], "\(label) blockedReason",
                                         required: ["code", "message"])
            try nonEmptyString(reason["code"], "\(label) blocked code")
            try nonEmptyString(reason["message"], "\(label) blocked message")
        } else if goal["blockedReason"] != nil {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) blockedReason requires blocked phase")
        }
    }

    static func scheduleChangeValue(_ data: [String: Any], subject: String) throws {
        try literalInt(data["version"], allowed: [1], label: "\(subject) version")
        if data["operation"] as? String == "create" {
            try keys(data, required: ["version", "operation", "schedule"],
                     optional: [], label: "\(subject) data")
            try scheduleRecordValue(data["schedule"], "\(subject) schedule")
            return
        }
        try keys(data, required: ["version", "operation", "id"],
                 optional: data["operation"] as? String == "dispatch" ? ["acceptedAt"] : [],
                 label: "\(subject) data")
        try literalStrings(data["operation"], allowed: ["delete", "dispatch"],
                           label: "\(subject) operation")
        try scheduleIDValue(data["id"], "\(subject) id")
        if let accepted = data["acceptedAt"] {
            try instantValue(accepted, "\(subject) acceptedAt")
        }
    }

    private static func scheduleRecordValue(_ value: Any?, _ label: String) throws {
        let record = try record(value, label)
        switch record["kind"] as? String {
        case "after":
            try keys(record, required: ["id", "kind", "prompt", "afterSeconds", "scheduledAt"],
                     optional: [], label: label)
            _ = try positiveIntegerValue(record["afterSeconds"], "\(label) afterSeconds")
        case "at":
            try keys(record, required: ["id", "kind", "prompt", "scheduledAt"],
                     optional: [], label: label)
        case "every":
            try keys(record, required: ["id", "kind", "prompt", "everySeconds", "scheduledAt"],
                     optional: [], label: label)
            let seconds = try positiveIntegerValue(record["everySeconds"], "\(label) everySeconds")
            guard seconds >= 300 else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(label) everySeconds must be at least 300")
            }
        default:
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) has unknown schedule kind")
        }
        try scheduleIDValue(record["id"], "\(label) id")
        try nonEmptyString(record["prompt"], "\(label) prompt")
        try instantValue(record["scheduledAt"], "\(label) scheduledAt")
    }

    private static func scheduleIDValue(_ value: Any?, _ label: String) throws {
        let text = try nonEmptyString(value, label)
        guard text.trimmingCharacters(in: .whitespaces) == text else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) must not have surrounding whitespace")
        }
    }

    /// Canonical UTC instants with millisecond precision (`YYYY-MM-DDTHH:MM:SS.sssZ`).
    static func instantValue(_ value: Any?, _ label: String) throws {
        guard let text = value as? String, text.count == 24 else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) must be a canonical UTC instant")
        }
        let chars = Array(text)
        func digits(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                // ASCII only, matching upstream `\d` without unicode flag.
                guard chars[index].isASCII, chars[index].isNumber,
                      let digit = chars[index].wholeNumberValue else {
                    return nil
                }
                result = result * 10 + digit
            }
            return result
        }
        guard chars[4] == "-", chars[7] == "-", chars[10] == "T", chars[13] == ":",
              chars[16] == ":", chars[19] == ".", chars[23] == "Z",
              let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hour = digits(11..<13), let minute = digits(14..<16),
              let second = digits(17..<19), digits(20..<23) != nil else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) must be a canonical UTC instant")
        }
        guard year != 0, (1...12).contains(month), hour <= 23, minute <= 59, second <= 59 else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) must be a canonical UTC instant")
        }
        let leap = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= monthLengths[month - 1] else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) must be a canonical UTC instant")
        }
    }

    static func titleSourceValue(_ value: Any?, _ label: String) throws {
        let source = try record(value, label)
        if source["kind"] as? String == "provider" {
            try keys(source, required: ["kind", "provider"], optional: ["model"], label: label)
            try nonEmptyString(source["provider"], "\(label) provider")
            if let model = source["model"] {
                try modelRouteValue(model, "\(label) model")
            }
            return
        }
        try keys(source, required: ["kind"], optional: [], label: label)
        try literalStrings(source["kind"], allowed: ["fallback", "user"], label: "\(label) kind")
    }

    static func modelRouteValue(_ value: Any?, _ label: String) throws {
        let route = try exactRecord(value, label, required: ["provider", "model"])
        try nonEmptyString(route["provider"], "\(label) provider")
        try nonEmptyString(route["model"], "\(label) model")
    }

    static func subagentDescriptorValue(_ data: [String: Any], subject: String) throws {
        try literalInt(data["version"], allowed: [3], label: "\(subject) version")
        try nonEmptyString(data["provider"], "\(subject) provider")
        if data["mode"] as? String == "one-shot" {
            try keys(data, required: ["mode", "version", "provider"], optional: ["label"],
                     label: "\(subject) data")
            if let label = data["label"] { _ = try stringValue(label, "\(subject) label") }
            return
        }
        try literalStrings(data["mode"], allowed: ["continuable"], label: "\(subject) mode")
        try nonEmptyString(data["label"], "\(subject) label")
        for key in ["agentProvider", "agentModel", "agentReasoningEffort", "persona"] {
            if let value = data[key] {
                try nonEmptyString(value, "\(subject) \(key)")
            }
        }
        guard (data["agentProvider"] == nil) == (data["agentModel"] == nil) else {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(subject) agentProvider and agentModel must be paired")
        }
        if let filter = data["toolFilter"] {
            let record = try exactRecord(filter, "\(subject) toolFilter", required: [],
                                         optional: ["allow", "deny"])
            guard record["allow"] != nil || record["deny"] != nil else {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(subject) toolFilter requires allow or deny")
            }
            if let allow = record["allow"] {
                try arrayValue(allow, "\(subject) allow") { member, memberLabel in
                    try nonEmptyString(member, memberLabel)
                }
            }
            if let deny = record["deny"] {
                try arrayValue(deny, "\(subject) deny") { member, memberLabel in
                    try nonEmptyString(member, memberLabel)
                }
            }
        }
    }

    static func allowedModelsValue(_ value: Any?, _ label: String) throws {
        var seen = Set<String>()
        let routes = try arrayValue(value, label) { member, memberLabel in
            let route = try exactRecord(member, memberLabel, required: ["provider", "model"])
            try nonEmptyString(route["provider"], "\(memberLabel) provider")
            try nonEmptyString(route["model"], "\(memberLabel) model")
            let key = "\(route["provider"] ?? "")\u{0}\(route["model"] ?? "")"
            guard !seen.contains(key) else {
                throw DeepSeekHarnessFormatError.invalidPayload("\(label) repeats route \(key)")
            }
            seen.insert(key)
        }
        if routes.isEmpty {
            throw DeepSeekHarnessFormatError.invalidPayload("\(label) must be non-empty")
        }
    }

    private static func teamSelector(_ data: [String: Any], subject: String) throws {
        try literalInt(data["version"], allowed: [1], label: "\(subject) version")
        try nonEmptyString(data["teamId"], "\(subject) teamId")
    }

    private static func teamMemberValue(_ value: Any?, _ label: String) throws {
        let member = try exactRecord(value, label,
                                     required: ["id", "name", "description", "provider",
                                                "context", "phase"],
                                     optional: ["error"])
        try nonEmptyString(member["id"], "\(label) id")
        _ = try stringValue(member["name"], "\(label) name")
        _ = try stringValue(member["description"], "\(label) description")
        _ = try stringValue(member["provider"], "\(label) provider")
        try literalStrings(member["context"], allowed: ["fresh", "fork"], label: "\(label) context")
        try literalStrings(member["phase"], allowed: ["provisioning", "active", "failed"],
                           label: "\(label) phase")
        if let error = member["error"] { _ = try stringValue(error, "\(label) error") }
    }

    private static func teamTaskValue(_ value: Any?, _ label: String) throws {
        let task = try exactRecord(
            value, label,
            required: ["id", "revision", "subject", "description", "status", "blockedBy", "writeScopes"],
            optional: ["ownerId"])
        try nonEmptyString(task["id"], "\(label) id")
        _ = try positiveIntegerValue(task["revision"], "\(label) revision")
        _ = try stringValue(task["subject"], "\(label) subject")
        _ = try stringValue(task["description"], "\(label) description")
        try literalStrings(task["status"],
                           allowed: ["pending", "in_progress", "completed", "deleted"],
                           label: "\(label) status")
        if let owner = task["ownerId"] { try nonEmptyString(owner, "\(label) ownerId") }
        try arrayValue(task["blockedBy"], "\(label) blockedBy") { member, memberLabel in
            try nonEmptyString(member, memberLabel)
        }
        try arrayValue(task["writeScopes"], "\(label) writeScopes") { member, memberLabel in
            _ = try stringValue(member, memberLabel)
        }
    }

    private static func teamMessageValue(_ value: Any?, _ label: String, version: Int) throws {
        let message = try exactRecord(value, label,
                                      required: ["id", "senderId", "senderName", "targetId",
                                                 "delivery", "content"])
        for key in ["id", "senderId", "targetId"] {
            try nonEmptyString(message[key], "\(label) \(key)")
        }
        _ = try stringValue(message["senderName"], "\(label) senderName")
        try literalStrings(message["delivery"], allowed: ["quiet", "wakeup"],
                           label: "\(label) delivery")
        try contentBlocksValue(message["content"], "\(label) content", version: version)
    }

    private static func workflowIdentity(_ data: [String: Any], subject: String) throws {
        try nonEmptyString(data["runId"], "\(subject) runId")
        _ = try positiveIntegerValue(data["seq"], "\(subject) seq")
    }

    static func deepSeekSearchBodyValue(_ value: Any?, _ label: String) throws {
        let body = try exactRecord(value, label,
                                   required: ["model", "max_tokens", "messages", "tools"])
        try nonEmptyString(body["model"], "\(label) model")
        _ = try positiveIntegerValue(body["max_tokens"], "\(label) max_tokens")
        let messages = try arrayValue(body["messages"], "\(label) messages") { member, memberLabel in
            let message = try exactRecord(member, memberLabel, required: ["role", "content"])
            try literalStrings(message["role"], allowed: ["user"], label: "\(memberLabel) role")
            let content = try arrayValue(message["content"], "\(memberLabel) content") {
                block, blockLabel in
                let text = try exactRecord(block, blockLabel, required: ["type", "text"])
                try literalStrings(text["type"], allowed: ["text"], label: "\(blockLabel) type")
                _ = try stringValue(text["text"], "\(blockLabel) text")
            }
            if content.count != 1 {
                throw DeepSeekHarnessFormatError.invalidPayload(
                    "\(memberLabel) content must contain one text block")
            }
        }
        if messages.count != 1 {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) messages must contain one user message")
        }
        let tools = try arrayValue(body["tools"], "\(label) tools") { member, memberLabel in
            let tool = try exactRecord(member, memberLabel,
                                       required: ["type", "name", "max_uses"])
            try literalStrings(tool["type"], allowed: ["web_search_20250305"],
                               label: "\(memberLabel) type")
            try literalStrings(tool["name"], allowed: ["web_search"], label: "\(memberLabel) name")
            _ = try positiveIntegerValue(tool["max_uses"], "\(memberLabel) max_uses")
        }
        if tools.count != 1 {
            throw DeepSeekHarnessFormatError.invalidPayload(
                "\(label) tools must contain one web search tool")
        }
    }
}
