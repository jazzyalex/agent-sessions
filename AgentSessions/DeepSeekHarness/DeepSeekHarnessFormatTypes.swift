import CryptoKit
import CoreFoundation
import Foundation

enum DeepSeekHarnessCompression: String, Sendable {
    case plain
    case zstd

    var suffix: String { self == .plain ? ".jsonl" : ".jsonl.zstd" }
}

// MARK: - Lossless JSON scalar helpers
//
// The pinned codecs distinguish safe integers from other numbers and reject
// non-canonical shapes. These helpers reproduce that admission without
// permissive fallbacks.

enum DeepSeekHarnessJSON {
    static let maxSafeInteger = 9_007_199_254_740_991

    static func safeInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            // Swift's `value is Bool` also accepts JSON-decoded NSNumber 0/1
            // on Darwin. Use the Core Foundation identity so integer zero and
            // one remain valid sequence/count values while true/false cannot
            // enter numeric fields.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let raw = number.doubleValue
            guard raw.isFinite, raw.rounded() == raw,
                  raw >= -Double(maxSafeInteger), raw <= Double(maxSafeInteger) else { return nil }
            return Int(raw)
        }
        if let direct = value as? Int {
            guard direct >= -maxSafeInteger, direct <= maxSafeInteger else { return nil }
            return direct
        }
        return nil
    }

    static func count(_ value: Any?) -> Int? {
        guard let result = safeInt(value), result >= 0 else { return nil }
        return result
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func safeAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum >= -maxSafeInteger, sum <= maxSafeInteger else { return nil }
        return sum
    }

    /// Deterministic canonical JSON with sorted keys. Used for repeat-output
    /// comparison and for deterministic generated identities.
    static func canonicalString(_ value: Any) -> String? {
        let candidate: Any = value
        guard JSONSerialization.isValidJSONObject(candidate) ||
            candidate is String || candidate is NSNumber else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: candidate,
            options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Header

struct DeepSeekHarnessHeader: Equatable, Sendable {
    let version: Int
    let id: String
    let createdAtMilliseconds: Int64
    let cwd: String?
    let parentSessionID: String?
    let isSeeded: Bool
    let origin: String?
    let delegationDepth: Int
    let agentPreset: String?

    /// Decodes a logical header (used by tests and post-migration stages).
    static func decode(_ object: [String: Any]) throws -> DeepSeekHarnessHeader {
        let (header, _) = try decodePhysical(object)
        return header
    }

    /// Decodes a released physical header for v0 through v3.
    /// Returns the logical header plus the physical inherited cut when the
    /// header itself carries it (v0/v1 `seedLength`). v2/v3 carry no cut; the
    /// reader derives it from `session/end-seed` markers.
    static func decodePhysical(_ object: [String: Any]) throws -> (DeepSeekHarnessHeader, Int?) {
        guard let version = DeepSeekHarnessJSON.safeInt(object["version"]) else {
            throw DeepSeekHarnessFormatError.invalidHeader
        }
        guard (0...3).contains(version) else {
            throw DeepSeekHarnessFormatError.unsupportedVersion(version)
        }
        guard (object["type"] as? String) == "session" else {
            throw DeepSeekHarnessFormatError.invalidHeader
        }
        if version <= 1 {
            let required = ["type", "version", "id", "createdAt", "delegationDepth"]
            let optional = ["cwd", "parentSession", "seedLength", "origin", "agentPreset"]
            try assertKeys(object, required: required, optional: optional, label: "header")
            guard let id = DeepSeekHarnessJSON.nonEmptyString(object["id"]),
                  let createdAt = DeepSeekHarnessJSON.count(object["createdAt"]),
                  let depth = DeepSeekHarnessJSON.count(object["delegationDepth"]) else {
                throw DeepSeekHarnessFormatError.invalidHeader
            }
            var cut = 0
            if let seed = object["seedLength"] {
                guard let seedLength = DeepSeekHarnessJSON.count(seed) else {
                    throw DeepSeekHarnessFormatError.invalidHeader
                }
                cut = seedLength
            }
            let header = try makeHeader(version: version, id: id, createdAt: createdAt,
                                        isSeeded: object["seedLength"] != nil, depth: depth, object: object)
            return (header, cut)
        }
        let required = ["type", "version", "id", "createdAt", "isSeeded", "delegationDepth"]
        let optional = ["cwd", "parentSession", "origin", "agentPreset"]
        try assertKeys(object, required: required, optional: optional, label: "header")
        guard let id = DeepSeekHarnessJSON.nonEmptyString(object["id"]),
              let createdAt = DeepSeekHarnessJSON.count(object["createdAt"]),
              let isSeeded = DeepSeekHarnessJSON.bool(object["isSeeded"]),
              let depth = DeepSeekHarnessJSON.count(object["delegationDepth"]) else {
            throw DeepSeekHarnessFormatError.invalidHeader
        }
        let header = try makeHeader(version: version, id: id, createdAt: createdAt,
                                    isSeeded: isSeeded, depth: depth, object: object)
        return (header, nil)
    }

    private static func makeHeader(version: Int, id: String, createdAt: Int, isSeeded: Bool,
                                   depth: Int, object: [String: Any]) throws -> DeepSeekHarnessHeader {
        var cwd: String?
        if let raw = object["cwd"] {
            guard let path = DeepSeekHarnessJSON.string(raw), path.hasPrefix("/") else {
                throw DeepSeekHarnessFormatError.invalidHeader
            }
            cwd = path
        }
        var parent: String?
        if let raw = object["parentSession"] {
            guard let text = DeepSeekHarnessJSON.string(raw) else {
                throw DeepSeekHarnessFormatError.invalidHeader
            }
            parent = text
        }
        var preset: String?
        if let raw = object["agentPreset"] {
            guard let text = DeepSeekHarnessJSON.string(raw) else {
                throw DeepSeekHarnessFormatError.invalidHeader
            }
            preset = text
        }
        var origin: String?
        if let raw = object["origin"] {
            guard (raw as? String) == "subagent" else {
                throw DeepSeekHarnessFormatError.invalidHeader
            }
            origin = "subagent"
        }
        return DeepSeekHarnessHeader(version: version, id: id,
                                     createdAtMilliseconds: Int64(createdAt), cwd: cwd,
                                     parentSessionID: parent, isSeeded: isSeeded,
                                     origin: origin, delegationDepth: depth, agentPreset: preset)
    }

    static func assertKeys(_ object: [String: Any], required: [String], optional: [String],
                           label: String) throws {
        let allowed = Set(required + optional)
        for key in object.keys where !allowed.contains(key) {
            throw DeepSeekHarnessFormatError.invalidHeader
        }
        for key in required where object[key] == nil {
            throw DeepSeekHarnessFormatError.invalidHeader
        }
    }
}

// MARK: - Envelope

/// Surface placement decoded from either released naming generation:
/// v0/v1/v2 use `start`/`end`, v3 uses `startSeq`/`endSeq`.
enum DeepSeekHarnessSurfaceOp: Equatable {
    case append
    case replace(start: Int, end: Int)
    case replaceV3(startSeq: Int, endSeq: Int)

    var startValue: Int? {
        switch self {
        case .append: return nil
        case .replace(let start, _): return start
        case .replaceV3(let startSeq, _): return startSeq
        }
    }

    var endValue: Int? {
        switch self {
        case .append: return nil
        case .replace(_, let end): return end
        case .replaceV3(_, let endSeq): return endSeq
        }
    }

    var isAppend: Bool {
        if case .append = self { return true }
        return false
    }

    func canonicalV3() -> DeepSeekHarnessSurfaceOp {
        switch self {
        case .append: return .append
        case .replace(let start, let end): return .replaceV3(startSeq: start, endSeq: end)
        case .replaceV3: return self
        }
    }

    func rawValue() -> Any {
        switch self {
        case .append: return "append"
        case .replace(let start, let end):
            return ["op": "replace", "start": start, "end": end] as [String: Any]
        case .replaceV3(let startSeq, let endSeq):
            return ["op": "replace", "startSeq": startSeq, "endSeq": endSeq] as [String: Any]
        }
    }
}

struct DeepSeekHarnessEnvelope {
    let type: String
    let sequence: Int
    let timeMilliseconds: Int64
    let data: [String: Any]
    let ignorable: Bool
    /// Expanded source seqs; range-encoded `[start, end]` storage pairs are
    /// expanded losslessly at decode time.
    let sourceEventSeqs: [Int]?
    let surfaceOp: DeepSeekHarnessSurfaceOp?
    let rawObject: [String: Any]

    init(type: String, sequence: Int, timeMilliseconds: Int64, data: [String: Any],
         ignorable: Bool = false, sourceEventSeqs: [Int]? = nil,
         surfaceOp: DeepSeekHarnessSurfaceOp? = nil, rawObject: [String: Any]? = nil) {
        self.type = type
        self.sequence = sequence
        self.timeMilliseconds = timeMilliseconds
        self.data = data
        self.ignorable = ignorable
        self.sourceEventSeqs = sourceEventSeqs
        self.surfaceOp = surfaceOp
        var raw: [String: Any] = ["type": type, "seq": sequence,
                                  "time": timeMilliseconds, "data": data]
        if ignorable { raw["ignorable"] = true }
        if let sourceEventSeqs { raw["sourceEventSeqs"] = sourceEventSeqs }
        if let surfaceOp { raw["surfaceOp"] = surfaceOp.rawValue() }
        self.rawObject = rawObject ?? raw
    }

    /// Decodes one physical envelope. Sequences are zero-based; density is
    /// enforced by the reader. Range-encoded `sourceEventSeqs` are expanded
    /// here; earlier-seq semantics are enforced by stage validation.
    static func decode(_ object: [String: Any]) throws -> DeepSeekHarnessEnvelope {
        let allowed: Set<String> = ["type", "seq", "time", "data", "ignorable",
                                    "sourceEventSeqs", "surfaceOp"]
        for key in object.keys where !allowed.contains(key) {
            throw DeepSeekHarnessFormatError.invalidEnvelope
        }
        guard let type = DeepSeekHarnessJSON.nonEmptyString(object["type"]),
              let seq = DeepSeekHarnessJSON.count(object["seq"]),
              let time = DeepSeekHarnessJSON.safeInt(object["time"]),
              let data = DeepSeekHarnessJSON.dictionary(object["data"]) else {
            throw DeepSeekHarnessFormatError.invalidEnvelope
        }
        var ignorable = false
        if let raw = object["ignorable"] {
            guard (raw as? Bool) == true else {
                throw DeepSeekHarnessFormatError.invalidEnvelope
            }
            ignorable = true
        }
        var sources: [Int]?
        if let raw = object["sourceEventSeqs"] {
            sources = try decodeSeqRanges(raw, seq: seq, label: "\(type) \(seq)")
        }
        var operation: DeepSeekHarnessSurfaceOp?
        if let raw = object["surfaceOp"] {
            operation = try decodeSurfaceOp(raw, seq: seq, label: "\(type) \(seq)")
        }
        return DeepSeekHarnessEnvelope(type: type, sequence: seq,
                                       timeMilliseconds: Int64(time), data: data,
                                       ignorable: ignorable, sourceEventSeqs: sources,
                                       surfaceOp: operation, rawObject: object)
    }

    static func decodeSeqRanges(_ value: Any, seq: Int, label: String) throws -> [Int] {
        guard let entries = DeepSeekHarnessJSON.array(value) else {
            throw DeepSeekHarnessFormatError.invalidReference("\(label) sourceEventSeqs must be an array")
        }
        var output: [Int] = []
        var hasRange = false
        for entry in entries {
            if let pair = entry as? [Any], !(entry is Bool) {
                guard pair.count == 2,
                      let start = DeepSeekHarnessJSON.count(pair[0]),
                      let end = DeepSeekHarnessJSON.count(pair[1]) else {
                    throw DeepSeekHarnessFormatError.invalidReference("\(label) sourceEventSeqs range must be a [start, end] pair")
                }
                guard end >= start, end - start + 1 <= seq - output.count else {
                    throw DeepSeekHarnessFormatError.invalidReference("\(label) sourceEventSeqs range exceeds its event seq")
                }
                for member in start...end { output.append(member) }
                hasRange = true
                continue
            }
            guard let member = DeepSeekHarnessJSON.count(entry) else {
                throw DeepSeekHarnessFormatError.invalidReference("\(label) sourceEventSeqs must contain non-negative safe integers")
            }
            guard output.count < seq else {
                throw DeepSeekHarnessFormatError.invalidReference("\(label) sourceEventSeqs exceeds its event seq")
            }
            output.append(member)
        }
        if hasRange {
            for index in 1..<output.count where output[index] <= output[index - 1] {
                throw DeepSeekHarnessFormatError.invalidReference("\(label) sourceEventSeqs ranges must be strictly increasing")
            }
        }
        return output
    }

    static func decodeSurfaceOp(_ value: Any, seq: Int, label: String) throws -> DeepSeekHarnessSurfaceOp {
        if let text = value as? String, text == "append" { return .append }
        guard let record = DeepSeekHarnessJSON.dictionary(value),
              (record["op"] as? String) == "replace" else {
            throw DeepSeekHarnessFormatError.invalidEnvelope
        }
        if record["startSeq"] != nil || record["endSeq"] != nil {
            guard Set(record.keys) == ["op", "startSeq", "endSeq"],
                  let start = DeepSeekHarnessJSON.count(record["startSeq"]),
                  let end = DeepSeekHarnessJSON.count(record["endSeq"]) else {
                throw DeepSeekHarnessFormatError.invalidEnvelope
            }
            return .replaceV3(startSeq: start, endSeq: end)
        }
        guard Set(record.keys) == ["op", "start", "end"],
              let start = DeepSeekHarnessJSON.count(record["start"]),
              let end = DeepSeekHarnessJSON.count(record["end"]) else {
            throw DeepSeekHarnessFormatError.invalidEnvelope
        }
        return .replace(start: start, end: end)
    }
}

// MARK: - Released packed assistant rows (v0/v1 physical only)

/// A released packed assistant row (`text-chunks`, `reasoning-chunks`,
/// `tool-call-chunks`). It occupies `eventCount` sequence positions starting
/// at `firstSeq` and is folded exactly once during v1-to-v2.
struct DeepSeekHarnessPackedRun {
    enum Kind: String {
        case text
        case reasoning
        case toolCall
    }

    let kind: Kind
    let firstSeq: Int
    let eventCount: Int
    let turn: Int
    let step: Int
    let lastSeq: Int
    let lastTime: Int
    let index: Int
    let gaps: [Int]
    let payload: [String]
    let callID: String?
    let name: String?
    let rawObject: [String: Any]

    var streamRecord: [String: Any] {
        switch kind {
        case .text:
            return ["type": "text-chunks", "time0": firstTime, "index": index,
                    "dt": gaps, "texts": payload]
        case .reasoning:
            return ["type": "reasoning-chunks", "time0": firstTime, "index": index,
                    "dt": gaps, "texts": payload]
        case .toolCall:
            var record: [String: Any] = ["type": "tool-call-chunks", "time0": firstTime,
                                         "index": index, "dt": gaps, "id": callID ?? "",
                                         "args": payload]
            if let name { record["name"] = name }
            return record
        }
    }

    private let firstTime: Int

    static func decode(_ object: [String: Any]) throws -> DeepSeekHarnessPackedRun {
        guard let type = DeepSeekHarnessJSON.string(object["type"]),
              ["text-chunks", "reasoning-chunks", "tool-call-chunks"].contains(type),
              Set(object.keys) == ["type", "seq0", "time0", "data"],
              let seq0 = DeepSeekHarnessJSON.count(object["seq0"]),
              let time0 = DeepSeekHarnessJSON.safeInt(object["time0"]),
              let data = DeepSeekHarnessJSON.dictionary(object["data"]) else {
            throw DeepSeekHarnessFormatError.invalidEnvelope
        }
        let isTool = type == "tool-call-chunks"
        let required = isTool
            ? ["turn", "step", "index", "id", "dt", "args"]
            : ["turn", "step", "index", "dt", "texts"]
        let optional = isTool ? ["name"] : []
        guard Set(data.keys) == Set(required + optional) else {
            throw DeepSeekHarnessFormatError.invalidPayload("packed \(type) row has unexpected members")
        }
        guard let turn = DeepSeekHarnessJSON.count(data["turn"]),
              let step = DeepSeekHarnessJSON.count(data["step"]),
              let index = DeepSeekHarnessJSON.count(data["index"]),
              let gaps = DeepSeekHarnessJSON.array(data["dt"]),
              let members = DeepSeekHarnessJSON.array(data[isTool ? "args" : "texts"]),
              !members.isEmpty, members.allSatisfy({ $0 is String }),
              gaps.count == members.count - 1,
              gaps.allSatisfy({ DeepSeekHarnessJSON.safeInt($0) != nil }) else {
            throw DeepSeekHarnessFormatError.invalidPayload("packed \(type) row has a malformed payload")
        }
        var lastTime = time0
        var decodedGaps: [Int] = []
        for gap in gaps {
            guard let step = DeepSeekHarnessJSON.safeInt(gap),
                  let next = DeepSeekHarnessJSON.safeAdd(lastTime, step) else {
                throw DeepSeekHarnessFormatError.invalidPayload("packed \(type) row has invalid member times")
            }
            decodedGaps.append(step)
            lastTime = next
        }
        var callID: String?
        var name: String?
        if isTool {
            guard let id = DeepSeekHarnessJSON.nonEmptyString(data["id"]) else {
                throw DeepSeekHarnessFormatError.invalidPayload("packed \(type) row id must be a non-empty string")
            }
            callID = id
            if let rawName = data["name"] {
                guard let text = DeepSeekHarnessJSON.string(rawName) else {
                    throw DeepSeekHarnessFormatError.invalidPayload("packed \(type) row name must be a string")
                }
                name = text
            }
        }
        let texts = members.map { $0 as! String }
        guard seq0 + texts.count - 1 <= DeepSeekHarnessJSON.maxSafeInteger else {
            throw DeepSeekHarnessFormatError.invalidPayload("packed \(type) row exceeds the sequence range")
        }
        return DeepSeekHarnessPackedRun(kind: isTool ? .toolCall : (type == "text-chunks" ? .text : .reasoning),
                                        firstSeq: seq0, eventCount: texts.count, turn: turn, step: step,
                                        lastSeq: seq0 + texts.count - 1, lastTime: lastTime,
                                        index: index, gaps: decodedGaps, payload: texts,
                                        callID: callID, name: name, rawObject: object,
                                        firstTime: time0)
    }

    private init(kind: Kind, firstSeq: Int, eventCount: Int, turn: Int, step: Int,
                 lastSeq: Int, lastTime: Int, index: Int, gaps: [Int], payload: [String],
                 callID: String?, name: String?, rawObject: [String: Any], firstTime: Int) {
        self.kind = kind
        self.firstSeq = firstSeq
        self.eventCount = eventCount
        self.turn = turn
        self.step = step
        self.lastSeq = lastSeq
        self.lastTime = lastTime
        self.index = index
        self.gaps = gaps
        self.payload = payload
        self.callID = callID
        self.name = name
        self.rawObject = rawObject
        self.firstTime = firstTime
    }
}

enum DeepSeekHarnessPhysicalRow {
    case event(DeepSeekHarnessEnvelope)
    case packed(DeepSeekHarnessPackedRun)
}

// MARK: - Vocabulary

/// Frozen event inventories ported from the pinned reference. The final v3
/// vocabulary is `knownEventTypes.ts`; earlier generations use the released
/// disposition inventories. Unknown required events fail closed; unknown
/// ignorable v3 events are retained as diagnostic-only normalized envelopes
/// so their type/sequence provenance survives without rendering.
enum DeepSeekHarnessVocabulary {
    static let packedTypes: Set<String> = ["text-chunks", "reasoning-chunks", "tool-call-chunks"]

    static let legacySourceTypes: Set<String> = ["steering/message", "request/header-delta", "mode/set",
                                                 "compact/start", "compact/summary", "compact/end", "compact/prune"]

    static let v0Events: Set<String> = [
        "agent-preset/selected", "agent/inbox/spliced", "approval/asked", "approval/decided",
        "approval/policy", "assistant/chunk", "assistant/message", "command/done", "command/run",
        "compaction/end", "compaction/prune", "compaction/start", "compaction/summary",
        "feedback/record", "goal/change", "hook/invoked", "hook/result", "llm/retry",
        "llm/retry-started", "model/selection", "permission/preset", "plan/mode",
        "request/context", "request/header", "sandbox/mode", "schedule/change",
        "session-log-deepseek/delivery-accepted", "session/end-seed", "session/title",
        "session/title-llm-request", "step/end", "step/start", "subagent/descriptor",
        "subagent/model-selection-policy", "team/member", "team/message/delivered",
        "team/message/queued", "team/task", "todo/write", "tool-workflow/agent-end",
        "tool-workflow/agent-start", "tool-workflow/run-end", "tool-workflow/run-start",
        "tool/call", "tool/code-dispatch", "tool/code-dispatch-start", "tool/result",
        "turn/end", "turn/start", "user/message", "web/deepseek-search-llm-request",
    ]

    /// Ported verbatim from staged `known-event-types.ts`.
    static let v3Known: Set<String> = [
        "agent-preset/selected", "agent/inbox/spliced", "approval/asked", "approval/decided",
        "approval/policy", "assistant/attempt", "assistant/message", "command/done", "command/run",
        "compaction/end", "compaction/prune", "compaction/start", "compaction/summary",
        "deliverables/presented", "feedback/message-delete", "feedback/message-put",
        "feedback/record", "goal/change", "hook/invoked", "hook/result", "image/offload",
        "llm/retry", "llm/retry-started", "model/selection", "permission/preset", "plan/mode",
        "request/context", "request/header", "sandbox/mode", "schedule/change",
        "session-log-deepseek/delivery-accepted", "session/end-seed", "session/title",
        "session/title-llm-request", "step/end", "step/start", "subagent/catalog",
        "subagent/descriptor", "subagent/model-selection-policy", "system/message",
        "team/member", "team/message/delivered", "team/message/queued", "team/task",
        "todo/write", "tool-workflow/agent-end", "tool-workflow/agent-start",
        "tool-workflow/run-end", "tool-workflow/run-start", "tool/call", "tool/ptc-dispatch",
        "tool/ptc-dispatch-start", "tool/result", "turn/end", "turn/start", "user/message",
        "web/deepseek-search-llm-request", "workspace/changes",
    ]

    static let surfaceV0: Set<String> = ["user/message", "assistant/message", "tool/result"]
    static let surfaceV3: Set<String> = ["system/message", "user/message", "assistant/message", "tool/result"]
    static let contentKinds: Set<String> = ["text", "reasoning", "image", "file", "tool-call", "tool-result"]
}

// MARK: - Presentation dispositions

/// V1 presentation disposition for each frozen first-party v3 event type.
///
/// Categories mirror the existing `DeepSeekHarnessSessionParser` behavior;
/// adding this table changes no rendering. User-message, system, assistant,
/// tool, request, turn, and seed entries describe emitted rows or metadata.
/// Diagnostic-attempt and intentionally-ignored entries describe admitted
/// but non-rendered events.
enum DeepSeekHarnessPresentationDisposition: String, Sendable, CaseIterable {
    case userMessage
    case systemMetadata
    case assistantRendering
    case diagnosticAttempt
    case toolCall
    case toolResult
    case requestHeader
    case requestContext
    case turnLifecycle
    case seedBoundary
    case intentionallyIgnored
}

/// Checked-in inventory with exactly one entry per `v3Known` name. Lookup is
/// an explicit dictionary fetch with no default: a known name without an
/// entry is a programming error and must fail closed in the parser.
///
/// Intentionally ignored first-party events are safe for v1 presentation
/// because they carry coordination or provenance state (approvals, hooks,
/// compaction, team, workflows, feedback, scheduling, dispatch) rather than
/// transcript content, and mapping unaudited shapes as tool activity would
/// risk double-counting or misattribution. They remain admitted and
/// strictly validated upstream (`validateV3` plus `assertV3EventPostMigration`),
/// so a malformed ignored payload still refuses the file; the parser simply
/// renders no row for a well-formed one. Step coordinates survive inside
/// neighbouring events' raw payloads, and DSH's own generated titles stay
/// out because the v1 title is always the first direct-human user text.
/// Unknown ignorable events stay diagnostic-only through the normalizer and
/// unknown required events still fail closed there.
enum DeepSeekHarnessPresentation {
    static let dispositions: [String: DeepSeekHarnessPresentationDisposition] = [
        "agent-preset/selected": .intentionallyIgnored,
        "agent/inbox/spliced": .intentionallyIgnored,
        "approval/asked": .intentionallyIgnored,
        "approval/decided": .intentionallyIgnored,
        "approval/policy": .intentionallyIgnored,
        "assistant/attempt": .diagnosticAttempt,
        "assistant/message": .assistantRendering,
        "command/done": .intentionallyIgnored,
        "command/run": .intentionallyIgnored,
        "compaction/end": .intentionallyIgnored,
        "compaction/prune": .intentionallyIgnored,
        "compaction/start": .intentionallyIgnored,
        "compaction/summary": .intentionallyIgnored,
        "deliverables/presented": .intentionallyIgnored,
        "feedback/message-delete": .intentionallyIgnored,
        "feedback/message-put": .intentionallyIgnored,
        "feedback/record": .intentionallyIgnored,
        "goal/change": .intentionallyIgnored,
        "hook/invoked": .intentionallyIgnored,
        "hook/result": .intentionallyIgnored,
        "image/offload": .intentionallyIgnored,
        "llm/retry": .intentionallyIgnored,
        "llm/retry-started": .intentionallyIgnored,
        "model/selection": .intentionallyIgnored,
        "permission/preset": .intentionallyIgnored,
        "plan/mode": .intentionallyIgnored,
        "request/context": .requestContext,
        "request/header": .requestHeader,
        "sandbox/mode": .intentionallyIgnored,
        "schedule/change": .intentionallyIgnored,
        "session-log-deepseek/delivery-accepted": .intentionallyIgnored,
        "session/end-seed": .seedBoundary,
        "session/title": .intentionallyIgnored,
        "session/title-llm-request": .intentionallyIgnored,
        "step/end": .intentionallyIgnored,
        "step/start": .intentionallyIgnored,
        "subagent/catalog": .intentionallyIgnored,
        "subagent/descriptor": .intentionallyIgnored,
        "subagent/model-selection-policy": .intentionallyIgnored,
        "system/message": .systemMetadata,
        "team/member": .intentionallyIgnored,
        "team/message/delivered": .intentionallyIgnored,
        "team/message/queued": .intentionallyIgnored,
        "team/task": .intentionallyIgnored,
        "todo/write": .intentionallyIgnored,
        "tool-workflow/agent-end": .intentionallyIgnored,
        "tool-workflow/agent-start": .intentionallyIgnored,
        "tool-workflow/run-end": .intentionallyIgnored,
        "tool-workflow/run-start": .intentionallyIgnored,
        "tool/call": .toolCall,
        "tool/ptc-dispatch": .intentionallyIgnored,
        "tool/ptc-dispatch-start": .intentionallyIgnored,
        "tool/result": .toolResult,
        "turn/end": .turnLifecycle,
        "turn/start": .turnLifecycle,
        "user/message": .userMessage,
        "web/deepseek-search-llm-request": .intentionallyIgnored,
        "workspace/changes": .intentionallyIgnored,
    ]

    /// Explicit lookup only. Known names classify solely through the table
    /// above; there is no default mapping. Returns nil for unknown types so
    /// callers preserve the existing normalizer contract (diagnostic-only
    /// ignorable passthrough, fail-closed required events upstream).
    static func disposition(for eventType: String) -> DeepSeekHarnessPresentationDisposition? {
        dispositions[eventType]
    }

    static var isComplete: Bool {
        dispositions.count == v3KnownCount
            && Set(dispositions.keys) == DeepSeekHarnessVocabulary.v3Known
    }

    private static let v3KnownCount = 58
}

enum DeepSeekHarnessFormatError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case invalidHeader
    case invalidEnvelope
    case invalidPayload(String)
    case invalidReference(String)
    case unsupportedMigration(String)
    case sequence(expected: Int, actual: Int)
    case unknownRequiredEvent(String)
    case tornLine(offset: Int)
    case invalidUTF8(offset: Int)
    case invalidJSON(offset: Int)
    case corruptFrame(frame: Int, offset: Int, reason: String)
    case incompleteFrame(frame: Int, offset: Int)
    case firstFrameHeaderViolation
    case encodingMismatch
    case legacyLayout(URL)
    case canonicalPathMismatch
    case ambiguousSession(String)
    case filesystemAccess(String)
    case staleAnchor
    case limitsExceeded(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "DeepSeek format v\(version) is unsupported; supported versions are v0 through v3."
        case .invalidHeader: return "DeepSeek session header is invalid."
        case .invalidEnvelope: return "DeepSeek event envelope is invalid."
        case .invalidPayload(let detail): return "DeepSeek event payload is invalid: \(detail)."
        case .invalidReference(let detail): return "DeepSeek event reference is invalid: \(detail)."
        case .unsupportedMigration(let detail): return "DeepSeek migration refuses this log: \(detail)."
        case .sequence(let expected, let actual): return "DeepSeek event sequence expected \(expected), got \(actual)."
        case .unknownRequiredEvent(let type): return "DeepSeek requires unsupported event \(type)."
        case .tornLine(let offset): return "DeepSeek has an incomplete final JSONL record at byte \(offset)."
        case .invalidUTF8(let offset): return "DeepSeek has invalid UTF-8 at byte \(offset)."
        case .invalidJSON(let offset): return "DeepSeek has invalid JSON at byte \(offset)."
        case .corruptFrame(let frame, let offset, let reason): return "DeepSeek Zstandard frame \(frame) is corrupt at byte \(offset): \(reason)."
        case .incompleteFrame(let frame, let offset): return "DeepSeek Zstandard frame \(frame) is incomplete at byte \(offset)."
        case .firstFrameHeaderViolation: return "DeepSeek first Zstandard frame must contain exactly one newline-terminated header record."
        case .encodingMismatch: return "DeepSeek session root mixes plain and Zstandard artifacts."
        case .legacyLayout(let url): return "DeepSeek legacy flat artifact is unsupported: \(url.lastPathComponent)."
        case .canonicalPathMismatch: return "DeepSeek artifact path does not match its header-derived identity."
        case .ambiguousSession(let id): return "DeepSeek session id is ambiguous across project directories: \(id)."
        case .filesystemAccess(let path): return "DeepSeek could not read session storage: \(path)."
        case .staleAnchor: return "DeepSeek artifact changed generation while it was being read."
        case .limitsExceeded(let value): return "DeepSeek read limit exceeded: \(value)."
        }
    }
}

