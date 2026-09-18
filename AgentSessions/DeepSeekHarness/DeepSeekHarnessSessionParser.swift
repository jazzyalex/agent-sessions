import Foundation

/// Maps normalized canonical v3 DSH events into Agent Sessions rows.
///
/// The input is the output of `DeepSeekHarnessHistoricalNormalizer.normalize`,
/// so every event below already uses the released v3 envelope and payload
/// vocabulary (pinned reference `packages/core/session/src/types.ts`,
/// `packages/llm/llm/src/message.ts`, `packages/llm/llm/src/types.ts`,
/// `packages/llm/llm/src/assistant-stream.ts`). In particular the parser reads
/// the actual nested shapes and never schematic top-level text fields:
///
/// - `user/message` data is `{id, role, content, source}`; only `content`
///   blocks of type `text` become message text.
/// - `assistant/message` data is `{turn, step, message, stream, usage?}` where
///   `message` is `{id, role, content, source}` and `stream` holds packed
///   `text-chunks` / `reasoning-chunks` / `tool-call-chunks` / raw `chunk`
///   records. The stream is provenance only: the final message content renders
///   exactly once from `message.content`, never once per stream record.
/// - `tool/call` data is `{turn, step, callId, name, arguments}`.
/// - `tool/result` data is `{turn, step, message, error?, meta?}` where
///   `message` carries exactly one `tool-result` block whose nested `content`
///   holds the rendered result blocks.
/// - `system/message` data is `{turn, step, message}` with a plugin source.
/// - `request/header` data is `{header: {config: {provider, model, ...}, ...},
///   reason, startsSeries?}`; the model comes from `header.config`, never from
///   a top-level field.
/// - `request/context` data is `{provider, model, ...}` route metadata.
///
/// Explicit event dispositions (plan Task 5 gate: nothing is silently
/// dropped; each arm below is covered by
/// `DeepSeekHarnessSessionParserTests`):
///
/// - `user/message` with `source.kind == "user"` → `.user` event and the only
///   title source. Any other source kind (plugin, agent-instructions,
///   team-message, goal, skill-*, coordinator, subagent-*, webhook,
///   agent-message, session-reference, model, tool) or a missing source →
///   `.meta` event with role `"user"`: injected context is preserved but can
///   never title the session, become the first-user preview, or inflate user
///   message counts.
/// - `system/message` → `.meta` marker with role `"system"` and no text. The
///   rendered system prompt is provenance, not transcript content: keeping it
///   out of event text keeps it out of search corpora and titles while the
///   bounded raw payload preserves the evidence.
/// - `assistant/message` → one `.assistant` event for joined text blocks (with
///   an embedded-stream fallback only when content carries no text), one
///   `.meta` event with role `"reasoning"` for joined reasoning blocks, and
///   one `.meta` attachment event per top-level image/file block. Tool-call
///   blocks are deduplicated with `tool/call` events (see below), never
///   emitted as text.
/// - `assistant/attempt` → diagnostic only. The normalizer already flags it and
///   this parser skips it, so failed/retried attempts never contribute
///   transcript text, titles, counts, or model labels.
/// - assistant `tool-call` block + `tool/call` event with the same id → exactly
///   one `.tool_call` event keyed by call id. The block owns model-request
///   provenance, the log event owns recorded-start metadata; when both exist
///   the merged raw payload retains both. Unmatched blocks and unmatched log
///   events are each preserved explicitly, never paired by invention.
/// - `tool/result` → one `.tool_result` event per envelope, paired to its call
///   by `toolCallId`; the tool name is backfilled from the matching call
///   record when the result itself carries no name. Nested image/file blocks
///   render inline as placeholders inside the result text rather than as
///   separate events, so a result is represented exactly once.
/// - `request/header` → list-level model / provider / reasoning-effort
///   metadata only, never an event. The latest valid header wins; the latest
///   assistant-message model source is the fallback.
/// - `request/context` → `.meta` marker with role `"request-context"` and no
///   text (injected context stays out of search text).
/// - `turn/start` / `turn/end` → `.meta` lifecycle markers (`"Turn N
///   started"` / `"Turn N ended: <kind>"`) and duration inputs.
/// - `step/start` / `step/end` → intentionally ignored; step coordinates are
///   preserved in every neighbouring event's raw payload.
/// - `session/end-seed` → `.meta` seed-boundary marker.
/// - `session/title` / `session/title-llm-request` → intentionally ignored;
///   the title is always the first direct-human user text per the source
///   contract, never DSH's own generated title.
/// - `tool/ptc-dispatch` / `tool/ptc-dispatch-start` and every other known v3
///   vocabulary type → intentionally ignored in v1. Their payload shapes are
///   not audited from the staged reference, so mapping them as tool activity
///   would risk double-counting or misattribution; they remain countable in a
///   future pass once their shapes are pinned.
/// - Unknown ignorable events reach this parser marked diagnostic-only and are
///   not rendered; unknown required events fail normalization, so this parser
///   returns nil and the indexer preserves the last healthy row.
///
/// Attachments render only as metadata placeholders (`[image: name,
/// mediatype, bytes]`, `[file: name, bytes]`) built from source-provided
/// display fields. Attachment ids/paths are never rendered, and no path is
/// ever opened: there is no filesystem or network dereference anywhere below.
///
/// Relationships follow durable header semantics only: `origin == "subagent"`
/// plus a parent id nests beneath the parent with the normalized preset
/// (`code` → `ptc` via `normalizedHeader`) as subtype. A parent id without
/// subagent origin is a seeded fork and stays a root; fork provenance lives in
/// the raw header metadata, never in `parentSessionID`, because Agent Sessions
/// interprets every such parent as a subagent.
///
/// Lightweight (`parseFile`) and full (`parseFileFull`) parses share one
/// projection: lightweight drops the events but keeps identical titles,
/// counts, model labels, and timestamps. Any read or normalization failure
/// returns nil. This source is not resumable; no resume behavior is defined
/// here.
enum DeepSeekHarnessSessionParser {
    static func parseFile(at url: URL) -> Session? {
        parse(url: url, includeEvents: false)
    }

