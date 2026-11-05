import Foundation

/// Builds the presentation model of one paired invocation (spec §6.2 pass 2).
///
/// Input side (shared by `build` and `rowSummary`, reads the call's input and sidecar labels only):
/// - **Orphan output** (no call): one `ToolVerb.output` action; the object is the tool name.
/// - **Codex code mode** (`exec`): the script's `tools.*` calls become actions (`exec_command` →
///   shell, `write_stdin` → poll, `apply_patch` → edit, anything else → structured), each with the
///   context item "exec script · command i of n" when n > 1. A script with no readable call is
///   one "Ran script" action whose command is the script.
/// - **Polls** (`write_stdin`, `wait`): the object is the command that started the session or
///   cell (`ToolInvocationIndex.processOwnerBySessionID`); the detail is "session N" / "cell N".
/// - **Shell tools**: wrappers (`bash|sh|zsh -lc|-c`) and a leading `cd X &&` / `cd X;` move to the
///   context; `workdir` / `cwd` give cwd; a heredoc on the first line is split off. Object (spec
///   §14 Q1): the `description` input, then the agent label (call sidecar first, then outputs),
///   then the command's first line.
/// - **Every other tool**: one action with the category's verb (a structured action's verb is
///   its tool name), the primary argument as object, and the input as fields.
///
/// Output side (`build` only), per output block: (1) the text: content items joined as is, any
/// other structured value through `ToolTextDecoding.decode(value:fallback:)` (final; nothing to
/// lift); (2) `ToolEnvelopes.lift` on that text; (3) `ToolTextDecoding.decode(value: nil,
/// fallback: body)` for shape and normalization. Code mode instead uses `CodexExecOutput` and
/// attaches chunks per `CodexExecOutput.assign`; output that is not assigned to a command goes to
/// one extra trailing `ToolVerb.output` action (spec §9).
///
/// Ciphertext (a string that starts `gAAAAA` and is longer than 40 characters) never appears: it
/// becomes "message encrypted in the log (N chars)" in objects, fields, output and plain text.
enum ToolInvocationBuilder {
    typealias Block = SessionTranscriptBuilder.LogicalBlock

    /// - Parameter blocks: the full session block array (`globalBlockIndex` == position).
    static func build(_ ref: ToolInvocationRef, blocks: [Block], index: ToolInvocationIndex,
                      source: SessionSource, duration: Double?) -> ToolInvocation {
        let plan = inputPlan(ref, blocks: blocks, index: index, source: source)
        let call = ref.callBlockIndex.flatMap { block(at: $0, in: blocks) }
        let outputs = ref.outputBlockIndices.compactMap { block(at: $0, in: blocks) }
        let toolName = call?.toolName ?? outputs.first?.toolName

        var actions: [ToolAction] = []
        var invocationDuration = duration
        if plan.isCodeMode {
            let exec = mergedExecOutput(outputs)
            invocationDuration = duration ?? exec.wallTimeSeconds
            actions = codeModeActions(plan, exec: exec, status: ref.status, duration: invocationDuration)
        } else if let draft = plan.drafts.first {
            let decoded = decodeOutputs(outputs, source: source, toolName: toolName)
            let exitCode = decoded.facts.lazy.compactMap(exitCodeFact).first
                ?? call?.toolSidecar?.exitCode
                ?? outputs.lazy.compactMap({ $0.toolSidecar?.exitCode }).first
                ?? failedExitCode(ref.status)
            let wallTime = decoded.facts.lazy.compactMap(wallTimeFact).first
            if invocationDuration == nil { invocationDuration = wallTime }
            actions = [finish(draft, output: decoded.text, facts: decoded.facts, hiddenNotes: decoded.hiddenNotes,
                              status: ref.status, exitCode: exitCode, duration: wallTime ?? duration)]
        }
        return ToolInvocation(ref: ref, displayToolName: plan.displayToolName, actions: actions,
                              scriptSource: plan.scriptSource, durationSeconds: invocationDuration)
    }

    /// L1 only: reads the call's input and sidecar labels, never an output body (the chips come
    /// from `ref.status`). A poll whose session was started by a code-mode script reads the
    /// owner's chunk metadata to find the command (a substring scan, no decoding).
    static func rowSummary(_ ref: ToolInvocationRef, blocks: [Block],
                           index: ToolInvocationIndex, source: SessionSource) -> ToolRowSummary {
        let plan = inputPlan(ref, blocks: blocks, index: index, source: source)
        return ToolRowSummary(actions: plan.drafts.map {
            ToolRowAction(category: $0.category, verbKey: $0.verbKey, object: $0.object,
                          objectIsAgentLabel: $0.objectIsAgentLabel, objectDetail: $0.objectDetail)
        }, chips: ToolChip.chips(for: ref.status))
    }

