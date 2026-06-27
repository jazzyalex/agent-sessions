import Foundation
import CryptoKit

/// Parser for Antigravity CLI JSONL transcripts.
/// Layout: ~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl
enum AntigravityTranscriptParser {
    static func parse(at url: URL, forcedID: String?, includeEvents: Bool) -> Session? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }
        // Only claim JSONL that is actually an antigravity-cli transcript. Every
        // antigravity-cli record carries a top-level `step_index`; other JSONL
        // session formats (e.g. legacy Gemini CLI transcripts) do not, so we leave
        // them for their own parsers instead of mis-claiming them here.
        guard isAntigravityTranscript(lines) else { return nil }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let ctime = (attrs[.creationDate] as? Date) ?? mtime
        let sid = forcedID ?? conversationID(for: url) ?? sha256(path: url.path)

        let iso = ISO8601DateFormatter()
        var events: [SessionEvent] = []
        var firstUserText: String? = nil
        var model: String? = nil
        var lastToolName: String? = nil
        var firstDate: Date? = nil
        var lastDate: Date? = nil
        var count = 0

        for (idx, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            count += 1
            let ts = (obj["created_at"] as? String).flatMap { iso.date(from: $0) }
            if let ts { if firstDate == nil { firstDate = ts }; lastDate = ts }
            let content = obj["content"] as? String
            let raw = line

            switch type {
            case "USER_INPUT":
                let unwrapped = unwrapUserRequest(content ?? "")
                if firstUserText == nil { firstUserText = unwrapped }
                if model == nil { model = modelName(fromUserInput: content ?? "") }
                if includeEvents {
                    events.append(makeEvent(sid, eventID(idx), ts, .user, "user", unwrapped, nil, nil, nil, raw))
                }
            case "PLANNER_RESPONSE":
                if includeEvents {
                    // A PLANNER_RESPONSE may carry the model's actual answer in `content`
                    // and/or internal reasoning in `thinking`. Prefer the answer.
                    let thinking = obj["thinking"] as? String
                    let assistantText = (obj["content"] as? String) ?? thinking ?? ""
                    events.append(makeEvent(sid, eventID(idx), ts, .assistant, "assistant", assistantText, nil, nil, nil, raw))
                    if let calls = obj["tool_calls"] as? [[String: Any]] {
                        for (ci, call) in calls.enumerated() {
                            let name = call["name"] as? String
                            lastToolName = name
                            let input = (call["args"] as? [String: Any]).map {
                                (try? JSONSerialization.data(withJSONObject: $0)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            }
                            events.append(makeEvent(sid, "\(eventID(idx))-t\(ci)", ts, .tool_call, "assistant", nil, name, input, nil, raw))
                        }
                    }
                }
            case "RUN_COMMAND", "VIEW_FILE", "LIST_DIRECTORY":
                if includeEvents {
                    events.append(makeEvent(sid, eventID(idx), ts, .tool_result, "tool", nil, lastToolName, nil, content, raw))
                }
            default: // CHECKPOINT, CONVERSATION_HISTORY, unknown
                if includeEvents {
                    events.append(makeEvent(sid, eventID(idx), ts, .meta, "system", content, nil, nil, nil, raw))
                }
            }
        }

        guard count > 0 else { return nil }

        let title = firstUserText?.split(separator: "\n").first.map(String.init)
            ?? url.deletingLastPathComponent().lastPathComponent

        return Session(id: sid,
                       source: .antigravity,
                       startTime: firstDate ?? ctime,
                       endTime: lastDate ?? mtime,
                       model: model,
                       filePath: url.path,
                       fileSizeBytes: size >= 0 ? size : nil,
                       eventCount: count,
                       events: includeEvents ? events : [],
                       cwd: nil,
                       repoName: nil,
                       lightweightTitle: title)
    }

    /// Antigravity-cli transcripts tag every record with a top-level `step_index`
    /// alongside a string `type`. Require at least one such record so foreign JSONL
    /// formats are not mis-claimed as antigravity sessions.
    static func isAntigravityTranscript(_ lines: [String]) -> Bool {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if obj["step_index"] != nil, obj["type"] is String { return true }
        }
        return false
    }

    static func unwrapUserRequest(_ content: String) -> String {
        // Prefer the inside of <USER_REQUEST>…</USER_REQUEST>.
        if let r = content.range(of: "<USER_REQUEST>"),
           let e = content.range(of: "</USER_REQUEST>"),
           r.upperBound <= e.lowerBound {
            return String(content[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Otherwise drop any metadata blocks and return the remainder.
        var out = content
        for tag in ["<ADDITIONAL_METADATA>", "<USER_SETTINGS_CHANGE>"] {
            if let r = out.range(of: tag) { out = String(out[..<r.lowerBound]) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func modelName(fromUserInput content: String) -> String? {
        // USER_SETTINGS_CHANGE reports the active model as
        // "...`Model Selection` from <old> to <new>." — capture <new>, whether the
        // change is from None (initial selection) or from a prior model.
        guard let rx = try? NSRegularExpression(pattern: "Model Selection`?\\s+from\\s+.+?\\s+to\\s+(.+)") else { return nil }
        let ns = content as NSString
        guard let m = rx.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        var name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    static func conversationID(for url: URL) -> String? {
        // .../brain/<id>/.system_generated/logs/transcript.jsonl  → <id>
        let comps = url.pathComponents
        if let i = comps.firstIndex(of: "brain"), i + 1 < comps.count {
            return comps[i + 1]
        }
        // Otherwise derive <id> from the conversation folder that holds
        // .system_generated/logs/transcript.jsonl.
        if let i = comps.firstIndex(of: ".system_generated"), i > 0 {
            return comps[i - 1]
        }
        return nil
    }

    /// Zero-padded id stem for a line's primary event. Line events get this stem
    /// directly; tool-call events append a `-t<ci>` suffix so their ids never collide
    /// with a later line's stem (e.g. line 1's first tool call must not equal line 100).
    private static func eventID(_ idx: Int) -> String { String(format: "%04d", idx) }

    private static func makeEvent(_ sid: String, _ idSuffix: String, _ ts: Date?, _ kind: SessionEventKind,
                                  _ role: String, _ text: String?, _ tool: String?, _ input: String?,
                                  _ output: String?, _ raw: String) -> SessionEvent {
        SessionEvent(id: "\(sid)-\(idSuffix)", timestamp: ts, kind: kind, role: role,
                     text: text, toolName: tool, toolInput: input, toolOutput: output,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: raw)
    }

    private static func sha256(path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
}
