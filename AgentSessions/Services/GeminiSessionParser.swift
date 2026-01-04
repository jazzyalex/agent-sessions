import Foundation
import CryptoKit

/// Minimal parser for Gemini session JSON (preview-only for indexing)
/// Shape observed: {
///   lastUpdated, messages: [...], projectHash, sessionId, startTime
/// }
/// Fallbacks handled: root array, or object.history
final class GeminiSessionParser {

    private static let previewCountScanLimit = 2_000

    /// Preview-only parse for list indexing. Builds a lightweight Session with empty events
    /// and a derived title from the first user message.
    static func parseFile(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        guard let data = try? Data(contentsOf: url),
              let any = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let (items, meta) = extractItemsAndMeta(from: any)
        let folderHash = projectHash(from: url)
        let count = previewEventCount(from: items)

        // Title: first meaningful user line (from preview logic similar to Session.title expectations)
        var title: String? = nil
        if let arr = items {
            title = firstUserText(from: arr)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Lightweight cwd extraction (bounded scan to keep preview fast)
        var cwd: String? = nil
        var cwdLockedByResolver = false
        // Resolver-first
        if let hash = folderHash, let mapped = GeminiHashResolver.shared.resolve(hash), let v = validateCwd(mapped) { cwd = v; cwdLockedByResolver = true }
        // Heuristics only if not locked; require hash match when folderHash present
        if !cwdLockedByResolver, let arr = items {
            if let cand = extractCwd(from: arr, limit: 20), let norm = validateCwd(cand) {
                if let hash = folderHash {
                    if sha256(path: normalizePath(norm)) == hash { cwd = norm }
                } else {
                    cwd = norm
                }
            }
        }
        // As final attempt, check resolver again (in case it was seeded mid-parse)
        if !cwdLockedByResolver, cwd == nil, let hash = folderHash, let mapped = GeminiHashResolver.shared.resolve(hash) { cwd = validateCwd(mapped) }

        // start/end times from meta or from items timestamps
        var tmin: Date? = decodeDate(meta.startTime) ?? decodeDate(meta.firstTS)
        var tmax: Date? = decodeDate(meta.lastUpdated) ?? decodeDate(meta.lastTS) ?? tmin
        if tmin == nil { tmin = (attrs[.creationDate] as? Date) ?? mtime }
        if tmax == nil { tmax = mtime }

        // Use per-file stable ID for UI list consistency
        let sid = forcedID ?? sha256(path: url.path)
        return Session(id: sid,
                       source: .gemini,
                       startTime: tmin,
                       endTime: tmax,
                       model: meta.model,
                       filePath: url.path,
                       fileSizeBytes: size >= 0 ? size : nil,
                       eventCount: max(0, count),
                       events: [],
                       cwd: cwd,
                       repoName: nil,
                       lightweightTitle: title)
    }

    // Full parse that normalizes Gemini JSON to Session + SessionEvent[]
    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let sid = forcedID ?? sha256(path: url.path)

        guard let data = try? Data(contentsOf: url),
              let any = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let (items, meta) = extractItemsAndMeta(from: any)
        let folderHash = projectHash(from: url)

        var events: [SessionEvent] = []
        var model = meta.model
        var tmin: Date? = decodeDate(meta.startTime) ?? decodeDate(meta.firstTS)
        var tmax: Date? = decodeDate(meta.lastUpdated) ?? decodeDate(meta.lastTS) ?? tmin
        var cwd: String? = nil
        var cwdLockedByResolver = false
        // Resolver-first
        if let hash = folderHash, let mapped = GeminiHashResolver.shared.resolve(hash), let v = validateCwd(mapped) { cwd = v; cwdLockedByResolver = true }

        if let arr = items {
            events.reserveCapacity(arr.count)
            var i = 0
            for anyItem in arr {
                i += 1
                guard let obj = anyItem as? [String: Any] else { continue }

                if let tsAny = timestampOf(item: obj), let ts = decodeDate(tsAny) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }
                if model == nil, let m = obj["model"] as? String, !m.isEmpty { model = m }

                let typeStr = (obj["type"] as? String) ?? (obj["role"] as? String)
                let lowerType = typeStr?.lowercased()

                let roleNorm: String? = {
                    guard let t = lowerType else { return nil }
                    if t == "user" || t == "human" { return "user" }
                    if t == "gemini" || t == "model" || t == "assistant" { return "assistant" }
                    if t == "system" { return "system" }
                    if t == "tool" || t == "tool_result" || t == "tool_use" || t == "tool_call" { return "tool" }
                    return t
                }()

                var kind: SessionEventKind = {
                    if let t = lowerType {
                        switch t {
                        case "tool_use", "tool_call": return .tool_call
                        case "tool_result": return .tool_result
                        case "error": return .error
                        case "system": return .meta
                        case "info": return .meta
                        case "user", "human": return .user
                        case "gemini", "model", "assistant": return .assistant
                        default: break
                        }
                    }
                    if let r = roleNorm {
                        switch r {
                        case "user": return .user
                        case "assistant": return .assistant
                        case "tool": return .tool_result
                        case "system": return .meta
                        default: break
                        }
                    }
                    return .assistant
                }()

                let text = contentString(of: obj)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let toolCalls = toolCallObjects(from: obj)
                // Forward-compatibility: unknown message types without displayable content become meta.
                if kind == .assistant {
                    let isExplicitAssistant = (lowerType == "gemini" || lowerType == "model" || lowerType == "assistant" || roleNorm == "assistant")
                    let hasText = (text?.isEmpty == false)
                    if !isExplicitAssistant && !hasText && toolCalls.isEmpty {
                        kind = .meta
                    }
                }

                // Opportunistic cwd extraction while walking items (cheap checks)
                if !cwdLockedByResolver, cwd == nil {
                    if let c = directCwd(from: obj) ?? cwdFromText(text), let norm = validateCwd(c) {
                        if let hash = folderHash {
                            if sha256(path: normalizePath(norm)) == hash { cwd = norm }
                        } else {
                            cwd = norm
                        }
                    }
                }

                var toolName: String? = nil
                var toolInput: String? = nil
                var toolOutput: String? = nil
                if lowerType == "tool_use" || lowerType == "tool_call" {
                    toolName = (obj["name"] as? String) ?? (obj["tool"] as? String)
                    if let input = obj["input"] { toolInput = stringifyJSON(input) }
                } else if lowerType == "tool_result" {
                    if let output = obj["output"] { toolOutput = stringifyJSON(output) }
                }

                let ts = decodeDate(timestampOf(item: obj) ?? obj["ts"]) // fallback
                let rawData = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
                let rawJSON = rawData.base64EncodedString()

                let hasMeaningfulText = (text?.isEmpty == false)
                let shouldEmitPrimaryEvent = !(kind == .assistant && !hasMeaningfulText && !toolCalls.isEmpty)
                if shouldEmitPrimaryEvent {
                    let event = SessionEvent(
                        id: sid + String(format: "-%04d", i),
                        timestamp: ts,
                        kind: kind,
                        role: roleNorm,
                        text: text,
                        toolName: toolName,
                        toolInput: toolInput,
                        toolOutput: toolOutput,
                        messageID: (obj["id"] as? String) ?? (obj["uuid"] as? String),
                        parentID: obj["parentId"] as? String,
                        isDelta: false,
                        rawJSON: rawJSON
                    )
                    events.append(event)
                }

                if !toolCalls.isEmpty {
                    var tci = 0
                    for tc in toolCalls {
                        tci += 1
                        let suffix = String(format: "-%04d-t%02d", i, tci)
                        if let call = toolCallEvent(from: tc, baseID: sid + suffix) {
                            events.append(call)
                        }
                        if let result = toolResultEvent(from: tc, baseID: sid + suffix + "-r") {
                            events.append(result)
                        }
                    }
                }
            }
        }