    /// "1.2s" under a minute (one decimal), else "1m 5s".
    static func durationText(_ seconds: Double) -> String {
        guard seconds >= 60 else { return String(format: "%.1fs", max(0, seconds)) }
        let total = Int(seconds.rounded())
        return "\(total / 60)m \(total % 60)s"
    }

    // MARK: - Input plan

    /// An action before its output is known.
    private struct Draft {
        var category: ToolCategory
        var verbKey: String
        var object = ""
        var objectIsAgentLabel = false
        var objectDetail: String?
        var context: [ToolContextItem] = []
        var command: String?
        /// The whole command (heredoc included) for `plainText`.
        var fullCommand: String?
        var heredoc: DecodedText?
        var inputFields: [ToolField] = []
    }

    private struct InputPlan {
        var displayToolName: String
        var drafts: [Draft]
        var isCodeMode = false
        var script: CodexExecScript?
        var scriptSource: String?
    }

    private static func inputPlan(_ ref: ToolInvocationRef, blocks: [Block],
                                  index: ToolInvocationIndex, source: SessionSource) -> InputPlan {
        let callIndex = ref.callBlockIndex.flatMap { blocks.indices.contains($0) ? $0 : nil }
        let firstOutput = ref.outputBlockIndices.first { blocks.indices.contains($0) }
        let nameBlock = callIndex ?? firstOutput
        let toolName = nameBlock.flatMap { blocks[$0].toolName }
        let namespace = nameBlock.flatMap { blocks[$0].toolNamespace }
        let display = displayName(toolName, namespace: namespace)
        let category = ToolCategoryMap.category(source: source, toolName: toolName, namespace: namespace)

        guard let callIndex else {
            var draft = Draft(category: category, verbKey: ToolVerb.output)
            draft.object = display
            return InputPlan(displayToolName: display, drafts: [draft])
        }
        let input = blocks[callIndex].toolInput

        if ToolStatusProbe.isCodeMode(toolName: toolName, source: source), (namespace ?? "").isEmpty {
            let script = input.flatMap { CodexExecScript.parse($0) }
            var drafts: [Draft]
            if let script {
                let count = script.calls.count
                drafts = script.calls.enumerated().map { offset, call in
                    var draft = scriptCallDraft(call, index: index, blocks: blocks, source: source)
                    if count > 1 {
                        draft.context.insert(ToolContextItem(key: "script", value: ToolText.scriptCommand(offset + 1, of: count)),
                                             at: 0)
                    }
                    return draft
                }
            } else {
                var draft = Draft(category: .shell, verbKey: ToolVerb.ranScript)
                draft.command = input ?? ""
                draft.fullCommand = input ?? ""
                draft.object = singleLine(input ?? "")
                drafts = [draft]
            }
            return InputPlan(displayToolName: display, drafts: drafts, isCodeMode: true, script: script,
                             scriptSource: input)
        }

        let arguments = parseInput(input)
        if ToolStatusProbe.isPoll(toolName: toolName) {
            return InputPlan(displayToolName: display,
                             drafts: [pollDraft(toolName: toolName ?? "", arguments: arguments.object,
                                                index: index, blocks: blocks, source: source)])
        }
        let label = agentLabel(callIndex: callIndex, outputs: ref.outputBlockIndices, blocks: blocks)
        if category == .shell, let draft = shellDraft(arguments.object, agentLabel: label) {
            return InputPlan(displayToolName: display, drafts: [draft])
        }
        return InputPlan(displayToolName: display,
                         drafts: [genericDraft(category, toolName: toolName, display: display,
                                               arguments: arguments, agentLabel: label)])
    }

    /// The ready-made label (spec §7.1 item 8): the call's sidecar first, then the outputs'.
    private static func agentLabel(callIndex: Int, outputs: [Int], blocks: [Block]) -> String? {
        if let label = nonEmpty(blocks[callIndex].toolSidecar?.agentLabel) { return label }
        for position in outputs where blocks.indices.contains(position) {
            if let label = nonEmpty(blocks[position].toolSidecar?.agentLabel) { return label }
        }
        return nil
    }

    /// "server › tool" for a Codex namespace or a Claude-style `mcp__server__tool` name.
    private static func displayName(_ name: String?, namespace: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        if (namespace ?? "").isEmpty, name.hasPrefix("mcp__") {
            let rest = name.dropFirst("mcp__".count)
            if let separator = rest.range(of: "__"), separator.lowerBound > rest.startIndex,
               separator.upperBound < rest.endIndex {
                return "\(rest[..<separator.lowerBound]) › \(rest[separator.upperBound...])"
            }
        }
        return TranscriptToolSummary.displayToolName(name: name, namespace: namespace) ?? name
    }

    // MARK: Code-mode calls

