import Foundation

/// Evidence from a paired result. The renderer discovers snippet ranges in the decoded text.
struct ToolOutputSyntax: Equatable, Sendable {
    var language: TranscriptSyntaxLanguage?
    var openCodePath: String? = nil
    var blameSource = false

    static func file(path: String, wrappedByOpenCode: Bool = false) -> Self? {
        let language = TranscriptSyntaxLanguage(path: path)
        guard language != nil || ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
        else { return nil }
        return Self(language: language, openCodePath: wrappedByOpenCode ? path : nil)
    }

    static func isIncomplete(_ fact: AgentFact) -> Bool {
        switch fact.kind {
        case .truncated, .persisted: return true
        default: return false
        }
    }

    /// Literal shell header segments, with quoted semicolons kept inside their word.
    /// Expansion, substitution, pipes and background commands prevent a language hint.
    private static func literalShellSegments(_ command: String) -> [String]? {
        guard command.utf8.count <= 8_192, !command.contains("\n"), !command.contains("\r") else { return nil }
        var quote: Character?
        var segment = ""
        var segments: [String] = []
        for character in command {
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
                else if currentQuote == "\"", "$`\\".contains(character) { return nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if "$`\\|&>()".contains(character) {
                return nil
            } else if character == ";" {
                segments.append(segment.trimmingCharacters(in: .whitespaces))
                segment = ""
                continue
            }
            segment.append(character)
        }
        guard quote == nil else { return nil }
        segments.append(segment.trimmingCharacters(in: .whitespaces))
        return segments
    }

    private static let interpreterHeredoc = try! NSRegularExpression(pattern:
        #"\A(python(?:3(?:\.[0-9]+)?)?|bash|sh|zsh|node)(?:[ \t]+-)?[ \t]+<<-?[ \t]*(?:'[A-Za-z_][A-Za-z_0-9]*'|"[A-Za-z_][A-Za-z_0-9]*"|[A-Za-z_][A-Za-z_0-9]*)[ \t]*\z"#)

    static func heredocLanguage(command: String) -> TranscriptSyntaxLanguage? {
        guard let last = literalShellSegments(command)?.last,
              let match = interpreterHeredoc.firstMatch(in: last, range: NSRange(location: 0, length: last.utf16.count))
        else { return nil }
        let interpreter = (last as NSString).substring(with: match.range(at: 1))
        if interpreter.hasPrefix("python") { return .python }
        return interpreter == "node" ? .javascript : .shell
    }

    private static let blameCommand = try! NSRegularExpression(pattern:
        #"\Agit[ \t]+blame(?:[ \t]+-L[ \t]+[1-9][0-9]*,[1-9][0-9]*)?[ \t]+(?:--[ \t]+)?('[^'\r\n]+'|"[^"\r\n]+"|[A-Za-z0-9_./+\-]+)\z"#)
    private static let blameLine = try! NSRegularExpression(pattern:
        #"(?m)^\^?[0-9a-f]{7,40}[ \t]+\([^\r\n)]* [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}[ \t]+([1-9][0-9]*)\)[ \t]([^\r\n]*)$"#)

    static func blameRead(_ input: ToolPayloadValue?) -> Self? {
        guard case .string(let command) = input, command.utf8.count <= 8_192 else { return nil }
        let header: String
        if command.contains("\n") {
            // Only a complete final interpreter heredoc may follow the header. Never
            // discard arbitrary later commands when assigning one language to output.
            guard !command.contains("\r"), let split = ToolInvocationBuilder.splitHeredoc(command),
                  heredocLanguage(command: split.command) != nil else { return nil }
            header = split.command
        } else {
            header = command
        }
        guard let segments = literalShellSegments(header) else { return nil }
        var paths = Set<String>()
        for segment in segments where !segment.isEmpty {
            let words = segment.split(whereSeparator: \.isWhitespace)
            guard words.starts(with: ["git", "blame"]) else {
                // Other shell commands can change cwd or emit another file's blame
                // under a wrapper. Keep only the screenshot's known mixed shapes.
                guard words.starts(with: ["git", "log"])
                    || (segment == segments.last && heredocLanguage(command: segment) != nil)
                else { return nil }
                continue
            }
            guard let match = blameCommand.firstMatch(in: segment, range: NSRange(location: 0, length: segment.utf16.count))
            else { return nil }
            var path = (segment as NSString).substring(with: match.range(at: 1))
            if path.hasPrefix("'") || path.hasPrefix("\"") { path = String(path.dropFirst().dropLast()) }
            guard !path.hasPrefix("-"), TranscriptSyntaxLanguage(path: path) != nil else { return nil }
            paths.insert(path)
        }
        // Default blame rows carry no file boundary. Even two files in the same
        // language cannot safely share multiline string/comment state.
        guard paths.count == 1, let path = paths.first,
              let language = TranscriptSyntaxLanguage(path: path) else { return nil }
        return Self(language: language, blameSource: true)
    }

    // The only supported code-mode record is one literal call emitted directly. The
    // recording has no trusted per-emission boundaries for more than one child.
    private static let directEmission = try! NSRegularExpression(pattern:
        #"\A\s*text\s*\(\s*await\s+tools\.exec_command\s*\(\s*\{([\s\S]*)\}\s*\)\s*\)\s*;?\s*\z"#)
    private static let literalFields: NSRegularExpression = {
        let escape = #"\\(?:["'\\/bfnrtv]|0(?![0-9]))"#
        let double = #""(?:[^"\\\r\n]++|"# + escape + #")*+""#
        let single = #"'(?:[^'\\\r\n]++|"# + escape + #")*+'"#
        let template = #"`(?:[^`\\$]++|\$(?!\{)|\\`|"# + escape + #")*+`"#
        let key = #"(?:([A-Za-z_][A-Za-z_0-9]*)|"([A-Za-z_][A-Za-z_0-9]*)"|'([A-Za-z_][A-Za-z_0-9]*)')"#
        return try! NSRegularExpression(pattern: #"\G\s*"# + key + #"\s*:\s*(?:"# +
            [double, single, template, "[0-9]+", "true", "false", "null"].joined(separator: "|") + #")\s*(,|\z)"#)
    }()

    static func literalSingleton(_ source: String, script: CodexExecScript) -> ToolPayloadValue? {
        guard source.utf8.count <= 8_192, script.calls.count == 1, let call = script.calls.first,
              call.tool == "exec_command",
              let match = directEmission.firstMatch(in: source, range: NSRange(location: 0, length: source.utf16.count))
        else { return nil }
        let fields = (source as NSString).substring(with: match.range(at: 1))
        let ns = fields as NSString
        var offset = 0
        var keys: Set<String> = []
        while offset < ns.length {
            if ns.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            guard let field = literalFields.firstMatch(in: fields, options: [.anchored],
                                                       range: NSRange(location: offset, length: ns.length - offset)),
                  let range = (1...3).map({ field.range(at: $0) }).first(where: { $0.location != NSNotFound }),
                  keys.insert(ns.substring(with: range)).inserted else { return nil }
            offset = NSMaxRange(field.range)
        }
        guard keys.contains("cmd"), !keys.contains("command"), !keys.contains("code"),
              case .string? = call.arguments["cmd"] else { return nil }
        return call.arguments["cmd"]
    }

    private static let shellRead = try! NSRegularExpression(pattern:
        #"\A(?:cat[ \t]+|nl[ \t]+-ba[ \t]+|sed[ \t]+-n[ \t]+'([1-9][0-9]{0,8})(?:,([1-9][0-9]{0,8}))?p'[ \t]+)('[^'\r\n]+'|"[^"\x24`\\\r\n]+"|[A-Za-z0-9_./+\-]+)(?:[ \t]+\|[ \t]+sed[ \t]+-n[ \t]+'([1-9][0-9]{0,8})(?:,([1-9][0-9]{0,8}))?p')?\z"#)
    private static let shellWrapper = try! NSRegularExpression(pattern:
        #"\A(?:bash|sh|zsh)[ \t]+-l?c[ \t]+(?:'([^']+)'|"([^"\x24`\\]+)")\z"#)

    static func shellRead(_ input: ToolPayloadValue?, output: DecodedText) -> Self? {
        let command: String
        switch input {
        case .string(let raw):
            guard raw.utf8.count <= 8_192, !raw.contains("\n"), !raw.contains("\r") else { return nil }
            command = raw.trimmingCharacters(in: .whitespaces)
        case .array(let argv):
            let args = argv.compactMap(\.stringValue)
            guard args.count == argv.count else { return nil }
            if args.count == 3, ["bash", "sh", "zsh"].contains((args[0] as NSString).lastPathComponent),
               ["-c", "-lc"].contains(args[1]) {
                return shellRead(.string(args[2]), output: output)
            }
            guard let path = args.last, !path.hasPrefix("-"), !path.contains("\n"), !path.contains("\r"),
                  let first = args.first else { return nil }
            switch (first, args.count) {
            case ("cat", 2): break
            case ("nl", 3) where args[1] == "-ba":
                guard case .lineNumbered = output.shape else { return nil }
            case ("sed", 4) where args[1] == "-n":
                return shellRead(.string("sed -n '\(args[2])' '\(path)'"), output: output)
            default: return nil
            }
            return file(path: path)
        default: return nil
        }

        let original = command as NSString
        let wrapper = shellWrapper.firstMatch(in: command, range: NSRange(location: 0, length: original.length))
        let inner = wrapper.flatMap { match in
            [match.range(at: 1), match.range(at: 2)].first { $0.location != NSNotFound }
        }.map { original.substring(with: $0) } ?? command
        let ns = inner as NSString
        guard let match = shellRead.firstMatch(in: inner, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let numbered = inner.hasPrefix("nl ") || inner.hasPrefix("nl\t")
        if numbered {
            guard case .lineNumbered = output.shape else { return nil }
        }
        for (start, end) in [(1, 2), (4, 5)] where match.range(at: end).location != NSNotFound {
            guard let first = Int(ns.substring(with: match.range(at: start))),
                  let last = Int(ns.substring(with: match.range(at: end))), last >= first else { return nil }
        }
        guard numbered || match.range(at: 4).location == NSNotFound else { return nil }
        var path = ns.substring(with: match.range(at: 3))
        if path.hasPrefix("'") || path.hasPrefix("\"") { path = String(path.dropFirst().dropLast()) }
        guard !path.hasPrefix("-") else { return nil }
        return file(path: path)
    }

    func snippets(in decoded: DecodedText) -> [TranscriptSyntaxSnippet] {
        let output = decoded.text
        guard output.utf8.count <= TranscriptSyntaxSnippet.bodyLimit else { return [] }
        switch decoded.shape {
        case .image, .binary: return []
        default: break
        }
        if blameSource { return blameSnippets(in: output) }
        let text: String
        let map: [TranscriptSyntaxSpan]
        if let openCodePath {
            let head = "<path>\(openCodePath)</path>\n<type>file</type>\n<content>\n"
            let tail = "\n</content>"
            guard output.hasPrefix(head), output.hasSuffix(tail) else { return [] }
            let body = output.dropFirst(head.count).dropLast(tail.count)
            guard let footer = body.range(of: "\n\n(", options: .backwards),
                  !body[footer.lowerBound...].hasPrefix("\n\n(Output capped"),
                  body[footer.lowerBound...].hasPrefix("\n\n(Showing lines ")
                    || body[footer.lowerBound...].hasPrefix("\n\n(End of file - total "),
                  let stripped = ToolTextDecoding.stripLineNumbersMapped(String(body[..<footer.lowerBound]))
            else { return [] }
            text = stripped.text
            map = stripped.map.map {
                TranscriptSyntaxSpan(source: $0.rendered, renderedLocation: head.utf16.count + $0.source.location)
            }
        } else {
            text = output
            map = [TranscriptSyntaxSpan(source: NSRange(location: 0, length: text.utf16.count), renderedLocation: 0)]
        }

        let ranges = language.map { [(NSRange(location: 0, length: text.utf16.count), $0)] } ?? Self.fences(in: text)
        let ns = text as NSString
        var bytes = 0
        return ranges.compactMap { range, language in
            let body = ns.substring(with: range)
            let cost = body.utf8.count
            guard cost > 0, cost <= TranscriptSyntaxSnippet.snippetLimit,
                  bytes + cost <= TranscriptSyntaxSnippet.bodyLimit else { return nil }
            bytes += cost
            let spans = map.compactMap { span -> TranscriptSyntaxSpan? in
                let overlap = NSIntersectionRange(range, span.source)
                guard overlap.length > 0 else { return nil }
                return TranscriptSyntaxSpan(source: NSRange(location: overlap.location - range.location,
                                                            length: overlap.length),
                                            renderedLocation: span.renderedLocation + overlap.location - span.source.location)
            }
            return TranscriptSyntaxSnippet(key: .init(language: language, text: body), spans: spans)
        }
    }

    private func blameSnippets(in output: String) -> [TranscriptSyntaxSnippet] {
        guard let language else { return [] }
        let ns = output as NSString
        var snippets: [TranscriptSyntaxSnippet] = []
        var text = ""
        var textUTF16Length = 0
        var spans: [TranscriptSyntaxSpan] = []
        var previousLine: Int?
        var previousEnd = 0
        func finish() {
            if !text.isEmpty, text.utf8.count <= TranscriptSyntaxSnippet.snippetLimit,
               snippets.count < TranscriptSyntaxSnippet.snippetsPerBody {
                snippets.append(TranscriptSyntaxSnippet(key: .init(language: language, text: text), spans: spans))
            }
            text = ""
            textUTF16Length = 0
            spans = []
        }
        Self.blameLine.enumerateMatches(in: output, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let line = Int(ns.substring(with: match.range(at: 1))) else { return }
            let separator: String? = previousLine.flatMap { _ in
                guard match.range.location >= previousEnd else { return nil }
                return ns.substring(with: NSRange(location: previousEnd,
                                                  length: match.range.location - previousEnd))
            }
            if previousLine.map({ line != $0 + 1 }) == true
                || separator.map({ $0 != "\n" && $0 != "\r\n" }) == true {
                finish()
            }
            if !text.isEmpty {
                text.append("\n")
                textUTF16Length += 1
            }
            let range = match.range(at: 2)
            spans.append(TranscriptSyntaxSpan(source: NSRange(location: textUTF16Length, length: range.length),
                                              renderedLocation: range.location))
            text += ns.substring(with: range)
            textUTF16Length += range.length
            previousLine = line
            previousEnd = NSMaxRange(match.range)
        }
        finish()
        return snippets
    }

    private static let fenceLine = try! NSRegularExpression(pattern: #"(?m)^ {0,3}(`{3,}|~{3,})[^\r\n]*"#)

    private static func fences(in text: String) -> [(NSRange, TranscriptSyntaxLanguage)] {
        let ns = text as NSString
        var open: (marker: String, end: Int, language: TranscriptSyntaxLanguage?)?
        var result: [(NSRange, TranscriptSyntaxLanguage)] = []
        fenceLine.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match else { return }
            let marker = ns.substring(with: match.range(at: 1))
            let info = ns.substring(with: NSRange(location: NSMaxRange(match.range(at: 1)),
                                                  length: NSMaxRange(match.range) - NSMaxRange(match.range(at: 1))))
            if let prior = open {
                if marker.hasPrefix(prior.marker), info.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let language = prior.language, match.range.location > prior.end {
                        result.append((NSRange(location: prior.end, length: match.range.location - prior.end), language))
                    }
                    open = nil
                    if result.count == TranscriptSyntaxSnippet.snippetsPerBody { stop.pointee = true }
                }
            } else {
                let tag = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
                let end = NSMaxRange(match.range)
                guard end < ns.length, ns.character(at: end) == 10 else { return }
                open = (marker, end + 1, tag.flatMap(TranscriptSyntaxLanguage.init(tag:)))
            }
        }
        return result
    }
}