        // If still no cwd, try resolver again
        if !cwdLockedByResolver, cwd == nil, let hash = folderHash, let mapped = GeminiHashResolver.shared.resolve(hash) { cwd = validateCwd(mapped) }

        let nonMetaCount = events.filter { $0.kind != .meta }.count
        return Session(id: sid,
                       source: .gemini,
                       startTime: tmin,
                       endTime: tmax ?? tmin,
                       model: model,
                       filePath: url.path,
                       fileSizeBytes: size >= 0 ? size : nil,
                       eventCount: nonMetaCount,
                       events: events,
                       cwd: cwd,
                       repoName: nil,
                       lightweightTitle: nil)
    }

    // MARK: - Helpers

    private struct Meta {
        var model: String? = nil
        var startTime: Any? = nil
        var lastUpdated: Any? = nil
        var firstTS: Any? = nil
        var lastTS: Any? = nil
        var sessionID: String? = nil
    }

    private static func extractItemsAndMeta(from any: Any) -> ([Any]?, Meta) {
        var meta = Meta()
        if let arr = any as? [Any] {
            // Flat array of messages
            meta.firstTS = timestampOf(item: arr.first)
            meta.lastTS = timestampOf(item: arr.last)
            return (arr, meta)
        }
        if let dict = any as? [String: Any] {
            // Object with messages/history and metadata
            let messages = dict["messages"] as? [Any] ?? dict["history"] as? [Any] ?? dict["items"] as? [Any]
            meta.model = dict["model"] as? String
            meta.startTime = dict["startTime"] ?? dict["start_time"]
            meta.lastUpdated = dict["lastUpdated"] ?? dict["last_updated"]
            meta.sessionID = (dict["sessionId"] as? String) ?? (dict["session_id"] as? String) ?? (dict["id"] as? String)
            if let arr = messages { meta.firstTS = timestampOf(item: arr.first); meta.lastTS = timestampOf(item: arr.last) }
            return (messages, meta)
        }
        return (nil, meta)
    }

    private static func timestampOf(item: Any?) -> Any? {
        guard let obj = item as? [String: Any] else { return nil }
        return obj["ts"] ?? obj["timestamp"] ?? obj["created_at"] ?? obj["time"]
    }

    private static func roleString(of obj: [String: Any]) -> String? {
        let raw = (obj["type"] ?? obj["role"]) as? String
        let lower = raw?.lowercased()
        if lower == "user" || lower == "human" { return "user" }
        if lower == "gemini" || lower == "model" || lower == "assistant" { return "assistant" }
        return lower
    }

    private static func contentString(of obj: [String: Any]) -> String? {
        if let s = obj["content"] as? String { return s }
        if let s = obj["text"] as? String { return s }
        // content array form
        if let contentArray = obj["content"] as? [[String: Any]] {
            var texts: [String] = []
            for block in contentArray {
                if let t = block["text"] as? String { texts.append(t) }
                else if block["inlineData"] != nil || block["inline_file"] != nil { texts.append("[inline data omitted]") }
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        // parts array form
        if let parts = obj["parts"] as? [[String: Any]] {
            var texts: [String] = []
            for p in parts {
                if let t = p["text"] as? String { texts.append(t) }
                else if p["inlineData"] != nil || p["inline_file"] != nil { texts.append("[inline data omitted]") }
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    // MARK: - ToolCalls (Gemini newer formats)

    private static func toolCallObjects(from obj: [String: Any]) -> [[String: Any]] {
        let direct = obj["toolCalls"] ?? obj["tool_calls"]
        if let arr = direct as? [[String: Any]] { return arr }
        if let arr = direct as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
        return []
    }

    private static func toolCallName(from tc: [String: Any]) -> String? {
        if let s = tc["displayName"] as? String, !s.isEmpty { return s }
        if let s = tc["name"] as? String, !s.isEmpty { return s }
        if let s = tc["tool"] as? String, !s.isEmpty { return s }
        return nil
    }

    private static func toolCallInput(from tc: [String: Any]) -> String? {
        if let args = tc["args"] { return stringifyJSON(args) }
        if let input = tc["input"] { return stringifyJSON(input) }
        return nil
    }

    private static func toolCallOutput(from tc: [String: Any]) -> String? {
        if let s = tc["resultDisplay"] as? String, !s.isEmpty { return s }
        if let s = tc["output"] as? String, !s.isEmpty { return s }
        if let result = tc["result"] as? [Any] {
            for item in result {
                guard let dict = item as? [String: Any] else { continue }
                // Common Gemini nesting: result[].functionResponse.response.output
                if let fr = dict["functionResponse"] as? [String: Any],
                   let resp = fr["response"] as? [String: Any] {
                    if let out = resp["output"] as? String, !out.isEmpty { return out }
                    if let out = resp["stdout"] as? String, !out.isEmpty { return out }
                    if let out = resp["text"] as? String, !out.isEmpty { return out }
                    if let out = resp["content"] as? String, !out.isEmpty { return out }
                }
                if let out = dict["output"] as? String, !out.isEmpty { return out }
                if let out = dict["stdout"] as? String, !out.isEmpty { return out }
            }
        }
        return nil
    }

    private static func toolTimestamp(from tc: [String: Any]) -> Date? {
        return decodeDate(tc["timestamp"] ?? tc["ts"] ?? tc["time"])
    }

    private static func toolCallEvent(from tc: [String: Any], baseID: String) -> SessionEvent? {
        let toolName = toolCallName(from: tc)
        let toolInput = toolCallInput(from: tc)
        // Emit call even if args are missing, as long as we have a name or id.
        if toolName == nil, tc["id"] == nil { return nil }
        let rawData = (try? JSONSerialization.data(withJSONObject: tc, options: [])) ?? Data()
        return SessionEvent(
            id: baseID,
            timestamp: toolTimestamp(from: tc),
            kind: .tool_call,
            role: "tool",
            text: nil,
            toolName: toolName ?? (tc["id"] as? String),
            toolInput: toolInput,
            toolOutput: nil,
            messageID: tc["id"] as? String,
            parentID: nil,
            isDelta: false,
            rawJSON: rawData.base64EncodedString()
        )
    }

    private static func toolResultEvent(from tc: [String: Any], baseID: String) -> SessionEvent? {
        guard let toolOutput = toolCallOutput(from: tc), !toolOutput.isEmpty else { return nil }
        let toolName = toolCallName(from: tc)
        let rawData = (try? JSONSerialization.data(withJSONObject: tc, options: [])) ?? Data()
        return SessionEvent(
            id: baseID,
            timestamp: toolTimestamp(from: tc),
            kind: .tool_result,
            role: "tool",
            text: nil,
            toolName: toolName ?? (tc["id"] as? String),
            toolInput: nil,
            toolOutput: toolOutput,
            messageID: tc["id"] as? String,
            parentID: nil,
            isDelta: false,
            rawJSON: rawData.base64EncodedString()
        )
    }

    /// Extract hashed project folder from path: ~/.gemini/tmp/<hash>/(chats)?/session-*.json
    private static func projectHash(from url: URL) -> String? {
        let comps = url.pathComponents
        guard let idx = comps.firstIndex(of: "tmp"), comps.count > idx + 1 else { return nil }
        let candidate = comps[idx + 1]
        // Basic sanity check: hex-like hash length 32..64
        if candidate.count >= 32 && candidate.allSatisfy({ $0.isHexDigit }) { return candidate }
        return nil
    }

    // MARK: - CWD extraction helpers

    /// Bounded scan to keep indexing responsive
    private static func extractCwd(from arr: [Any], limit: Int) -> String? {
        let n = min(limit, arr.count)
        for i in 0..<n {
            guard let obj = arr[i] as? [String: Any] else { continue }
            // 1) Direct keys first
            if let c = directCwd(from: obj), let v = validateCwd(c) { return v }
            // 2) Text blocks with <cwd>…</cwd> or absolute path hints
            if let t = contentString(of: obj) {
                if let c = cwdFromText(t), let v = validateCwd(c) { return v }
            }
        }
        return nil
    }

    /// Recognize common keys used by various builds
    private static func directCwd(from obj: [String: Any]) -> String? {
        let keys = ["cwd", "workingDir", "workdir", "project_root", "projectRoot", "rootDir"]
        for k in keys {
            if let v = obj[k] as? String, !v.isEmpty { return v }
        }
        // Nested repo/root
        if let repo = obj["repo"] as? [String: Any], let root = repo["root"] as? String, !root.isEmpty { return root }
        // Some payloads nest useful fields
        if let payload = obj["payload"] as? [String: Any] {
            for k in keys { if let v = payload[k] as? String, !v.isEmpty { return v } }
            if let repo = payload["repo"] as? [String: Any], let root = repo["root"] as? String, !root.isEmpty { return root }
        }
        return nil
    }

    /// Parse <cwd>…</cwd> or extract plausible absolute paths from text
    private static func cwdFromText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if let start = text.range(of: "<cwd>"), let end = text.range(of: "</cwd>", range: start.upperBound..<text.endIndex) {
            let candidate = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { return candidate }
        }
        // Simple absolute-path heuristic (avoid over-matching)
        // Prefer lines that look like declarations: "Working directory: /path" or start-with-slash tokens
        for line in text.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            // working directory hint
            if let r = l.range(of: ": ") {
                let after = l[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if after.hasPrefix("/") { return String(after) }
            }
            // tokenized path at start
            if l.hasPrefix("/") { return l }
        }
        return nil
    }

    /// Validate a candidate path and prefer the git repo root when available
    private static func validateCwd(_ path: String?) -> String? {
        guard var p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        // Expand ~ if present
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
            if let root = gitRootOf(p) { return root }
            return p
        }
        return nil
    }
    private static func normalizePath(_ p: String) -> String {
        var s = (p as NSString).expandingTildeInPath
        while s.hasSuffix("/") && s.count > 1 { s.removeLast() }
        return URL(fileURLWithPath: s).path
    }

    /// Lightweight git root detection (duplicated here because Session.gitInfo is fileprivate)
    private static func gitRootOf(_ start: String, maxLevels: Int = 6) -> String? {
        var url = URL(fileURLWithPath: start)
        let fm = FileManager.default
        for _ in 0..<maxLevels {
            let dotGitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGitDir.path, isDirectory: &isDir), isDir.boolValue {
                return url.path
            }
            if fm.fileExists(atPath: dotGitDir.path) {
                if let data = try? String(contentsOf: dotGitDir, encoding: .utf8), data.contains("gitdir:") {
                    // Treat as repo root; callers only need root path
                    return url.path
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    private static func firstUserText(from arr: [Any]) -> String? {
        for case let item as [String: Any] in arr {
            let role = roleString(of: item) ?? ""
            if role == "user" {
                if let t = contentString(of: item), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Cap overly long titles
                    return t.count > 400 ? String(t.prefix(400)) : t
                }
            }
        }
        return nil
    }

    private static func previewEventCount(from items: [Any]?) -> Int {
        guard let items, !items.isEmpty else { return 0 }
        let limit = min(items.count, previewCountScanLimit)
        var count = 0

        for i in 0..<limit {
            guard let obj = items[i] as? [String: Any] else { continue }

            let typeStr = (obj["type"] as? String) ?? (obj["role"] as? String)
            let lowerType = typeStr?.lowercased()

            let toolCalls = toolCallObjects(from: obj)
            if !toolCalls.isEmpty {
                for tc in toolCalls {
                    count += 1 // tool_call
                    if toolCallOutput(from: tc) != nil { count += 1 } // tool_result
                }
            }

            let text = contentString(of: obj)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasText = (text?.isEmpty == false)

            let isMeta: Bool = {
                if let t = lowerType {
                    if t == "system" || t == "info" { return true }
                    if t == "tool_result" { return false }
                    if t == "tool_use" || t == "tool_call" { return false }
                    if t == "user" || t == "human" { return false }
                    if t == "gemini" || t == "model" || t == "assistant" { return false }
                }
                // Unknown: count only if it carries displayable content or toolCalls.
                return !hasText && toolCalls.isEmpty
            }()

            if !isMeta {
                // Avoid counting empty assistant wrappers when toolCalls exist (tool events already counted).
                if lowerType == "gemini" || lowerType == "model" || lowerType == "assistant" {
                    if hasText { count += 1 }
                } else {
                    count += 1
                }
            }
        }

        // If file is huge, assume remaining items are non-meta to avoid hiding real sessions.
        if items.count > limit {
            count += (items.count - limit)
        }
        return count
    }

    private static func decodeDate(_ any: Any?) -> Date? {
        guard let any else { return nil }
        if let d = any as? Double { return Date(timeIntervalSince1970: normalizeEpochSeconds(d)) }
        if let i = any as? Int { return Date(timeIntervalSince1970: normalizeEpochSeconds(Double(i))) }
        if let s = any as? String {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let x = iso.date(from: s) { return x }
            let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
            if let x = iso2.date(from: s) { return x }
        }
        return nil
    }

    private static func normalizeEpochSeconds(_ value: Double) -> Double {
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1_000 }
        return value
    }

    private static func stringifyJSON(_ any: Any) -> String? {
        if let s = any as? String { return s }
        if JSONSerialization.isValidJSONObject(any),
           let d = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return String(describing: any)
    }

    private static func sha256(path: String) -> String {
        let d = SHA256.hash(data: Data(path.utf8))
        return d.compactMap { String(format: "%02x", $0) }.joined()
    }
}