    private static func scriptCallDraft(_ call: CodexExecScript.Call, index: ToolInvocationIndex,
                                        blocks: [Block], source: SessionSource) -> Draft {
        switch call.tool {
        case "exec_command":
            if let draft = shellDraft(call.arguments, agentLabel: nil) { return draft }
        case "write_stdin":
            return pollDraft(toolName: call.tool, arguments: call.arguments, index: index, blocks: blocks, source: source)
        case "apply_patch":
            return genericDraft(.edit, toolName: call.tool, display: call.tool,
                                arguments: Arguments(object: call.arguments, other: nil), agentLabel: nil)
        default:
            break
        }
        return genericDraft(.structured, toolName: call.tool, display: call.tool,
                            arguments: Arguments(object: call.arguments, other: nil), agentLabel: nil)
    }

    // MARK: Polls

    private static func pollDraft(toolName: String, arguments: [String: ToolPayloadValue],
                                  index: ToolInvocationIndex, blocks: [Block], source: SessionSource) -> Draft {
        let chars = arguments["chars"]?.stringValue ?? ""
        let sendsInput = toolName == "write_stdin" && !chars.isEmpty
        var draft = Draft(category: .shell, verbKey: sendsInput ? ToolVerb.sentInput : ToolVerb.polled)
        if sendsInput { draft.inputFields = [ToolField(key: "chars", value: .string(chars))] }

        var detail: String?
        var processID: String?
        if let id = arguments["session_id"].flatMap(token) {
            processID = id
            detail = ToolText.session(id)
        } else if let id = arguments["cell_id"].flatMap(token) {
            processID = id
            detail = ToolText.cell(id)
        }
        if let processID, let command = ownerCommand(processID, index: index, blocks: blocks, source: source) {
            draft.object = redactedCiphertext(command)
            draft.objectDetail = detail
        } else {
            draft.object = detail ?? ""
        }
        return draft
    }

    /// The display command (first line, wrapper and `cd` lifted) of the invocation that started
    /// process or cell `id`. For a code-mode owner: the command of the chunk whose metadata holds
    /// the id when chunks map to commands by order, else the script's first command.
    private static func ownerCommand(_ id: String, index: ToolInvocationIndex, blocks: [Block],
                                     source: SessionSource) -> String? {
        guard let ownerID = index.processOwnerBySessionID[id],
              let owner = invocation(withID: ownerID, in: index),
              let callIndex = owner.callBlockIndex, blocks.indices.contains(callIndex) else { return nil }
        let call = blocks[callIndex]
        if ToolStatusProbe.isCodeMode(toolName: call.toolName, source: source) {
            guard let script = call.toolInput.flatMap({ CodexExecScript.parse($0) }) else { return nil }
            let commands = script.calls.map { $0.tool == "exec_command" ? shellParts($0.arguments)?.command : nil }
            let ordered = script.calls.allSatisfy { $0.tool == "exec_command" || $0.tool == "write_stdin" }
            if ordered {
                let texts = owner.outputBlockIndices.filter { blocks.indices.contains($0) }.map { blocks[$0].text }
                let found = chunkOrdinal(ofProcessID: id, in: texts)
                if let ordinal = found.ordinal, found.total == script.calls.count, let command = commands[ordinal] {
                    return singleLine(command)
                }
            }
            return commands.lazy.compactMap { $0 }.first.map(singleLine)
        }
        guard let command = shellParts(parseInput(call.toolInput).object)?.command else { return nil }
        return singleLine(command)
    }