    static func parseFileFull(at url: URL) -> Session? {
        parse(url: url, includeEvents: true)
    }

    // MARK: - Projection

    private struct ToolCallInfo {
        var name: String?
        var arguments: String?
        var block: [String: Any]?
        var blockMessageID: String?
        var event: [String: Any]?
        var eventTime: Date?
    }

    private struct Projection {
        let header: DeepSeekHarnessHeader
        let startDate: Date
        let lastDate: Date
        let model: String?
        let reasoningEffort: String?
        let lightweightTitle: String?
        let toolCallCount: Int
        let nonMetaCount: Int
        let events: [SessionEvent]
    }

    private static func parse(url: URL, includeEvents: Bool) -> Session? {
        guard let parsedFilename = DeepSeekHarnessDiscovery.parseGenerationFilename(url.lastPathComponent) else { return nil }
        guard let result = try? DeepSeekHarnessArtifactReader.read(url: url, compression: parsedFilename.compression),
              let normalized = try? DeepSeekHarnessHistoricalNormalizer.normalize(result),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }

        let header = DeepSeekHarnessHistoricalNormalizer.normalizedHeader(result.header)
        let projection = project(header: header, events: normalized, incompleteTurn: result.incompleteTurn)
        let size = (attrs[.size] as? NSNumber)?.intValue
        let modificationDate = attrs[.modificationDate] as? Date
        let endDate = [projection.startDate, projection.lastDate, modificationDate].compactMap { $0 }.max()