struct DeepSeekHarnessParseResult {
    let header: DeepSeekHarnessHeader
    /// Physical rows in file order: standard envelopes plus released packed
    /// assistant runs (v0/v1 only). Migrations fold runs exactly once.
    let rows: [DeepSeekHarnessPhysicalRow]
    /// Inherited prefix length: `seedLength` for v0/v1, derived from the
    /// inherited `session/end-seed` marker for v2/v3.
    let inheritedEventCount: Int
    /// Unknown ignorable records retained for diagnostics without retaining
    /// their payload. Sequence makes repeated extension events actionable.
    let skippedIgnorableEvents: [DeepSeekHarnessIgnorableDiagnostic]
    let incompleteTurn: Bool

    var skippedIgnorableTypes: [String] { skippedIgnorableEvents.map(\.type) }

    init(header: DeepSeekHarnessHeader,
         rows: [DeepSeekHarnessPhysicalRow],
         inheritedEventCount: Int,
         skippedIgnorableEvents: [DeepSeekHarnessIgnorableDiagnostic],
         incompleteTurn: Bool) {
        self.header = header
        self.rows = rows
        self.inheritedEventCount = inheritedEventCount
        self.skippedIgnorableEvents = skippedIgnorableEvents
        self.incompleteTurn = incompleteTurn
    }

