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
            return block.lines
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
        if let outputText,
           let obj = parseJSON(outputText) {
            extractOutputInfo(from: obj, into: &info)
        }

        if let obj = parseJSON(rawJSON) {
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
        let shellNames: Set<String> = ["shell_command", "shell", "bash", "execute", "terminal"]
        if shellNames.contains(lowered) { return true }
        if lowered.contains("shell") { return true }
        if lowered.contains("bash") { return true }
        if lowered == "execute" { return true }

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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
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
        let timeout = firstInt(for: ["timeout_ms", "timeoutMs", "timeout"], in: dict)

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

    private static func extractOutputInfo(from obj: Any, into info: inout OutputInfo, depth: Int = 0) {
        guard depth <= 4 else { return }

        if let s = obj as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, info.stdout == nil, info.stderr == nil {
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

            if let toolUseResult = dict["toolUseResult"] {
                extractOutputInfo(from: toolUseResult, into: &info, depth: depth + 1)
            }
            if let data = dict["data"] {
                extractOutputInfo(from: data, into: &info, depth: depth + 1)
            }
            if let result = resultValue {
                extractOutputInfo(from: result, into: &info, depth: depth + 1)
            }
            if let output = outputValue {
                extractOutputInfo(from: output, into: &info, depth: depth + 1)
            }
            if let content = contentValue {
                extractOutputInfo(from: content, into: &info, depth: depth + 1)
            }
            if let value = dict["value"] {
                extractOutputInfo(from: value, into: &info, depth: depth + 1)
            }
            if let state = dict["state"] {
                extractOutputInfo(from: state, into: &info, depth: depth + 1)
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
                extractOutputInfo(from: item, into: &info, depth: depth + 1)
            }
        }
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