    private static func invocation(withID id: Int, in index: ToolInvocationIndex) -> ToolInvocationRef? {
        var low = 0
        var high = index.invocations.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = index.invocations[mid].id
            if candidate == id { return index.invocations[mid] }
            if candidate < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// The text before a chunk's `chunk_id` key: `{"` plain, `{\"` in a JSON-encoded item.
    private static let plainChunkStart = #"{"chunk_id"#
    private static let encodedChunkStart = #"{\"chunk_id"#

    /// Which chunk (0-based, counted over all `texts`) carries `"session_id":id` in its metadata,
    /// and how many chunks there are. Metadata ends at the chunk's `output` key, the next chunk or
    /// 512 characters.
    private static func chunkOrdinal(ofProcessID id: String, in texts: [String]) -> (ordinal: Int?, total: Int) {
        var total = 0
        var ordinal: Int?
        for text in texts {
            var starts: [String.Index] = []
            var cursor = text.startIndex
            while let hit = text.range(of: "chunk_id", range: cursor..<text.endIndex) {
                cursor = hit.upperBound
                let head = text[..<hit.upperBound]
                if head.hasSuffix(plainChunkStart) {
                    starts.append(text.index(hit.lowerBound, offsetBy: -2))
                } else if head.hasSuffix(encodedChunkStart) {
                    starts.append(text.index(hit.lowerBound, offsetBy: -3))
                }
            }
            for (k, start) in starts.enumerated() {
                let next = k + 1 < starts.count ? starts[k + 1] : text.endIndex
                var end = text.index(start, offsetBy: 512, limitedBy: next) ?? next
                if let output = text.range(of: "output", range: start..<end) { end = output.lowerBound }
                if ordinal == nil,
                   ToolInvocationIndex.processIDs(in: text[start..<end], keys: ["session_id"]).contains(id) {
                    ordinal = total
                }
                total += 1
            }
        }
        return (ordinal, total)
    }

    // MARK: Shell

    private struct ShellParts {
        var command: String
        var context: [ToolContextItem]
        /// The input was a `code` script, not a command.
        var isScript: Bool
    }

    private static let shellWrappers: Set<String> = ["bash", "sh", "zsh"]

    /// The command and its context from shell-tool arguments (`command`, `cmd`, Antigravity
    /// `CommandLine`; a `code` script), or nil when there is none.
    private static func shellParts(_ arguments: [String: ToolPayloadValue]) -> ShellParts? {
        var command: String
        var shell: String?
        var isScript = false
        switch arguments["command"] ?? arguments["cmd"] ?? arguments["CommandLine"] {
        case .string(let raw)?:
            command = unwrapJSONString(raw)
            if let lifted = liftStringWrapper(command) {
                command = lifted.command
                shell = lifted.shell
            }
        case .array(let items)?:
            let words = items.compactMap(\.stringValue)
            guard !words.isEmpty, words.count == items.count else { return nil }
            if words.count == 3, shellWrappers.contains(baseName(words[0])), words[1] == "-lc" || words[1] == "-c" {
                command = words[2]
                shell = "\(words[0]) \(words[1])"
            } else {
                command = words.map(shellQuoted).joined(separator: " ")
            }
        default:
            guard let code = arguments["code"]?.stringValue, !code.isEmpty else { return nil }
            command = code
            isScript = true
        }
        guard !command.isEmpty else { return nil }

        var cwd = nonEmpty(arguments["workdir"]?.stringValue) ?? nonEmpty(arguments["cwd"]?.stringValue)
        if !isScript, let lifted = liftLeadingCD(command) {
            command = lifted.rest
            if let base = cwd, !lifted.directory.hasPrefix("/"), !lifted.directory.hasPrefix("~") {
                cwd = (base as NSString).appendingPathComponent(lifted.directory)
            } else {
                cwd = lifted.directory
            }
        }
        var context: [ToolContextItem] = []
        if let cwd { context.append(ToolContextItem(key: "cwd", value: cwd)) }
        if let shell { context.append(ToolContextItem(key: "shell", value: shell)) }
        if let timeout = arguments["timeout"].flatMap(token) { context.append(ToolContextItem(key: "timeout", value: timeout)) }
        return ShellParts(command: command, context: context, isScript: isScript)
    }

    /// A shell action, or nil when the arguments hold no command.
    private static func shellDraft(_ arguments: [String: ToolPayloadValue], agentLabel: String?) -> Draft? {
        guard let parts = shellParts(arguments) else { return nil }
        var draft = Draft(category: .shell, verbKey: parts.isScript ? ToolVerb.ranScript : ToolVerb.ran)
        draft.context = parts.context
        draft.fullCommand = parts.command
        if !parts.isScript, let split = splitHeredoc(parts.command) {
            draft.command = split.command
            draft.heredoc = DecodedText(text: split.body,
                                        sourceMap: split.body.isEmpty ? [] : [SourceMapEntry(
                                            rendered: NSRange(location: 0, length: split.body.utf16.count),
                                            source: NSRange(location: 0, length: split.body.utf16.count))],
                                        shape: .plain)
        } else {
            draft.command = parts.command
        }
        if let description = nonEmpty(arguments["description"]?.stringValue) {
            draft.object = redactedCiphertext(singleLine(description))
            draft.objectIsAgentLabel = true
        } else if let agentLabel {
            draft.object = redactedCiphertext(singleLine(agentLabel))
            draft.objectIsAgentLabel = true
        } else {
            draft.object = singleLine(draft.command ?? "")
        }
        return draft
    }

    /// `bash -lc '<script>'` / `zsh -c "<script>"` where the rest is exactly one quoted word.
    private static func liftStringWrapper(_ text: String) -> (command: String, shell: String)? {
        var rest = Substring(text).drop(while: \.isWhitespace)
        let program = rest.prefix { !$0.isWhitespace }
        rest = rest.dropFirst(program.count).drop(while: { $0 == " " || $0 == "\t" })
        let flag = rest.prefix { !$0.isWhitespace }
        guard shellWrappers.contains(baseName(String(program))), flag == "-lc" || flag == "-c" else { return nil }
        rest = rest.dropFirst(flag.count).drop(while: \.isWhitespace)
        while let last = rest.last, last.isWhitespace { rest = rest.dropLast() }
        guard rest.count >= 2, let quote = rest.first, quote == "'" || quote == "\"", rest.last == quote else { return nil }
        let inner = rest.dropFirst().dropLast()
        if quote == "'" {
            guard !inner.contains("'") else { return nil }
            return (String(inner), "\(program) \(flag)")
        }
        var out = ""
        var iterator = inner.makeIterator()
        while let c = iterator.next() {
            if c == "\"" { return nil }
            if c == "\\" {
                guard let next = iterator.next() else { out.append(c); break }
                switch next {
                case "\"", "\\", "$", "`": out.append(next)
                case "\n": break
                default: out.append(c); out.append(next)
                }
            } else {
                out.append(c)
            }
        }
        return (out, "\(program) \(flag)")
    }

    /// A leading `cd X &&` / `cd X;` (X bare or quoted) and the non-empty command after it.
    private static func liftLeadingCD(_ command: String) -> (directory: String, rest: String)? {
        var s = Substring(command).drop(while: { $0 == " " || $0 == "\t" })
        guard s.hasPrefix("cd"), let gap = s.dropFirst(2).first, gap == " " || gap == "\t" else { return nil }
        s = s.dropFirst(2).drop(while: { $0 == " " || $0 == "\t" })
        let directory: Substring
        if let quote = s.first, quote == "'" || quote == "\"" {
            let body = s.dropFirst()
            guard let close = body.firstIndex(of: quote) else { return nil }
            directory = body[..<close]
            if quote == "\"", directory.contains("\\") { return nil }
            s = body[body.index(after: close)...]
        } else {
            directory = s.prefix { !$0.isWhitespace && $0 != ";" && $0 != "&" && $0 != "|" }
            s = s.dropFirst(directory.count)
        }
        guard !directory.isEmpty else { return nil }
        s = s.drop(while: { $0 == " " || $0 == "\t" })
        if s.hasPrefix("&&") {
            s = s.dropFirst(2)
        } else if s.hasPrefix(";") {
            s = s.dropFirst()
        } else {
            return nil
        }
        let rest = s.drop(while: \.isWhitespace)
        guard !rest.isEmpty else { return nil }
        return (String(directory), String(rest))
    }

    /// A heredoc (`<<WORD`, `<<'WORD'`, `<<"WORD"`, `<<-WORD`) opened on the first line, whose
    /// terminator is the last non-blank line. Anything else (a here-string, two heredocs, text after
    /// the terminator) is not split, so no command text is lost.
    private static func splitHeredoc(_ command: String) -> (command: String, body: String)? {
        guard let newline = command.firstIndex(of: "\n") else { return nil }
        let first = command[..<newline]
        var openers: [Range<Substring.Index>] = []
        var cursor = first.startIndex
        while let hit = first.range(of: "<<", range: cursor..<first.endIndex) {
            cursor = first.index(after: hit.lowerBound)
            let before = hit.lowerBound > first.startIndex ? first[first.index(before: hit.lowerBound)] : " "
            let after = hit.upperBound < first.endIndex ? first[hit.upperBound] : " "
            if before != "<", after != "<" { openers.append(hit) }
        }
        guard openers.count == 1, let opener = openers.first else { return nil }
        var p = opener.upperBound
        var stripsTabs = false
        if p < first.endIndex, first[p] == "-" { stripsTabs = true; p = first.index(after: p) }
        while p < first.endIndex, first[p] == " " { p = first.index(after: p) }
        guard p < first.endIndex else { return nil }
        let word: Substring
        if first[p] == "'" || first[p] == "\"" {
            let quote = first[p]
            let body = first[first.index(after: p)...]
            guard let close = body.firstIndex(of: quote) else { return nil }
            word = body[..<close]
        } else {
            word = first[p...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        }
        guard !word.isEmpty else { return nil }
        let lines = command[command.index(after: newline)...].split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.firstIndex(where: { (stripsTabs ? $0.drop(while: { $0 == "\t" }) : $0) == word }),
              lines[(end + 1)...].allSatisfy({ $0.allSatisfy(\.isWhitespace) }) else { return nil }
        return (String(first), lines[..<end].joined(separator: "\n"))
    }

    /// One shell word: kept bare when it holds only safe characters, else single-quoted.
    private static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A value that is itself a JSON string literal (Antigravity double-encodes arguments) is
    /// unwrapped once.
    private static func unwrapJSONString(_ text: String) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"",
              case .string(let inner)? = ToolTextDecoding.decodeJSONString(text, maxDepth: 1) else { return text }
        return inner
    }

    private static func baseName(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }

    // MARK: Generic

    private struct Arguments {
        /// The input when it is a JSON object (or a parsed script call's arguments).
        var object: [String: ToolPayloadValue]
        /// Any other input: a JSON array or scalar, or raw text as a string.
        var other: ToolPayloadValue?
    }

    private static func parseInput(_ input: String?) -> Arguments {
        guard let input, !input.isEmpty else { return Arguments(object: [:], other: nil) }
        if let first = input.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
           let data = input.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let value = ToolPayloadValue(jsonObject: parsed) {
            if case .object(let object) = value { return Arguments(object: object, other: nil) }
            return Arguments(object: [:], other: value)
        }
        return Arguments(object: [:], other: .string(input))
    }

    /// Spec §6.3 primary arguments, in the order the label reads them.
    private static let primaryKeys = ["command", "cmd", "file_path", "filePath", "target_file", "pattern",
                                      "query", "url", "path", "description"]
    private static let pathKeys: Set<String> = ["file_path", "filePath", "target_file", "path"]

    private static func genericDraft(_ category: ToolCategory, toolName: String?, display: String,
                                     arguments: Arguments, agentLabel: String?) -> Draft {
        var draft = Draft(category: category, verbKey: verbKey(category, toolName: toolName, display: display))
        var fields = orderedFields(arguments.object)
        if let other = arguments.other { fields.append(ToolField(key: "input", value: redactedCiphertext(other))) }
        draft.inputFields = fields

        let patch = arguments.other?.stringValue ?? arguments.object["input"]?.stringValue
            ?? arguments.object["patch"]?.stringValue
        let files = category == .edit ? patch.map(patchFiles) ?? [] : []
        if let file = files.first {
            draft.object = (file as NSString).lastPathComponent
            if files.count > 1 { draft.objectDetail = "+\(files.count - 1)" }
        } else if let key = primaryKeys.first(where: { nonEmpty(arguments.object[$0]?.stringValue) != nil }),
                  let value = arguments.object[key]?.stringValue {
            let fileNameOnly = (category == .read || category == .edit) && pathKeys.contains(key)
            draft.object = fileNameOnly ? (value as NSString).lastPathComponent : singleLine(value)
            draft.objectIsAgentLabel = key == "description"
        } else if let agentLabel {
            draft.object = singleLine(agentLabel)
            draft.objectIsAgentLabel = true
        } else if let title = nonEmpty(arguments.object["title"]?.stringValue) {
            draft.object = singleLine(title)
        } else if let first = fields.lazy.compactMap({ nonEmpty($0.value.stringValue) }).first {
            draft.object = singleLine(first)
        }
        draft.object = redactedCiphertext(draft.object)
        return draft
    }

    private static func verbKey(_ category: ToolCategory, toolName: String?, display: String) -> String {
        switch category {
        case .structured:
            return display.isEmpty ? ToolVerb.output : display
        case .web:
            return (toolName ?? "").lowercased().contains("search") ? ToolVerb.searchedWeb : ToolVerb.fetched
        default:
            return ToolCategoryMap.defaultVerbKey(category)
        }
    }

    /// Primary-argument keys first (spec order), then the rest alphabetically. Ciphertext replaced.
    private static func orderedFields(_ object: [String: ToolPayloadValue]) -> [ToolField] {
        let primary = primaryKeys.filter { object[$0] != nil }
        let rest = object.keys.filter { !primaryKeys.contains($0) }.sorted()
        return (primary + rest).compactMap { key in
            object[key].map { ToolField(key: key, value: redactedCiphertext($0)) }
        }
    }

    /// Paths named by `*** Update File:` / `*** Add File:` / `*** Delete File:` patch headers.
    private static func patchFiles(_ patch: String) -> [String] {
        let prefixes = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        return patch.split(separator: "\n").compactMap { line in
            guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return nil }
            return nonEmpty(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Output

    private struct DecodedOutput {
        var text: DecodedText?
        var facts: [AgentFact] = []
        var hiddenNotes: [String] = []
    }

    /// The per-output pipeline (see the type comment). Several outputs are lifted one by one and
    /// decoded as one body.
    private static func decodeOutputs(_ outputs: [Block], source: SessionSource, toolName: String?) -> DecodedOutput {
        guard !outputs.isEmpty else { return DecodedOutput(text: nil) }
        var bodies: [String] = []
        var result = DecodedOutput(text: nil)
        for output in outputs {
            switch outputText(output) {
            case .decoded(let decoded):
                if outputs.count == 1 { return DecodedOutput(text: redactedCiphertext(decoded)) }
                bodies.append(decoded.text)
            case .text(let text):
                let lifted = ToolEnvelopes.lift(text, source: source, toolName: toolName)
                bodies.append(lifted.body)
                result.facts += lifted.facts
                result.hiddenNotes += lifted.hiddenNotes
            }
        }
        result.text = redactedCiphertext(ToolTextDecoding.decode(value: nil, fallback: bodies.joined(separator: "\n")))
        return result
    }

    private enum OutputText {
        case text(String)
        /// A structured value already decoded to its final form (pretty JSON, image, binary).
        case decoded(DecodedText)
    }

    private static func outputText(_ output: Block) -> OutputText {
        guard let value = output.toolOutputValue else { return .text(output.text) }
        var parts = ToolJSON.contentItemParts(value)
        if parts == nil, case .object = value { parts = ToolJSON.contentItemParts(.array([value])) }
        if let parts {
            if parts.allSatisfy({ $0 == .image }) { return .decoded(ToolTextDecoding.decode(value: value, fallback: nil)) }
            return .text(ToolJSON.joinedText(parts))
        }
        return .decoded(ToolTextDecoding.decode(value: value, fallback: output.text))
    }

    // MARK: Code mode

    /// Every output of a code-mode call, parsed and concatenated in block order.
    private static func mergedExecOutput(_ outputs: [Block]) -> CodexExecOutput {
        var merged = CodexExecOutput(status: nil, wallTimeSeconds: nil, chunks: [], looseText: nil, facts: [])
        var loose: [DecodedText] = []
        for output in outputs {
            let parsed = CodexExecOutput.parse(value: output.toolOutputValue, fallback: output.text)
            if merged.status == nil { merged.status = parsed.status }
            if merged.wallTimeSeconds == nil { merged.wallTimeSeconds = parsed.wallTimeSeconds }
            merged.chunks += parsed.chunks
            merged.facts += parsed.facts
            if let text = parsed.looseText { loose.append(text) }
        }
        merged.looseText = loose.count > 1
            ? ToolTextDecoding.decode(value: nil, fallback: loose.map(\.text).joined(separator: "\n"))
            : loose.first
        return merged
    }

    private static func codeModeActions(_ plan: InputPlan, exec: CodexExecOutput, status: ToolStatus,
                                        duration: Double?) -> [ToolAction] {
        // No readable call: one "Ran script" action that owns the whole output.
        guard let script = plan.script else {
            guard let draft = plan.drafts.first else { return [] }
            return [finish(draft, output: unassignedOutput(exec, includeChunks: true),
                           facts: exec.chunks.flatMap(\.facts) + exec.facts, hiddenNotes: [], status: status,
                           exitCode: failedExitCode(status), duration: duration)]
        }
        let assigned = CodexExecOutput.assign(exec, to: script)
        let single = plan.drafts.count == 1
        var actions: [ToolAction] = []
        for (offset, draft) in plan.drafts.enumerated() {
            if let chunk = assigned[offset] {
                actions.append(finish(draft, output: redactedCiphertext(chunk.output), facts: chunk.facts, hiddenNotes: [],
                                      status: chunkStatus(chunk, fallback: status), exitCode: chunk.exitCode,
                                      duration: chunk.wallTimeSeconds ?? (single ? duration : nil)))
            } else {
                actions.append(finish(draft, output: nil, facts: [], hiddenNotes: [], status: status,
                                      exitCode: single ? failedExitCode(status) : nil,
                                      duration: single ? duration : nil))
            }
        }
        // Output not assigned to a command shows under the script as one trailing action (spec §9).
        if let output = unassignedOutput(exec, includeChunks: assigned.isEmpty) {
            actions.append(finish(Draft(category: .shell, verbKey: ToolVerb.output), output: output,
                                  facts: assigned.isEmpty ? exec.chunks.flatMap(\.facts) : [], hiddenNotes: [],
                                  status: status, exitCode: nil, duration: nil))
        }
        if !exec.facts.isEmpty, !actions.isEmpty {
            actions[actions.count - 1].facts += exec.facts
        }
        return actions
    }

    /// The loose text, after every chunk output when `includeChunks`; nil when all are empty. A
    /// single piece keeps its own decoding.
    private static func unassignedOutput(_ exec: CodexExecOutput, includeChunks: Bool) -> DecodedText? {
        var pieces: [DecodedText] = includeChunks ? exec.chunks.map(\.output).filter { !$0.text.isEmpty } : []
        if let loose = exec.looseText, !loose.text.isEmpty { pieces.append(loose) }
        guard let first = pieces.first else { return nil }
        if pieces.count == 1 { return redactedCiphertext(first) }
        return redactedCiphertext(ToolTextDecoding.decode(value: nil, fallback: pieces.map(\.text).joined(separator: "\n")))
    }

    /// A chunk's own status: exit 0, or exit 1 with empty output (a search with no matches), is a
    /// success; another code is a failure; no code (still running) keeps the invocation's status.
    private static func chunkStatus(_ chunk: CodexExecOutput.Chunk, fallback: ToolStatus) -> ToolStatus {
        guard let code = chunk.exitCode else { return fallback }
        if code == 0 || (code == 1 && chunk.output.text.isEmpty) { return .success }
        return .failed(exitCode: code)
    }

    // MARK: - Finishing

    private static func finish(_ draft: Draft, output: DecodedText?, facts: [AgentFact], hiddenNotes: [String],
                               status: ToolStatus, exitCode: Int?, duration: Double?) -> ToolAction {
        var bracket: [String] = []
        if let exitCode {
            bracket.append(ToolChip.exit(exitCode))
        } else {
            switch status {
            case .failed(nil): bracket.append(ToolChip.error)
            case .rejected: bracket.append(ToolChip.rejected)
            case .interrupted: bracket.append(ToolChip.interrupted)
            default: break
            }
        }
        if let duration { bracket.append(durationText(duration)) }

        var lines: [String] = []
        if let command = draft.fullCommand {
            lines.append("$ " + command)
        } else {
            lines.append([ToolVerb.text(draft.verbKey), draft.object].filter { !$0.isEmpty }.joined(separator: " "))
        }
        if !bracket.isEmpty { lines.append("[" + bracket.joined(separator: " · ") + "]") }
        if let text = output?.text, !text.isEmpty { lines.append(text) }

        return ToolAction(category: draft.category, verbKey: draft.verbKey, object: draft.object,
                          objectIsAgentLabel: draft.objectIsAgentLabel, objectDetail: draft.objectDetail,
                          context: draft.context, command: draft.command, heredoc: draft.heredoc,
                          inputFields: draft.inputFields, output: output, facts: facts, hiddenNotes: hiddenNotes,
                          status: status, plainText: redactedCiphertext(lines.joined(separator: "\n")))
    }

    private static func exitCodeFact(_ fact: AgentFact) -> Int? {
        if case .exitCode(let code) = fact.kind { return code }
        return nil
    }

    private static func wallTimeFact(_ fact: AgentFact) -> Double? {
        if case .wallTime(let seconds) = fact.kind { return seconds }
        return nil
    }

    private static func failedExitCode(_ status: ToolStatus) -> Int? {
        if case .failed(let code) = status { return code }
        return nil
    }

    // MARK: - Ciphertext

    /// Encrypted Codex `collaboration` messages (Fernet tokens): `gAAAAA` + base64url, > 40 chars.
    private static let ciphertextPrefix = "gAAAAA"
    private static let ciphertextMinLength = 41

    static func isCiphertext(_ text: String) -> Bool {
        text.hasPrefix(ciphertextPrefix) && text.utf16.count >= ciphertextMinLength
    }

    /// The value with every ciphertext string (at any depth) replaced by the placeholder.
    static func redactedCiphertext(_ value: ToolPayloadValue) -> ToolPayloadValue {
        switch value {
        case .string(let s): return isCiphertext(s) ? .string(ToolText.encrypted(characters: s.utf16.count)) : value
        case .array(let items): return .array(items.map(redactedCiphertext))
        case .object(let object): return .object(object.mapValues(redactedCiphertext))
        default: return value
        }
    }

    /// Free text with every ciphertext token (`gAAAAA` + base64url characters, > 40 long) replaced.
    static func redactedCiphertext(_ text: String) -> String {
        replaceCiphertextTokens(text)?.text ?? text
    }

    /// Decoded output with ciphertext replaced. A replacement shifts characters, so the source map
    /// becomes one coarse entry (the decoders' rule when characters cannot be aligned).
    private static func redactedCiphertext(_ decoded: DecodedText) -> DecodedText {
        guard let replaced = replaceCiphertextTokens(decoded.text) else { return decoded }
        let sourceStart = decoded.sourceMap.map(\.source.location).min() ?? 0
        let sourceEnd = decoded.sourceMap.map { NSMaxRange($0.source) }.max() ?? 0
        let length = replaced.text.utf16.count
        return DecodedText(text: replaced.text,
                           sourceMap: length == 0 ? [] : [SourceMapEntry(
                               rendered: NSRange(location: 0, length: length),
                               source: NSRange(location: sourceStart, length: max(0, sourceEnd - sourceStart)))],
                           shape: decoded.shape)
    }

    private static func replaceCiphertextTokens(_ text: String) -> (text: String, count: Int)? {
        guard text.contains(ciphertextPrefix) else { return nil }
        let units = Array(text.utf16)
        let prefix = Array(ciphertextPrefix.utf16)
        func isTokenUnit(_ u: UInt16) -> Bool {
            (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
                || u == 0x2D || u == 0x5F || u == 0x3D
        }
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var count = 0
        var i = 0
        while i < units.count {
            if units[i] == prefix[0], i + prefix.count <= units.count,
               Array(units[i..<(i + prefix.count)]) == prefix,
               i == 0 || !isTokenUnit(units[i - 1]) {
                var end = i + prefix.count
                while end < units.count, isTokenUnit(units[end]) { end += 1 }
                if end - i >= ciphertextMinLength {
                    out.append(contentsOf: ToolText.encrypted(characters: end - i).utf16)
                    count += 1
                    i = end
                    continue
                }
            }
            out.append(units[i])
            i += 1
        }
        return count == 0 ? nil : (String(decoding: out, as: UTF16.self), count)
    }

    // MARK: - Helpers

    private static func block(at position: Int, in blocks: [Block]) -> Block? {
        blocks.indices.contains(position) ? blocks[position] : nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// A process or cell id, timeout or similar scalar as text: whole numbers without a fraction.
    private static func token(_ value: ToolPayloadValue) -> String? {
        switch value {
        case .string(let s): return nonEmpty(s)
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        default: return nil
        }
    }

    private static let objectLimit = 500

    /// The first non-blank line, trimmed, cut at 500 characters.
    private static func singleLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.count > objectLimit ? String(line.prefix(objectLimit)) + "…" : line
    }
}