    /// Test/source compatibility initializer. Production reads retain real
    /// sequence values through `skippedIgnorableEvents`.
    init(header: DeepSeekHarnessHeader,
         rows: [DeepSeekHarnessPhysicalRow],
         inheritedEventCount: Int,
         skippedIgnorableTypes: [String],
         incompleteTurn: Bool) {
        self.init(header: header, rows: rows,
                  inheritedEventCount: inheritedEventCount,
                  skippedIgnorableEvents: skippedIgnorableTypes.map {
                    DeepSeekHarnessIgnorableDiagnostic(type: $0, sequence: -1)
                  },
                  incompleteTurn: incompleteTurn)
    }

    var envelopes: [DeepSeekHarnessEnvelope] {
        rows.compactMap {
            if case .event(let envelope) = $0 { return envelope }
            return nil
        }
    }
}

struct DeepSeekHarnessIgnorableDiagnostic: Equatable {
    let type: String
    let sequence: Int
}

struct DeepSeekHarnessSessionCandidate: Equatable {
    let id: String
    let projectDirectory: URL
    let sessionDirectory: URL
    let selectedURL: URL
    let generation: Int
    let compression: DeepSeekHarnessCompression
    let header: DeepSeekHarnessHeader
    let manifestRevision: String
    let siblings: [URL]
}

struct DeepSeekHarnessDiscoveryResult {
    let candidates: [DeepSeekHarnessSessionCandidate]
    let issues: [DeepSeekHarnessFormatError]
    let encoding: DeepSeekHarnessCompression?
}
