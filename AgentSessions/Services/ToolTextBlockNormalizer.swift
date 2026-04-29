import Foundation

struct ToolTextBlock: Equatable, Sendable {
    enum Kind: String, Sendable {
        case toolCall
        case toolOutput
    }

    let id: String
    let kind: Kind
    let toolLabel: String
    let lines: [String]
    let groupKey: String?
    let agentFamily: String?
}

enum ToolTextBlockNormalizer {
    private struct OutputInfo {
        var stdout: String?
        var stderr: String?
        var exitCode: Int?
        var status: String?
    }

    private struct Context {
        let id: String
        let kind: ToolTextBlock.Kind
        let toolName: String?
        let toolInput: String?
        let toolOutput: String?
        let rawJSON: String
        let messageID: String?
        let parentID: String?
        let source: SessionSource?
    }

    static func normalize(event: SessionEvent, source: SessionSource?) -> ToolTextBlock? {
        let kind: ToolTextBlock.Kind
        switch event.kind {
        case .tool_call:
            kind = .toolCall
        case .tool_result:
            kind = .toolOutput
        case .error:
            guard event.toolName != nil || event.toolOutput != nil || event.text != nil else { return nil }
            kind = .toolOutput
        default:
            return nil
        }

        let context = Context(
            id: event.id,
            kind: kind,
            toolName: event.toolName,
            toolInput: event.toolInput,
            toolOutput: event.toolOutput ?? event.text,
            rawJSON: event.rawJSON,
            messageID: event.messageID,
            parentID: event.parentID,
            source: source
        )
        return normalize(context: context)
    }

    static func normalize(block: SessionTranscriptBuilder.LogicalBlock, source: SessionSource?) -> ToolTextBlock? {
        let kind: ToolTextBlock.Kind
        switch block.kind {
        case .toolCall:
            kind = .toolCall
        case .toolOut:
            kind = .toolOutput
        default:
            return nil
        }

        let context = Context(
            id: block.eventID,
            kind: kind,
            toolName: block.toolName,
            toolInput: block.toolInput,
            toolOutput: block.text,
            rawJSON: block.rawJSON,
            messageID: block.messageID,
            parentID: nil,
            source: source
        )
        return normalize(context: context)
    }

    static func displayLines(for block: ToolTextBlock) -> [String] {
        switch block.kind {
        case .toolCall:
            return [block.toolLabel] + block.lines
        case .toolOutput:
            return ["out: \(block.toolLabel)"] + block.lines
        }
    }

    static func displayText(for block: ToolTextBlock) -> String {
        displayLines(for: block).joined(separator: "\n")
    }

    static func exitCode(from rawJSON: String) -> Int? {
        guard let obj = parseJSON(rawJSON) else { return nil }
        var info = OutputInfo()
        extractOutputInfo(from: obj, into: &info)
        return info.exitCode
    }

    private static func normalize(context: Context) -> ToolTextBlock {
        let inputObject = parseInputObject(context.toolInput, rawJSON: context.rawJSON)
        let agentFamily = context.source.map { $0.rawValue }
        let groupKey = context.messageID ?? context.parentID ?? extractGroupKey(from: context.rawJSON)

        switch context.kind {
        case .toolCall:
            let (label, lines) = normalizeCall(toolName: context.toolName,
                                                inputObject: inputObject,
                                                rawInput: context.toolInput,
                                                rawJSON: context.rawJSON)
            let finalLines = lines.isEmpty ? ["(no content)"] : lines
            return ToolTextBlock(id: context.id,
                                 kind: .toolCall,
                                 toolLabel: label,
                                 lines: finalLines,
                                 groupKey: groupKey,
                                 agentFamily: agentFamily)
        case .toolOutput:
            let (label, lines) = normalizeOutput(toolName: context.toolName,
                                                 outputText: context.toolOutput,
                                                 rawJSON: context.rawJSON)
            let finalLines = lines.isEmpty ? ["(no output)"] : lines
            return ToolTextBlock(id: context.id,
                                 kind: .toolOutput,
                                 toolLabel: label,
                                 lines: finalLines,
                                 groupKey: groupKey,
                                 agentFamily: agentFamily)
        }
    }

    private static func normalizeCall(toolName: String?,
                                      inputObject: Any?,
                                      rawInput: String?,
                                      rawJSON: String) -> (String, [String]) {
        if let planLines = planLines(from: inputObject, rawInput: rawInput) {
            return ("plan", planLines)
        }

        if let task = taskLines(from: inputObject) {
            return (task.label, task.lines)
        }

        if isShellTool(name: toolName, inputObject: inputObject) {
            let command = extractCommand(from: inputObject, fallback: rawInput)
            let meta = extractShellMeta(from: inputObject)
            var lines: [String] = []
            if let command, !command.isEmpty {
                lines.append(command)
            }
            if let meta {
                lines.append(meta)
            }
            return ("bash", lines)
        }

        if let fileCall = fileOperationLines(toolName: toolName, inputObject: inputObject, rawInput: rawInput) {
            return (fileCall.label, fileCall.lines)
        }

        if let dict = inputObject as? [String: Any],
           let keyValueLines = keyValueLines(from: dict) {
            let label = normalizedToolLabel(from: toolName, defaultLabel: "tool")
            return (label, keyValueLines)
        }

        let fallbackLine = fallbackSummaryLine(from: inputObject, rawText: rawInput, emptyFallback: "(no content)")
        let label = normalizedToolLabel(from: toolName, defaultLabel: "tool")
        return (label, fallbackLine.map { [$0] } ?? ["(no content)"])
    }