        let isSubagent = header.origin == "subagent" && header.parentSessionID != nil
        return Session(id: header.id,
                       source: .deepseekHarness,
                       startTime: projection.startDate,
                       endTime: endDate,
                       model: projection.model,
                       filePath: url.path,
                       fileSizeBytes: size,
                       eventCount: projection.nonMetaCount,
                       events: includeEvents ? projection.events : [],
                       cwd: header.cwd,
                       repoName: header.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: projection.lightweightTitle,
                       lightweightCommands: projection.toolCallCount > 0 ? projection.toolCallCount : nil,
                       parentSessionID: isSubagent ? header.parentSessionID : nil,
                       subagentType: isSubagent ? header.agentPreset : nil,
                       relationshipKind: isSubagent ? .subagent : .root,
                       surface: isSubagent ? .subagent : .unknown)
    }

    private static func project(header: DeepSeekHarnessHeader,
                                events: [DeepSeekHarnessNormalizedEvent],
                                incompleteTurn: Bool) -> Projection {
        let startDate = Date(timeIntervalSince1970: TimeInterval(header.createdAtMilliseconds) / 1_000)
        var lastDate = startDate
        var model: String?
        var reasoningEffort: String?
        var fallbackAssistantModel: String?
        var firstDirectUserText: String?

        // Phase A: collect tool-call records from every content block and every
        // log event so Phase B can emit exactly one invocation per call id
        // regardless of which representation comes first in the log.
        var callsByID: [String: ToolCallInfo] = [:]
        func recordCall(id: String, mutate: (inout ToolCallInfo) -> Void) {
            if callsByID[id] == nil { callsByID[id] = ToolCallInfo() }
            mutate(&callsByID[id]!)
        }

        for item in events where !item.diagnosticOnly {
            let data = item.data
            switch item.canonicalType {
            case "assistant/message":
                if let message = data["message"] as? [String: Any],
                   let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks {
                        guard (block["type"] as? String) == "tool-call",
                              let id = nonEmptyString(block["id"]) else { continue }
                        recordCall(id: id) { info in
                            if info.block == nil {
                                info.block = block
                                info.blockMessageID = message["id"] as? String
                            }
                            if info.name == nil { info.name = nonEmptyString(block["name"]) }
                            if info.arguments == nil { info.arguments = argumentsString(block["arguments"]) }
                        }
                    }
                }
            case "tool/call":
                if let id = nonEmptyString(data["callId"]) {
                    recordCall(id: id) { info in
                        if info.event == nil {
                            info.event = item.envelope.rawObject
                            info.eventTime = eventDate(milliseconds: item.envelope.timeMilliseconds)
                        }
                        if let name = nonEmptyString(data["name"]) { info.name = name }
                        if let args = argumentsString(data["arguments"]) { info.arguments = args }
                    }
                }
            default:
                break
            }
        }

        // Phase B: emit in log order.
        var rows: [SessionEvent] = []
        var emittedCallIDs = Set<String>()
        let deferredBlockIDs = Set(callsByID.filter { $0.value.event != nil }.map(\.key))

        for item in events where !item.diagnosticOnly {
            let envelope = item.envelope
            let timestamp = eventDate(milliseconds: envelope.timeMilliseconds)
            if let timestamp { lastDate = max(lastDate, timestamp) }
            let data = item.data
            switch item.canonicalType {
            case "user/message":
                emitUserMessage(data: data, sequence: envelope.sequence, timestamp: timestamp,
                                raw: boundedRaw(envelope.rawObject), rows: &rows,
                                firstDirectUserText: &firstDirectUserText)
            case "system/message":
                rows.append(makeEvent(id: "dsh-\(envelope.sequence)-system", timestamp: timestamp,
                                      kind: .meta, role: "system", text: nil,
                                      raw: boundedRaw(envelope.rawObject)))
            case "assistant/message":
                emitAssistantMessage(data: data, sequence: envelope.sequence, timestamp: timestamp,
                                     raw: boundedRaw(envelope.rawObject), rows: &rows,
                                     deferredBlockIDs: deferredBlockIDs, emittedCallIDs: &emittedCallIDs,
                                     callsByID: callsByID)
                if fallbackAssistantModel == nil,
                   let message = data["message"] as? [String: Any],
                   let source = message["source"] as? [String: Any],
                   (source["kind"] as? String) == "model" {
                    fallbackAssistantModel = nonEmptyString(source["model"])
                }
            case "tool/call":
                if let id = nonEmptyString(data["callId"]), !emittedCallIDs.contains(id),
                   let info = callsByID[id] {
                    rows.append(toolCallEvent(callID: id, info: info, sequence: envelope.sequence,
                                              timestamp: timestamp))
                    emittedCallIDs.insert(id)
                } else if nonEmptyString(data["callId"]) == nil {
                    // Malformed call record with no correlation id: preserve
                    // the evidence explicitly rather than dropping it.
                    rows.append(makeEvent(id: "dsh-\(envelope.sequence)-call", timestamp: timestamp,
                                          kind: .tool_call, role: "assistant", text: nil,
                                          toolName: nonEmptyString(data["name"]),
                                          toolInput: capped(argumentsString(data["arguments"])),
                                          raw: boundedRaw(envelope.rawObject)))
                }
            case "tool/result":
                emitToolResult(data: data, sequence: envelope.sequence, timestamp: timestamp,
                               raw: boundedRaw(envelope.rawObject), rows: &rows, callsByID: callsByID)
            case "request/header":
                if let config = (data["header"] as? [String: Any])?["config"] as? [String: Any] {
                    if let name = nonEmptyString(config["model"]) { model = name }
                    if let effort = nonEmptyString(config["reasoningEffort"]) { reasoningEffort = effort }
                }
            case "request/context":
                rows.append(makeEvent(id: "dsh-\(envelope.sequence)-context", timestamp: timestamp,
                                      kind: .meta, role: "request-context", text: nil,
                                      raw: boundedRaw(envelope.rawObject)))
            case "turn/start":
                if let turn = data["turn"] as? Int {
                    rows.append(makeEvent(id: "dsh-\(envelope.sequence)-turn", timestamp: timestamp,
                                          kind: .meta, role: "turn", text: "Turn \(turn) started",
                                          raw: boundedRaw(envelope.rawObject)))
                }
            case "turn/end":
                if let turn = data["turn"] as? Int {
                    let kind = (data["reason"] as? [String: Any])?["kind"] as? String ?? "ended"
                    rows.append(makeEvent(id: "dsh-\(envelope.sequence)-turn", timestamp: timestamp,
                                          kind: .meta, role: "turn", text: "Turn \(turn) ended: \(kind)",
                                          raw: boundedRaw(envelope.rawObject)))
                }
            case "session/end-seed":
                rows.append(makeEvent(id: "dsh-\(envelope.sequence)-seed", timestamp: timestamp,
                                      kind: .meta, role: "seed", text: "Seed boundary",
                                      raw: boundedRaw(envelope.rawObject)))
            default:
                // step/start, step/end, session/title*, tool/ptc-dispatch* and
                // every other known v3 type: intentionally ignored per the
                // disposition table above. Unknown ignorable events are
                // diagnostic-only and filtered before this switch; unknown
                // required events fail normalization.
                continue
            }
        }

        if incompleteTurn {
            rows.append(makeEvent(id: "dsh-interrupted-turn", timestamp: lastDate,
                                  kind: .meta, role: "system", text: "Interrupted turn",
                                  raw: "{}"))
        }

        let title = firstDirectHumanTitle(firstDirectUserText) ?? fallbackTitle(cwd: header.cwd, createdAt: header.createdAtMilliseconds)
        let nonMetaCount = rows.filter { $0.kind != .meta }.count
        let toolCallCount = rows.filter { $0.kind == .tool_call }.count
        return Projection(header: header, startDate: startDate, lastDate: lastDate,
                          model: model ?? fallbackAssistantModel, reasoningEffort: reasoningEffort,
                          lightweightTitle: title, toolCallCount: toolCallCount,
                          nonMetaCount: nonMetaCount, events: rows)
    }

    // MARK: - Message emitters

    private static func emitUserMessage(data: [String: Any], sequence: Int, timestamp: Date?,
                                        raw: String, rows: inout [SessionEvent],
                                        firstDirectUserText: inout String?) {
        let source = data["source"] as? [String: Any]
        let isDirectHuman = (source?["kind"] as? String) == "user"
        let blocks = data["content"] as? [[String: Any]] ?? []
        let text = capped(joinTextBlocks(blocks))
        if isDirectHuman, firstDirectUserText == nil, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstDirectUserText = text
        }
        rows.append(makeEvent(id: "dsh-\(sequence)-user", timestamp: timestamp,
                              kind: isDirectHuman ? .user : .meta, role: "user", text: text,
                              messageID: data["id"] as? String, raw: raw))
        emitAttachmentPlaceholders(blocks: blocks, sequence: sequence, timestamp: timestamp,
                                   messageID: data["id"] as? String, rows: &rows)
    }

    private static func emitAssistantMessage(data: [String: Any], sequence: Int, timestamp: Date?,
                                             raw: String, rows: inout [SessionEvent],
                                             deferredBlockIDs: Set<String>,
                                             emittedCallIDs: inout Set<String>,
                                             callsByID: [String: ToolCallInfo]) {
        guard let message = data["message"] as? [String: Any] else { return }
        let blocks = message["content"] as? [[String: Any]] ?? []
        var text = joinTextBlocks(blocks)
        if text == nil, let stream = data["stream"] as? [[String: Any]] {
            // Content carries no text (e.g. a historical fold that preserved
            // only the embedded stream): fall back to the stream's text
            // fragments. Still exactly one rendering; never both.
            text = joinStreamText(stream)
        }
        if let text = capped(text), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(makeEvent(id: "dsh-\(sequence)-assistant", timestamp: timestamp,
                                  kind: .assistant, role: "assistant", text: text,
                                  messageID: message["id"] as? String, raw: raw))
        }
        let reasoning = capped(joinReasoningBlocks(blocks))
        if let reasoning = reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(makeEvent(id: "dsh-\(sequence)-reasoning", timestamp: timestamp,
                                  kind: .meta, role: "reasoning", text: reasoning,
                                  messageID: message["id"] as? String, raw: raw))
        }
        emitAttachmentPlaceholders(blocks: blocks, sequence: sequence, timestamp: timestamp,
                                   messageID: message["id"] as? String, rows: &rows)
        // Tool-call blocks whose invocation never appears as a log event are
        // preserved here; blocks paired with a `tool/call` event are emitted
        // at the event position with both provenances retained.
        for block in blocks {
            guard (block["type"] as? String) == "tool-call",
                  let id = nonEmptyString(block["id"]),
                  !deferredBlockIDs.contains(id), !emittedCallIDs.contains(id),
                  let info = callsByID[id] else { continue }
            rows.append(toolCallEvent(callID: id, info: info, sequence: sequence, timestamp: timestamp))
            emittedCallIDs.insert(id)
        }
    }

    private static func emitToolResult(data: [String: Any], sequence: Int, timestamp: Date?,
                                       raw: String, rows: inout [SessionEvent],
                                       callsByID: [String: ToolCallInfo]) {
        guard let message = data["message"] as? [String: Any] else {
            // Malformed result with no message envelope: preserve explicitly.
            rows.append(makeEvent(id: "dsh-\(sequence)-result", timestamp: timestamp,
                                  kind: .tool_result, role: "tool", text: nil, raw: raw))
            return
        }
        let callID = (message["source"] as? [String: Any])?["callId"] as? String
            ?? firstToolResultBlock(message["content"])?.toolCallID
        let nested = nestedResultBlocks(message["content"])
        // Nested attachments stay inline in the rendered result text (see
        // joinResultText); only top-level message attachments get their own
        // marker events, so a result is never represented twice.
        let output = capped(joinResultText(nested))
        rows.append(makeEvent(id: "dsh-\(sequence)-result", timestamp: timestamp,
                              kind: .tool_result, role: "tool", text: nil,
                              toolName: callID.flatMap { callsByID[$0]?.name },
                              toolOutput: output, messageID: callID ?? (message["id"] as? String),
                              raw: raw))
    }

    private static func toolCallEvent(callID: String, info: ToolCallInfo, sequence: Int,
                                      timestamp: Date?) -> SessionEvent {
        var provenance: [String: Any] = [:]
        if let block = info.block { provenance["block"] = block }
        if let event = info.event { provenance["event"] = event }
        let raw = provenance.isEmpty ? "{}" : boundedRaw(provenance)
        return makeEvent(id: "dsh-call-\(callID)", timestamp: timestamp ?? info.eventTime,
                         kind: .tool_call, role: "assistant", text: nil,
                         toolName: info.name, toolInput: info.arguments.flatMap { capped($0) },
                         messageID: callID, parentID: info.blockMessageID, raw: raw)
    }

    private static func emitAttachmentPlaceholders(blocks: [[String: Any]], sequence: Int,
                                                   timestamp: Date?, messageID: String?,
                                                   rows: inout [SessionEvent]) {
        var index = 0
        for block in blocks {
            guard let placeholder = attachmentPlaceholder(block) else { continue }
            rows.append(makeEvent(id: "dsh-\(sequence)-attachment-\(index)", timestamp: timestamp,
                                  kind: .meta, role: "attachment", text: placeholder,
                                  messageID: messageID, raw: "{}"))
            index += 1
        }
    }

    /// Safe display placeholder built only from source-provided display
    /// metadata. Attachment ids and paths are never rendered, and nothing is
    /// dereferenced: there is no filesystem or network access here.
    private static func attachmentPlaceholder(_ block: [String: Any]) -> String? {
        guard let attachment = block["attachment"] as? [String: Any] else { return nil }
        switch block["type"] as? String {
        case "image":
            var parts: [String] = []
            if let name = nonEmptyString(attachment["name"]) { parts.append(name) }
            if let media = nonEmptyString(attachment["mediaType"]) { parts.append(media) }
            if let bytes = attachment["bytes"] as? Int { parts.append("\(bytes) bytes") }
            else if let bytes = (attachment["bytes"] as? NSNumber)?.intValue { parts.append("\(bytes) bytes") }
            return "[image" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")) + "]"
        case "file":
            var parts: [String] = []
            if let name = nonEmptyString(attachment["name"]) { parts.append(name) }
            if let bytes = attachment["bytes"] as? Int { parts.append("\(bytes) bytes") }
            else if let bytes = (attachment["bytes"] as? NSNumber)?.intValue { parts.append("\(bytes) bytes") }
            return "[file" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")) + "]"
        default:
            return nil
        }
    }

    // MARK: - Content helpers

    private static func joinTextBlocks(_ blocks: [[String: Any]]) -> String? {
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text",
                  let text = block["text"] as? String, !text.isEmpty else { return nil }
            return text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private static func joinReasoningBlocks(_ blocks: [[String: Any]]) -> String? {
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "reasoning",
                  let text = block["text"] as? String, !text.isEmpty else { return nil }
            return text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    /// Fallback text from an embedded assistant stream: packed `text-chunks`
    /// members plus raw `text-delta` chunks, in record order. Reasoning and
    /// tool-call fragments never contribute.
    private static func joinStreamText(_ stream: [[String: Any]]) -> String? {
        var parts: [String] = []
        for record in stream {
            switch record["type"] as? String {
            case "text-chunks":
                if let texts = record["texts"] as? [String] {
                    let joined = texts.joined()
                    if !joined.isEmpty { parts.append(joined) }
                }
            case "chunk":
                if let chunk = record["chunk"] as? [String: Any],
                   (chunk["type"] as? String) == "text-delta",
                   let text = chunk["text"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            default:
                continue
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined()
    }

    private struct ToolResultRef {
        let toolCallID: String?
    }

    private static func firstToolResultBlock(_ content: Any?) -> ToolResultRef? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks where (block["type"] as? String) == "tool-result" {
            return ToolResultRef(toolCallID: block["toolCallId"] as? String)
        }
        return nil
    }

    /// Nested result content flattened one level (recursing into nested
    /// `tool-result` blocks with a depth cap); attachment blocks are returned
    /// alongside text so callers can placeholder them separately.
    private static func nestedResultBlocks(_ content: Any?) -> [[String: Any]] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        var out: [[String: Any]] = []
        var stack = blocks.map { ($0, 0) }
        while let (block, depth) = stack.popLast() {
            if (block["type"] as? String) == "tool-result", depth < 4,
               let inner = block["content"] as? [[String: Any]] {
                stack.append(contentsOf: inner.map { ($0, depth + 1) })
                continue
            }
            out.append(block)
        }
        return out.reversed()
    }

    private static func joinResultText(_ blocks: [[String: Any]]) -> String? {
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text", "reasoning":
                if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
            case "image", "file":
                if let placeholder = attachmentPlaceholder(block) { parts.append(placeholder) }
            default:
                continue
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    // MARK: - Titles

    private static func firstDirectHumanTitle(_ text: String?) -> String? {
        guard let candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else { return nil }
        return candidate
    }

    /// Deterministic fallback from the project display label and creation
    /// time. Never attachment data, never a raw prompt excerpt owned by
    /// another producer.
    private static func fallbackTitle(cwd: String?, createdAt: Int64) -> String {
        let label: String
        if let cwd, !cwd.isEmpty {
            let base = URL(fileURLWithPath: cwd).lastPathComponent
            label = base.isEmpty ? "DSH session" : base
        } else {
            label = "DSH session"
        }
        return "\(label) · \(utcDayMinute(ms: createdAt))"
    }

    private static func utcDayMinute(ms: Int64) -> String {
        // Built per call: parsing runs off the main queue and DateFormatter
        // is not thread-safe, while this fallback runs at most once per file.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1_000))
    }

    // MARK: - Small value helpers

    private static let renderedTextLimit = 32_768
    private static let rawJSONLimitBytes = 8_192

    private static func eventDate(milliseconds: Int64) -> Date? {
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func argumentsString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Caps pathological payloads before UI construction, mirroring the
    /// existing per-parser convention.
    private static func capped(_ text: String?) -> String? {
        guard let text else { return nil }
        guard text.count > renderedTextLimit else { return text }
        return String(text.prefix(renderedTextLimit)) + "\n…[truncated \(text.count - renderedTextLimit) chars]"
    }

    /// Bounded raw payload for inspection. Secret redaction for indexed text
    /// is the existing search pipeline's job (`SessionSearchTextBuilder`);
    /// rawJSON itself is never indexed.
    private static func boundedRaw(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        guard data.count > rawJSONLimitBytes else { return string }
        return String(string.prefix(rawJSONLimitBytes)) + "…[truncated \(data.count) bytes]"
    }

    private static func makeEvent(id: String, timestamp: Date?, kind: SessionEventKind, role: String?,
                                  text: String?, toolName: String? = nil, toolInput: String? = nil,
                                  toolOutput: String? = nil, messageID: String? = nil,
                                  parentID: String? = nil, raw: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: timestamp, kind: kind, role: role, text: text,
                     toolName: toolName, toolInput: toolInput, toolOutput: toolOutput,
                     messageID: messageID, parentID: parentID, isDelta: false, rawJSON: raw)
    }
}
