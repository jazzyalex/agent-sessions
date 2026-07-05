import Foundation

/// One-line tool-call summaries + consecutive-tool-run merging for the Rich
/// block list (Task 6). Pure, stateless — safe to call from the table
/// controller's `apply` path on every rebuild.
enum TranscriptToolSummary {

    /// Best-effort one-line summary of a tool call, derived from its raw JSON
    /// `toolInput`. Priority order (binding, per controller resolution — the
    /// brief's test semantics won over its prose): parsed JSON `command`
    /// (string, or array → drop `bash -lc`-style wrapper elements and join)
    /// → `description` → `file_path`/`path` last path component →
    /// `pattern`/`query`/`url` → `toolName` → first non-empty line of the
    /// raw `toolInput` (trimmed, capped at 80 chars; only reachable when
    /// `toolName` is nil/empty) → "Tool call". Rationale: real agent
    /// toolInput is JSON; when it isn't parseable, junk shouldn't beat a
    /// real tool name, but the raw-line rung still serves nameless tools.
    static func summary(toolName: String?, toolInput: String?) -> String {
        if let input = toolInput, let json = parseJSON(input) {
            if let command = commandSummary(from: json) {
                return command
            }
            if let description = string(json["description"]), !description.isEmpty {
                return description
            }
            if let path = string(json["file_path"]) ?? string(json["path"]), !path.isEmpty {
                return lastPathComponent(path)
            }
            if let pattern = string(json["pattern"]), !pattern.isEmpty {
                return pattern
            }
            if let query = string(json["query"]), !query.isEmpty {
                return query
            }
            if let url = string(json["url"]), !url.isEmpty {
                return url
            }
        }

        if let toolName, !toolName.isEmpty {
            return toolName
        }

        if let input = toolInput, let firstLine = firstNonEmptyLine(input) {
            return cap(firstLine, at: 80)
        }

        return "Tool call"
    }

    /// Fold consecutive `.toolCall`/`.toolOut` rows (run length >= 2) into a
    /// single `.toolGroup` row keyed by the first block's `globalBlockIndex`.
    /// A lone tool row (run length 1) is left as `.message` — it still renders
    /// as a collapsed tool card, just without group chrome.
    static func mergeToolRuns(_ rows: [BlockRowModel]) -> [BlockRowModel] {
        var result: [BlockRowModel] = []
        result.reserveCapacity(rows.count)

        var i = 0
        while i < rows.count {
            let row = rows[i]
            guard case .message(let block) = row.content, block.kind.isTool else {
                result.append(row)
                i += 1
                continue
            }

            var runBlocks: [SessionTranscriptBuilder.LogicalBlock] = [block]
            var j = i + 1
            while j < rows.count, case .message(let nextBlock) = rows[j].content, nextBlock.kind.isTool {
                runBlocks.append(nextBlock)
                j += 1
            }

            if runBlocks.count >= 2 {
                result.append(BlockRowModel(id: row.id, content: .toolGroup(runBlocks)))
            } else {
                result.append(row)
            }
            i = j
        }

        return result
    }

    // MARK: - JSON helpers

    private static func parseJSON(_ input: String) -> [String: Any]? {
        guard let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// `command` may be a plain string, or an argv-style array. For arrays,
    /// drop leading shell-wrapper elements (`bash`, `sh`, `zsh`, `-lc`, `-c`)
    /// and join the remainder — that remainder is normally the single
    /// human-readable command string emitted by `bash -lc "..."` invocations.
    private static func commandSummary(from json: [String: Any]) -> String? {
        guard let raw = json["command"] else { return nil }

        if let str = raw as? String, !str.isEmpty {
            return str
        }

        if let arr = raw as? [Any] {
            let parts = arr.compactMap { $0 as? String }
            // Drop only the LEADING run of wrapper tokens; stop at the first
            // non-wrapper token and keep everything after it verbatim. A wrapper
            // token appearing later (e.g. `grep -c TODO`) is a real argument.
            let filtered = Array(parts.drop(while: { isShellWrapperToken($0) }))
            let joined = (filtered.isEmpty ? parts : filtered).joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private static func isShellWrapperToken(_ token: String) -> Bool {
        switch token {
        case "bash", "sh", "zsh", "-lc", "-c":
            return true
        default:
            return false
        }
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func firstNonEmptyLine(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func cap(_ text: String, at maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength))
    }
}