    private static func normalizeOutput(toolName: String?,
                                        outputText: String?,
                                        rawJSON: String) -> (String, [String]) {
        let label = isShellTool(name: toolName, inputObject: nil) ? "bash" : normalizedToolLabel(from: toolName, defaultLabel: "tool")

        var info = OutputInfo()
        var parsedOutputObject: Any?
        var parsedOutputTrailingText: String?
        if let outputText,
           let parsed = parseJSONWithTrailingText(outputText) {
            let obj = parsed.object
            parsedOutputObject = obj
            parsedOutputTrailingText = parsed.trailingText
            if let blockText = extractTextBlocksDeep(from: obj) {
                appendStdout(blockText, into: &info)
            }
            extractOutputInfo(from: obj, into: &info, allowNestedScalarFallback: false)
        }

        if let obj = parseJSON(rawJSON) {
            if let blockText = extractTextBlocksDeep(from: obj) {
                appendStdout(blockText, into: &info)
            }
            extractOutputInfo(from: obj, into: &info)
        }

        var stdout = info.stdout
        let stderr = info.stderr

        if stdout == nil, stderr == nil, let outputText {
            let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !isEmptyJSONPayload(trimmed) {
                stdout = trimmed
            }
        }

        var lines: [String] = []
        if let stdout {
            lines.append(contentsOf: splitAndTrimTrailingEmptyLines(stdout))
        }
        if let stderr {
            lines.append(contentsOf: splitAndTrimTrailingEmptyLines(stderr))
        }
        lines = readableToolOutputLines(lines)

        if isShellTool(name: toolName, inputObject: nil) {
            if info.exitCode == nil {
                info.exitCode = extractExitCode(from: outputText)
            }
            if let exitCode = info.exitCode,
               !linesContainExitLine(lines) {
                if lines.isEmpty {
                    lines.append("(no output)")
                }
                lines.append("exit: \(exitCode)")
            }
        }

        if lines.isEmpty {
            return (label, ["(no output)"])
        }

        if let parsedOutputObject,
           let summaryLines = structuredSummaryLines(from: parsedOutputObject) {
            return (structuredSummaryLabel(toolName: toolName, fallback: label, object: parsedOutputObject),
                    appendTrailingText(parsedOutputTrailingText, to: summaryLines))
        }

        if shouldPreferStructuredJSONDisplay(parsedOutputObject, extracted: info, rawOutput: outputText),
           let parsedOutputObject,
           let structured = prettyStructuredLines(from: parsedOutputObject) {
            return (label, structured)
        }

        return (label, lines)
    }

    private static func extractGroupKey(from rawJSON: String) -> String? {
        guard let obj = parseJSON(rawJSON) else { return nil }
        return extractGroupKey(from: obj, depth: 0)
    }

    private static func extractGroupKey(from obj: Any, depth: Int) -> String? {
        guard depth <= 4 else { return nil }
        if let dict = obj as? [String: Any] {
            if let explicit = explicitCallID(from: dict) {
                return explicit
            }
            for value in dict.values {
                if let found = extractGroupKey(from: value, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        if let arr = obj as? [Any] {
            for item in arr {
                if let found = extractGroupKey(from: item, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    private static func explicitCallID(from dict: [String: Any]) -> String? {
        let keys = [
            "tool_call_id", "toolCallId", "tool_callId", "toolCallID",
            "tool_use_id", "toolUseId", "tool_useId", "toolUseID",
            "call_id", "callId", "callID"
        ]
        for key in keys {
            if let value = dict[key], let normalized = normalizeCallID(value) {
                return normalized
            }
        }
        if let type = dict["type"] as? String {
            let lower = type.lowercased()
            if lower.contains("tool") || lower.contains("function") {
                if let value = dict["id"], let normalized = normalizeCallID(value) {
                    return normalized
                }
            }
        }
        return nil
    }

    private static func normalizeCallID(_ value: Any) -> String? {
        guard let rendered = stringifyValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rendered.isEmpty else { return nil }
        return rendered
    }

    private static func isShellTool(name: String?, inputObject: Any?) -> Bool {
        let lowered = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let shellNames: Set<String> = ["shell_command", "shell", "bash", "execute", "terminal", "exec"]
        if shellNames.contains(lowered) { return true }
        if lowered.contains("shell") { return true }
        if lowered.contains("bash") { return true }
        if lowered == "execute" { return true }
        if lowered == "exec" { return true }

        if let dict = inputObject as? [String: Any] {
            if dict.keys.contains(where: { $0.lowercased() == "command" }) {
                return true
            }
        }
        return false
    }

    private static func normalizedToolLabel(from toolName: String?, defaultLabel: String) -> String {
        guard let toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !toolName.isEmpty else {
            return defaultLabel
        }
        let lower = toolName.lowercased()
        if lower.contains("read") { return "read" }
        if lower.contains("list") || lower == "ls" { return "list" }
        if lower.contains("glob") { return "glob" }
        if lower.contains("grep") { return "grep" }
        if lower.contains("plan") { return "plan" }
        if lower.contains("task") { return "task" }
        return defaultLabel
    }

    private static func parseInputObject(_ toolInput: String?, rawJSON: String) -> Any? {
        if let toolInput, let obj = parseJSON(toolInput) {
            return obj
        }
        guard let raw = parseJSON(rawJSON) else { return nil }
        if let dict = raw as? [String: Any] {
            if let input = dict["input"] ?? dict["arguments"] ?? dict["parameters"] ?? dict["args"] {
                return input
            }
            if let state = dict["state"] as? [String: Any],
               let input = state["input"] ?? state["arguments"] ?? state["parameters"] {
                return input
            }
            if let payload = dict["payload"] as? [String: Any],
               let input = payload["input"] ?? payload["arguments"] ?? payload["parameters"] {
                return input
            }
            if let data = dict["data"] as? [String: Any] {
                if let input = data["input"] ?? data["arguments"] ?? data["parameters"] {
                    return input
                }
                if let toolRequests = data["toolRequests"] as? [[String: Any]],
                   let first = toolRequests.first,
                   let args = first["arguments"] {
                    return args
                }
            }
        }
        return nil
    }

    private static func parseJSON(_ text: String) -> Any? {
        parseJSONWithTrailingText(text)?.object
    }

    private static func parseJSONWithTrailingText(_ text: String) -> (object: Any, trailingText: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let obj = parseJSONObject(from: trimmed) {
                return (obj, nil)
            }
            if let sanitized = sanitizeNonStrictJSON(trimmed),
               let obj = parseJSONObject(from: sanitized) {
                return (obj, nil)
            }
            if let split = splitLeadingJSONObject(from: trimmed) {
                if let obj = parseJSONObject(from: split.jsonText) {
                    return (obj, split.trailingText)
                }
                if let sanitized = sanitizeNonStrictJSON(split.jsonText),
                   let obj = parseJSONObject(from: sanitized) {
                    return (obj, split.trailingText)
                }
            }
            return nil
        }

        // Some providers store `rawJSON` as a base64-encoded JSON string (for example Claude/OpenClaw).
        // Decode + parse that so normalizers can extract nested metadata (exit codes, stdout/stderr, etc).
        guard trimmed.count >= 16 else { return nil }
        let base64Like = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        if trimmed.rangeOfCharacter(from: base64Like.inverted) != nil { return nil }
        guard let data = Data(base64Encoded: trimmed), !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return (obj, nil)
    }

    private static func parseJSONObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func splitLeadingJSONObject(from text: String) -> (jsonText: String, trailingText: String?)? {
        guard let first = text.first,
              first == "{" || first == "[" else {
            return nil
        }

        var stack: [Character] = []
        var inString = false
        var isEscaped = false

        for index in text.indices {
            let char = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }

            if char == "\"" {
                inString = true
            } else if char == "{" {
                stack.append("}")
            } else if char == "[" {
                stack.append("]")
            } else if char == "}" || char == "]" {
                guard stack.last == char else { return nil }
                stack.removeLast()
                if stack.isEmpty {
                    let jsonEnd = text.index(after: index)
                    let jsonText = String(text[..<jsonEnd])
                    let trailing = String(text[jsonEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (jsonText, trailing.isEmpty ? nil : trailing)
                }
            }
        }

        return nil
    }

    /// Best-effort cleanup for "JSON-like" payloads that embed literal control characters (notably newlines)
    /// inside string literals. Some tool runners print arrays of `{text,type}` blocks without escaping
    /// those characters, which makes them invalid JSON for `JSONSerialization`.
    private static func sanitizeNonStrictJSON(_ text: String) -> String? {
        var out = ""
        out.reserveCapacity(text.count + 16)

        var inString = false
        var isEscaped = false
        var didChange = false

        for scalar in text.unicodeScalars {
            let v = scalar.value

            if inString {
                if isEscaped {
                    isEscaped = false
                    out.unicodeScalars.append(scalar)
                    continue
                }
                if v == 92 { // '\'
                    isEscaped = true
                    out.unicodeScalars.append(scalar)
                    continue
                }
                if v == 34 { // '"'
                    inString = false
                    out.unicodeScalars.append(scalar)
                    continue
                }

                switch v {
                case 0x0A:
                    out.append("\\n")
                    didChange = true
                case 0x0D:
                    out.append("\\r")
                    didChange = true
                case 0x09:
                    out.append("\\t")
                    didChange = true
                case 0x08:
                    out.append("\\b")
                    didChange = true
                case 0x0C:
                    out.append("\\f")
                    didChange = true
                case 0x00...0x1F:
                    let hex = String(format: "%04X", v)
                    out.append("\\u\(hex)")
                    didChange = true
                default:
                    out.unicodeScalars.append(scalar)
                }
            } else {
                if v == 34 { // '"'
                    inString = true
                }
                out.unicodeScalars.append(scalar)
            }
        }

        return didChange ? out : nil
    }

    private static func extractCommand(from inputObject: Any?, fallback: String?) -> String? {
        if let dict = inputObject as? [String: Any] {
            if let commandValue = value(for: ["command"], in: dict) {
                return normalizeCommandValue(commandValue)
            }
        }
        if let fallback {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func normalizeCommandValue(_ value: Any) -> String? {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let arr = value as? [Any] {
            let parts = arr.compactMap { element -> String? in
                if let s = element as? String { return s }
                return String(describing: element)
            }
            guard !parts.isEmpty else { return nil }
            if parts.count >= 3, parts[0] == "bash", ["-lc", "-c"].contains(parts[1]) {
                return parts.dropFirst(2).joined(separator: " ")
            }
            return parts.joined(separator: " ")
        }
        return String(describing: value)
    }

    private static func extractShellMeta(from inputObject: Any?) -> String? {
        guard let dict = inputObject as? [String: Any] else { return nil }
        let cwd = firstString(for: ["cwd", "workdir", "workingDir", "working_directory"], in: dict)
        let timeout = firstInt(for: ["timeout_ms", "timeoutMs", "timeout", "yieldMs", "yield_ms"], in: dict)

        var parts: [String] = []
        if let cwd, !cwd.isEmpty {
            parts.append("cwd: \(cwd)")
        }
        if let timeout {
            parts.append("timeout: \(timeout)ms")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "   ")
    }

    private static func fileOperationLines(toolName: String?,
                                           inputObject: Any?,
                                           rawInput: String?) -> (label: String, lines: [String])? {
        guard let dict = inputObject as? [String: Any] else {
            if let rawInput {
                let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return (normalizedToolLabel(from: toolName, defaultLabel: "file"), [trimmed])
                }
            }
            return nil
        }

        let patterns = value(for: ["patterns", "pattern"], in: dict)
        let folder = firstString(for: ["folder", "directory", "directory_path", "directoryPath", "dir_path"], in: dict)
        let path = firstString(for: ["file_path", "filePath", "path"], in: dict)

        if patterns != nil {
            var lines: [String] = []
            if let folder, !folder.isEmpty {
                lines.append("folder: \(folder)")
            }
            if let patterns {
                let rendered = stringifyValue(patterns) ?? ""
                if !rendered.isEmpty {
                    lines.append("patterns: \(rendered)")
                }
            }
            return ("glob", lines)
        }

        let label = normalizedToolLabel(from: toolName, defaultLabel: "file")
        if label == "read", let path, !path.isEmpty {
            return (label, [path])
        }
        if label == "list", let folder, !folder.isEmpty {
            return (label, [folder])
        }
        if label == "grep", let path, !path.isEmpty {
            return (label, [path])
        }
        if let path, !path.isEmpty {
            return ("file", [path])
        }

        return nil
    }

    private static func keyValueLines(from dict: [String: Any]) -> [String]? {
        var lines: [String] = []

        if let query = firstString(for: ["query", "q", "searchQuery", "search_query"], in: dict),
           !query.isEmpty {
            lines.append("query: \(query)")
        }

        if let prompt = firstString(for: ["prompt", "instruction", "instructions"], in: dict),
           !prompt.isEmpty {
            lines.append("prompt: \(prompt)")
        }

        if let url = firstString(for: ["url", "uri", "link"], in: dict),
           !url.isEmpty {
            lines.append("url: \(url)")
        }

        if let path = firstString(for: ["path", "file_path", "filePath"], in: dict),
           !path.isEmpty {
            lines.append("path: \(path)")
        }

        if let dir = firstString(for: ["directory", "directory_path", "directoryPath", "dir_path"], in: dict),
           !dir.isEmpty {
            lines.append("dir: \(dir)")
        }

        appendKeyValueLine(key: "app", from: dict, to: &lines)
        appendKeyValueLine(key: "direction", from: dict, to: &lines)
        appendKeyValueLine(key: "element_index", label: "element", from: dict, to: &lines)
        appendKeyValueLine(key: "pages", from: dict, to: &lines)

        if let num = firstInt(for: ["numResults", "num_results", "topK", "top_k", "limit", "count", "k", "n"], in: dict) {
            lines.append("numResults: \(num)")
        }

        if !lines.isEmpty {
            return lines
        }

        let keys = dict.keys.sorted()
        guard keys.count <= 4 else { return nil }
        var simpleLines: [String] = []
        for key in keys {
            guard let value = dict[key] else { continue }
            if let line = simpleKeyValueLine(key: key, value: value) {
                simpleLines.append(line)
            } else {
                return nil
            }
        }
        return simpleLines.isEmpty ? nil : simpleLines
    }

    private static func appendKeyValueLine(key: String,
                                           label: String? = nil,
                                           from dict: [String: Any],
                                           to lines: inout [String]) {
        guard let value = dict[key],
              let line = simpleKeyValueLine(key: label ?? key, value: value),
              !lines.contains(line) else {
            return
        }
        lines.append(line)
    }

    private static func simpleKeyValueLine(key: String, value: Any) -> String? {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "\(key): \(trimmed)"
        }
        if let i = value as? Int {
            return "\(key): \(i)"
        }
        if let d = value as? Double {
            return "\(key): \(d)"
        }
        if let b = value as? Bool {
            return "\(key): \(b ? "true" : "false")"
        }
        if let arr = value as? [Any] {
            if arr.isEmpty { return "\(key): []" }
            let stringValues = arr.compactMap { element -> String? in
                if let s = element as? String { return s }
                if let i = element as? Int { return String(i) }
                if let d = element as? Double { return String(d) }
                if let b = element as? Bool { return b ? "true" : "false" }
                return nil
            }
            guard stringValues.count == arr.count, stringValues.count <= 6 else { return nil }
            let joined = stringValues.joined(separator: ", ")
            return "\(key): [\(joined)]"
        }
        return nil
    }

    private static func planLines(from inputObject: Any?, rawInput: String?) -> [String]? {
        let obj = inputObject ?? rawInput.flatMap(parseJSON)
        guard let dict = obj as? [String: Any] else { return nil }
        guard let planAny = dict["plan"] else { return nil }
        let planItems: [Any]
        if let arr = planAny as? [Any] {
            planItems = arr
        } else {
            return nil
        }

        var lines: [String] = []
        for item in planItems {
            if let s = item as? String {
                lines.append("- \(s)")
                continue
            }
            guard let d = item as? [String: Any] else { continue }
            let step = (d["step"] as? String) ?? (d["label"] as? String) ?? (d["title"] as? String) ?? ""
            let status = (d["status"] as? String) ?? (d["state"] as? String) ?? ""
            let symbol: String = {
                switch status.lowercased() {
                case "completed", "complete", "done":
                    return "[x]"
                case "in_progress", "in-progress", "progress", "active":
                    return "[>]"
                case "pending", "todo", "to-do":
                    return "[ ]"
                default:
                    return "-"
                }
            }()
            if step.isEmpty {
                lines.append("\(symbol) (untitled)")
            } else {
                lines.append("\(symbol) \(step)")
            }
        }
        return lines.isEmpty ? nil : lines
    }

    private static func taskLines(from inputObject: Any?) -> (label: String, lines: [String])? {
        guard let dict = inputObject as? [String: Any] else { return nil }
        let prompt = (dict["prompt"] as? String) ?? (dict["instructions"] as? String)
        let description = (dict["description"] as? String) ?? (dict["task"] as? String)
        let subagent = firstString(for: ["subagent_type", "subagentType", "agent"], in: dict)

        guard (prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else {
            return nil
        }

        var label = "task"
        if let subagent, !subagent.isEmpty {
            label += " (\(subagent))"
        }

        var lines: [String] = []
        if let description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        if let prompt {
            let promptLines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let first = promptLines.first,
               lines.first == first {
                lines.append(contentsOf: promptLines.dropFirst())
            } else {
                lines.append(contentsOf: promptLines)
            }
        }

        lines = trimTrailingEmptyLines(lines)
        return lines.isEmpty ? nil : (label, lines)
    }

    private static func fallbackSummaryLine(from inputObject: Any?, rawText: String?, emptyFallback: String) -> String? {
        if let dict = inputObject as? [String: Any] {
            if let uid = dict["uid"] ?? dict["id"] {
                let rendered = stringifyValue(uid) ?? ""
                if !rendered.isEmpty {
                    return "uid: \(rendered)"
                }
            }
            if let path = firstString(for: ["path", "file_path", "filePath"], in: dict), !path.isEmpty {
                return path
            }
            if let compact = compactJSONString(dict), !compact.isEmpty, compact != "{}" {
                return compact
            }
        }
        if let rawText {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !isEmptyJSONPayload(trimmed) {
                return trimmed
            }
        }
        return emptyFallback
    }

    private static func extractOutputInfo(from obj: Any,
                                          into info: inout OutputInfo,
                                          depth: Int = 0,
                                          allowNestedScalarFallback: Bool = true) {
        guard depth <= 4 else { return }

        if let s = obj as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only treat a bare string as stdout when we have no stderr yet. Otherwise we risk
            // capturing non-output status strings (e.g. "error") and blocking later stdout.
            if (depth == 0 || allowNestedScalarFallback), !trimmed.isEmpty, info.stdout == nil, info.stderr == nil {
                info.stdout = trimmed
            }
            return
        }

        if let dict = obj as? [String: Any] {
            let outputValue = dict["output"]
            let resultValue = dict["result"]
            let contentValue = dict["content"]

            if let format = dict["format"] as? String, format.lowercased() == "markdown" {
                if let url = dict["url"] as? String {
                    info.stdout = info.stdout ?? url
                } else if let text = dict["text"] as? String {
                    info.stdout = info.stdout ?? text
                } else if let content = dict["content"] as? String {
                    info.stdout = info.stdout ?? content
                }
            }

            if let url = dict["url"] as? String, info.stdout == nil, info.stderr == nil {
                info.stdout = url
            }

            if let stdoutValue = dict["stdout"] { info.stdout = info.stdout ?? stringifyValue(stdoutValue) }
            if let stderrValue = dict["stderr"] { info.stderr = info.stderr ?? stringifyValue(stderrValue) }
            if let errorValue = dict["error"] { info.stderr = info.stderr ?? stringifyValue(errorValue) }
            if let errValue = dict["err"] { info.stderr = info.stderr ?? stringifyValue(errValue) }
            if let statusValue = dict["status"] as? String { info.status = info.status ?? statusValue }
            if let exitValue = dict["exitCode"] ?? dict["exit_code"] ?? dict["exit"] ?? dict["code"] {
                info.exitCode = info.exitCode ?? extractExitCode(from: exitValue)
            }

            // Fast-path primitives even when stderr is already present.
            if info.stdout == nil {
                if let outputString = outputValue as? String, !outputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    info.stdout = outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let resultString = resultValue as? String, !resultString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    info.stdout = resultString.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let contentString = contentValue as? String, !contentString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    info.stdout = contentString.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if let toolUseResult = dict["toolUseResult"] {
                extractOutputInfo(from: toolUseResult, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let message = dict["message"] {
                extractOutputInfo(from: message, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let details = dict["details"] {
                extractOutputInfo(from: details, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let data = dict["data"] {
                extractOutputInfo(from: data, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let payload = dict["payload"] {
                extractOutputInfo(from: payload, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let result = resultValue {
                extractOutputInfo(from: result, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let output = outputValue {
                extractOutputInfo(from: output, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let content = contentValue {
                extractOutputInfo(from: content, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let value = dict["value"] {
                extractOutputInfo(from: value, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
            if let state = dict["state"] {
                extractOutputInfo(from: state, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }

            // Fallback: if we still have no output after exploring nested structures, stringify the
            // most common containers (result/output/content) for a best-effort display.
            if info.stdout == nil, info.stderr == nil {
                if let contentValue, let rendered = stringifyValue(contentValue), !rendered.isEmpty, !isEmptyJSONPayload(rendered) {
                    info.stdout = rendered
                } else if let outputValue, let rendered = stringifyValue(outputValue), !rendered.isEmpty, !isEmptyJSONPayload(rendered) {
                    info.stdout = rendered
                } else if let resultValue, let rendered = stringifyValue(resultValue), !rendered.isEmpty, !isEmptyJSONPayload(rendered) {
                    info.stdout = rendered
                }
            }
            return
        }

        if let arr = obj as? [Any] {
            for item in arr {
                extractOutputInfo(from: item, into: &info, depth: depth + 1, allowNestedScalarFallback: allowNestedScalarFallback)
            }
        }
    }

    private static func shouldPreferStructuredJSONDisplay(_ obj: Any?, extracted info: OutputInfo, rawOutput: String?) -> Bool {
        guard obj != nil else { return false }
        guard info.stderr == nil else { return false }
        guard let rawOutput else { return false }
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }

        // When there is no explicit stdout/output/result/content field, a JSON API/tool response is
        // more readable as pretty JSON than as a compact one-line payload or an arbitrary leaf value.
        guard let dict = obj as? [String: Any] else {
            return info.stdout == nil && info.exitCode == nil
        }
        let outputKeys = ["stdout", "stderr", "output", "result", "content", "text", "message", "toolUseResult"]
        return !dict.keys.contains { key in
            outputKeys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
        }
    }

    private static func prettyStructuredLines(from obj: Any) -> [String]? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return splitAndTrimTrailingEmptyLines(text)
    }

    private static func structuredSummaryLabel(toolName: String?, fallback: String, object: Any) -> String {
        let normalizedToolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let toolName = normalizedToolName,
           !toolName.isEmpty,
           toolName.lowercased() != "tool" {
            return toolName
        }

        if let dict = object as? [String: Any],
           let target = firstString(for: ["target"], in: dict),
           !target.isEmpty {
            return target
        }

        return fallback
    }

    private static func structuredSummaryLines(from obj: Any) -> [String]? {
        guard let dict = obj as? [String: Any] else {
            return nil
        }

        var lines: [String] = []
        appendSimpleLine(key: "success", from: dict, to: &lines)
        appendSimpleLine(key: "query", from: dict, to: &lines)
        appendSimpleLine(key: "target", from: dict, to: &lines)
        appendSimpleLine(key: "message", from: dict, to: &lines)
        appendSimpleLine(key: "summary", from: dict, to: &lines)
        appendSimpleLine(key: "passed", from: dict, to: &lines)
        appendSimpleLine(key: "total_count", from: dict, to: &lines)

        if let rawEntries = dict["entries"] {
            guard appendReadableArraySection(key: "entries",
                                             value: rawEntries,
                                             countOverride: firstInt(for: ["entry_count"], in: dict),
                                             to: &lines) else {
                return nil
            }

            let supportedKeys = Set(["success", "target", "entries", "usage", "entry_count", "message"])
            let hasOnlySupportedSummaryKeys = dict.keys.allSatisfy { supportedKeys.contains($0) }
            return hasOnlySupportedSummaryKeys && !lines.isEmpty ? lines : nil
        }

        if let rawResults = dict["results"] {
            guard appendReadableArraySection(key: "results",
                                             value: rawResults,
                                             countOverride: firstInt(for: ["count"], in: dict),
                                             to: &lines) else {
                return nil
            }
            return lines.isEmpty ? nil : lines
        }

        if let rawMatches = dict["matches"],
           let matchLines = readableSearchMatchLines(value: rawMatches) {
            appendCountLine(key: "matches", count: matchLines.count, to: &lines)
            if !matchLines.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append(contentsOf: groupedSearchMatchLines(matchLines))
            }
            return lines.isEmpty ? nil : lines
        }

        let collectionKeys = ["files", "items", "security_concerns", "logic_errors", "suggestions"]
        var appendedCollection = false
        for key in collectionKeys {
            guard let value = dict[key] else { continue }
            guard appendReadableArraySection(key: key, value: value, to: &lines) else {
                return nil
            }
            appendedCollection = true
        }

        if appendedCollection {
            return lines.isEmpty ? nil : lines
        }

        if containsOutputPayloadKey(dict) {
            return nil
        }

        let knownMetadataKeys = Set(["success", "query", "target", "message", "summary", "total_count", "entry_count", "count", "truncated", "passed"])
        guard dict.keys.allSatisfy({ knownMetadataKeys.contains($0) }) else {
            return nil
        }
        appendSimpleLine(key: "entry_count", from: dict, to: &lines)
        appendSimpleLine(key: "count", from: dict, to: &lines)
        appendSimpleLine(key: "truncated", from: dict, to: &lines)

        return lines.isEmpty ? nil : lines
    }

    private static func appendReadableArraySection(key: String,
                                                   value: Any,
                                                   countOverride: Int? = nil,
                                                   to lines: inout [String]) -> Bool {
        guard let array = value as? [Any] else {
            return false
        }

        appendCountLine(key: key, count: countOverride ?? array.count, to: &lines)
        guard !array.isEmpty else { return true }

        for (index, item) in array.enumerated() {
            if !lines.isEmpty { lines.append("") }

            if let text = readableScalarText(item) {
                lines.append("[\(index + 1)] \(text)")
                continue
            }

            guard let dict = item as? [String: Any],
                  isReadableSummaryObject(dict) else {
                return false
            }

            let title = summaryObjectTitle(for: dict)
            lines.append("[\(index + 1)] \(title)")

            for key in summaryObjectDisplayKeys(from: dict) {
                guard dict[key] != nil else { continue }
                if let longText = firstString(for: [key], in: dict),
                   ["summary", "content", "text"].contains(key),
                   longText.contains("\n") {
                    lines.append("")
                    lines.append(contentsOf: readableMarkdownLines(longText))
                } else {
                    appendSimpleLine(key: key, from: dict, to: &lines)
                }
            }
        }

        return true
    }

    private static func appendCountLine(key: String, count: Int, to lines: inout [String]) {
        let countLine = "\(key): \(count)"
        if !lines.contains(countLine) {
            lines.append(countLine)
        }
    }

    private struct SearchMatchLine {
        let path: String
        let line: Int?
        let content: String
    }

    private static func readableSearchMatchLines(value: Any) -> [SearchMatchLine]? {
        guard let array = value as? [Any] else { return nil }
        if array.isEmpty { return [] }

        var matches: [SearchMatchLine] = []
        matches.reserveCapacity(array.count)

        for item in array {
            guard let dict = item as? [String: Any],
                  let path = firstString(for: ["path", "file"], in: dict),
                  dict.keys.allSatisfy({ ["path", "file", "line", "line_number", "content", "text", "match"].contains($0) }) else {
                return nil
            }

            let content = firstString(for: ["content", "text", "match"], in: dict) ?? ""
            matches.append(SearchMatchLine(path: path,
                                           line: firstInt(for: ["line", "line_number"], in: dict),
                                           content: content))
        }

        return matches
    }

    private static func groupedSearchMatchLines(_ matches: [SearchMatchLine]) -> [String] {
        var lines: [String] = []
        var currentPath: String?

        for match in matches {
            if currentPath != match.path {
                if !lines.isEmpty { lines.append("") }
                lines.append(match.path)
                currentPath = match.path
            }

            if let line = match.line {
                lines.append(match.content.isEmpty ? "\(line):" : "\(line): \(match.content)")
            } else {
                lines.append(match.content)
            }
        }

        return lines
    }

    private static func appendTrailingText(_ trailingText: String?, to lines: [String]) -> [String] {
        guard let trailingText,
              !trailingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return lines
        }

        var output = lines
        if !output.isEmpty { output.append("") }
        output.append(contentsOf: splitAndTrimTrailingEmptyLines(trailingText))
        return output
    }

    private static func readableToolOutputLines(_ lines: [String]) -> [String] {
        let withoutOutputMarker = lines.filter { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "output:"
        }
        guard containsAccessibilityTreeLines(withoutOutputMarker) else {
            return withoutOutputMarker
        }

        let cleanedLines = withoutOutputMarker.compactMap(cleanAccessibilityTreeLine)
            .flatMap { splitAndTrimTrailingEmptyLines($0) }
        return trimRepeatedEmptyLines(cleanedLines)
    }

    private static func containsAccessibilityTreeLines(_ lines: [String]) -> Bool {
        lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("App=") ||
                trimmed.hasPrefix("Window:") ||
                trimmed.range(of: #"^\d+\s+(standard window|split group|tab group|scroll area|HTML content|link|button|pop up button|text field|heading|container|content list|text)\b"#,
                              options: .regularExpression) != nil
        }
    }

    private static func cleanAccessibilityTreeLine(_ line: String) -> String? {
        let indentWidth = max(0, line.prefix { $0 == "\t" }.count - 1) * 2
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("App=") {
            return "App: \(readableAppName(from: trimmed))"
        }

        if trimmed.hasPrefix("Window:") {
            if let windowTitle = firstRegexCapture(in: trimmed, pattern: #"Window:\s*"([^"]+)""#) {
                return "Window: \(windowTitle)"
            }
            return trimmed.replacingOccurrences(of: ".", with: "")
        }

        guard let parsed = parseAccessibilityElementLine(trimmed) else {
            return String(repeating: " ", count: indentWidth) + trimmed
        }

        var output = String(repeating: " ", count: indentWidth) + parsed.summary
        if let value = parsed.value,
           parsed.shouldShowValue {
            output += "\n" + String(repeating: " ", count: indentWidth + 2) + "Value: \(value)"
        }
        return output
    }

    private static func readableAppName(from line: String) -> String {
        if line.contains("Safari") { return "Safari" }
        if let bundle = firstRegexCapture(in: line, pattern: #"App=([^\s]+)"#) {
            return bundle.replacingOccurrences(of: "com.apple.", with: "")
        }
        return line.replacingOccurrences(of: "App=", with: "")
    }

    private struct AccessibilityElementLine {
        let summary: String
        let value: String?
        let shouldShowValue: Bool
    }

    private static func parseAccessibilityElementLine(_ line: String) -> AccessibilityElementLine? {
        let match = regexMatch(in: line, pattern: #"^(\d+)\s+(.+)$"#)
        guard match.count >= 3 else {
            return nil
        }
        let index = match[1]
        let body = match[2]
        let role = accessibilityRole(from: body)
        guard !role.isEmpty else { return nil }

        let remainder = body.dropFirst(role.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedRemainder = stripLeadingAttributes(from: remainder)
        let label = accessibilityLabel(from: cleanedRemainder)
        let value = accessibilityValue(from: body)
        let summary = label.isEmpty ? "\(index) \(role)" : "\(index) \(role) \"\(label)\""
        return AccessibilityElementLine(summary: summary,
                                        value: value,
                                        shouldShowValue: shouldShowAccessibilityValue(role: role, value: value))
    }

    private static func accessibilityRole(from body: String) -> String {
        let roles = [
            "pop up button", "standard window", "split group", "tab group", "scroll area",
            "HTML content", "content list", "text field", "container", "heading", "button",
            "link", "text", "splitter"
        ]
        return roles.first { body.hasPrefix($0) } ?? ""
    }

    private static func stripLeadingAttributes(from text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while output.hasPrefix("("),
              let close = output.firstIndex(of: ")") {
            output = String(output[output.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    private static func accessibilityLabel(from text: String) -> String {
        if let description = firstRegexCapture(in: text, pattern: #"Description:\s*([^,]+)"#) {
            return description.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var candidate = text
        if let range = candidate.range(of: ", Value:") {
            candidate = String(candidate[..<range.lowerBound])
        }
        if let range = candidate.range(of: ", ID:") {
            candidate = String(candidate[..<range.lowerBound])
        }
        if let range = candidate.range(of: ", URL:") {
            candidate = String(candidate[..<range.lowerBound])
        }
        if let range = candidate.range(of: ", Placeholder:") {
            candidate = String(candidate[..<range.lowerBound])
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("Value:") {
            let parts = candidate.split(separator: ",", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                candidate = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                candidate = ""
            }
        }
        return candidate
    }

    private static func accessibilityValue(from text: String) -> String? {
        guard let value = firstRegexCapture(in: text, pattern: #", Value:\s*([^,]+)"#)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("github.com/") else {
            return nil
        }
        return value
    }

    private static func shouldShowAccessibilityValue(role: String, value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        if Int(value) != nil { return false }
        return role.contains("field") || role.contains("text area") || role == "text"
    }

    private static func trimRepeatedEmptyLines(_ lines: [String]) -> [String] {
        var output: [String] = []
        var previousWasEmpty = false
        for line in lines {
            let isEmpty = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmpty, previousWasEmpty { continue }
            output.append(line)
            previousWasEmpty = isEmpty
        }
        return trimTrailingEmptyLines(output)
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        regexMatch(in: text, pattern: pattern).dropFirst().first
    }

    private static func regexMatch(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) else {
            return []
        }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func readableScalarText(_ value: Any) -> String? {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(d) }
        if let b = value as? Bool { return b ? "true" : "false" }
        return nil
    }

    private static func isReadableSummaryObject(_ dict: [String: Any]) -> Bool {
        dict.values.allSatisfy { value in
            if readableScalarText(value) != nil { return true }
            if let arr = value as? [Any] {
                return arr.isEmpty || arr.allSatisfy { readableScalarText($0) != nil }
            }
            return false
        }
    }

    private static func summaryObjectTitle(for dict: [String: Any]) -> String {
        firstString(for: ["session_id", "id", "title", "name", "path", "file", "url"], in: dict) ?? "result"
    }

    private static func summaryObjectDisplayKeys(from dict: [String: Any]) -> [String] {
        let titleKeys = Set(["session_id", "id", "title", "name", "path", "file", "url"])
        let preferred = [
            "when", "source", "model", "line", "column", "matches", "score",
            "content", "summary", "text", "message", "status", "error"
        ]
        var keys: [String] = []
        for key in preferred where dict.keys.contains(key) && !titleKeys.contains(key) {
            keys.append(key)
        }
        for key in dict.keys.sorted() where !titleKeys.contains(key) && !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private static func containsOutputPayloadKey(_ dict: [String: Any]) -> Bool {
        let outputKeys = ["stdout", "stderr", "output", "result", "content", "text", "toolUseResult"]
        return dict.keys.contains { key in
            outputKeys.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
        }
    }

    private static func appendSimpleLine(key: String,
                                         label: String? = nil,
                                         from dict: [String: Any],
                                         to lines: inout [String]) {
        guard let value = dict[key],
              let rendered = stringifyValue(value),
              !rendered.isEmpty,
              !isEmptyJSONPayload(rendered) else {
            return
        }
        lines.append("\(label ?? key): \(rendered)")
    }

    private static func readableMarkdownLines(_ text: String) -> [String] {
        splitAndTrimTrailingEmptyLines(text)
            .map(cleanReadableMarkdownLine)
    }

    private static func cleanReadableMarkdownLine(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("*   ") {
            cleaned = "- " + cleaned.dropFirst(4)
        } else if cleaned.hasPrefix("* ") {
            cleaned = "- " + cleaned.dropFirst(2)
        }
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
        return cleaned
    }

    private static func extractExitCode(from value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int(trimmed) { return i }
            return parseExitCode(from: trimmed)
        }
        return nil
    }

    private static func parseExitCode(from text: String?) -> Int? {
        guard let text else { return nil }
        let patterns = [
            "exit code[:\\s]*(-?\\d+)",
            "exit status[:\\s]*(-?\\d+)",
            "exit[:\\s]*(-?\\d+)"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: text) {
                return Int(text[range])
            }
        }
        return nil
    }

    private static func splitAndTrimTrailingEmptyLines(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return trimTrailingEmptyLines(lines)
    }

    private static func appendStdout(_ text: String, into info: inout OutputInfo) {
        guard !text.isEmpty else { return }
        if let existing = info.stdout, !existing.isEmpty {
            if existing.hasSuffix("\n") || text.hasPrefix("\n") {
                info.stdout = existing + text
            } else {
                info.stdout = existing + "\n" + text
            }
        } else {
            info.stdout = text
        }
    }

    private static func extractTextBlocks(from obj: Any) -> String? {
        if let arr = obj as? [Any] {
            return extractTextBlocks(from: arr)
        }
        if let dict = obj as? [String: Any] {
            if let content = dict["content"] as? [Any] {
                return extractTextBlocks(from: content)
            }
            if let blocks = dict["blocks"] as? [Any] {
                return extractTextBlocks(from: blocks)
            }
            if let parts = dict["parts"] as? [Any] {
                return extractTextBlocks(from: parts)
            }
        }
        return nil
    }

    private static func extractTextBlocksDeep(from obj: Any, depth: Int = 0) -> String? {
        guard depth <= 4 else { return nil }
        if let direct = extractTextBlocks(from: obj) {
            return direct
        }

        if let dict = obj as? [String: Any] {
            for key in dict.keys.sorted() {
                guard let value = dict[key] else { continue }
                if let found = extractTextBlocksDeep(from: value, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        if let arr = obj as? [Any] {
            for item in arr {
                if let found = extractTextBlocksDeep(from: item, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    private static func extractTextBlocks(from arr: [Any]) -> String? {
        var parts: [String] = []
        parts.reserveCapacity(arr.count)
        var sawBlockLikeDict = false

        for item in arr {
            if let dict = item as? [String: Any] {
                let type = (dict["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let text = (dict["text"] as? String) ?? (dict["content"] as? String)
                if let text, !text.isEmpty {
                    if type == nil || type == "text" || type == "input_text" || type == "output_text" || type == "output" {
                        parts.append(text)
                        sawBlockLikeDict = true
                        continue
                    }
                }
                if let nested = extractTextBlocks(from: dict) {
                    parts.append(nested)
                    sawBlockLikeDict = true
                }
                continue
            }

            // Avoid treating plain arrays of strings (for example stderr=["a","b"]) as tool output blocks.
            // Only include raw string entries when we're already in a block-like array.
            if sawBlockLikeDict, let str = item as? String, !str.isEmpty {
                parts.append(str)
            }
        }

        guard sawBlockLikeDict else { return nil }
        let joined = parts.joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : joined
    }

    private static func trimTrailingEmptyLines(_ lines: [String]) -> [String] {
        var out = lines
        while let last = out.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.removeLast()
        }
        return out
    }

    private static func linesContainExitLine(_ lines: [String]) -> Bool {
        for line in lines {
            let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.hasPrefix("exit:") || lower.hasPrefix("exit code:") || lower.hasPrefix("exit status:") {
                return true
            }
        }
        return false
    }

    private static func stringifyValue(_ value: Any) -> String? {
        if let b = value as? Bool {
            return b ? "true" : "false"
        }
        if let s = value as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }

    private static func compactJSONString(_ dict: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func value(for keys: [String], in dict: [String: Any]) -> Any? {
        for key in keys {
            if let value = dict[key] { return value }
        }
        let lowerKeys = keys.map { $0.lowercased() }
        for (k, v) in dict {
            if lowerKeys.contains(k.lowercased()) {
                return v
            }
        }
        return nil
    }

    private static func firstString(for keys: [String], in dict: [String: Any]) -> String? {
        if let value = value(for: keys, in: dict) {
            if let s = value as? String {
                return s
            }
            return stringifyValue(value)
        }
        return nil
    }

    private static func firstInt(for keys: [String], in dict: [String: Any]) -> Int? {
        if let value = value(for: keys, in: dict) {
            return extractExitCode(from: value)
        }
        return nil
    }

    private static func isEmptyJSONPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "{}" || trimmed == "[]" || trimmed == "null"
    }
}
