import Foundation

/// A fact lifted out of an agent envelope (spec §6.4 step 5). It becomes a footer chip or a muted note.
struct AgentFact: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case exitCode(Int)
        case wallTime(Double)
        case truncated(agent: String, originalTokens: Int?, totalLines: Int?)
        case note(String)
        case persisted(path: String, bytes: Int?)
    }
    var kind: Kind
}

/// Lifts agent envelopes (text that is about the call, not part of its output) into facts.
///
/// Every rule is anchored at the start or the end of the output and needs its agent's exact pattern.
/// The same words in the middle of the output stay in the body. When nothing matches, the input comes
/// back unchanged (anti-goal A2).
///
/// | Source | Anchor | Pattern | Result |
/// |---|---|---|---|
/// | Codex | start | header lines (`Chunk ID:`, `Wall time: X seconds`, `Process exited with code N`, `Process running with session ID N`, `Exit code: N`, `Original token count: N`, `Script completed/failed/running with cell ID N`) ending in `Output:` | exit code, wall time, notes; token count dropped |
/// | Codex | start | `Warning: truncated output (original token count: N)` + `Total output lines: N` + blank line, repeatable | `truncated` |
/// | Codex | start or end | `aborted by user after Ns` | note |
/// | Claude | whole text | `<persisted-output>` … `</persisted-output>` with `Output too large (S). Full output saved to: P` | `persisted`; body = preview |
/// | Claude | start | `Exit code N` | exit code |
/// | Claude | start or end | `[Truncated: PARTIAL view …]` | `truncated` |
/// | Claude | end | `Shell cwd was reset to …` | note |
/// | Claude | end | `<system-reminder>…</system-reminder>` blocks | hidden notes |
/// | any | start or end | `[Process exited with code N]` | exit code |
/// | any | end | `<shellId: X completed with exit code N>`, `Exit Code: N` | exit code |
///
/// Fact order is canonical, not the order the lines appear: exit code, wall time, truncation,
/// persisted pointer, notes; within one kind, the order of appearance. A Codex header therefore gives
/// `[.exitCode, .wallTime]` although its `Wall time` line comes first.
enum ToolEnvelopes {
    /// `toolName` is reserved: no rule in P1 depends on the tool.
    static func lift(_ text: String, source: SessionSource, toolName: String?) -> (body: String, facts: [AgentFact], hiddenNotes: [String]) {
        var lines = text.components(separatedBy: "\n")
        var facts: [AgentFact.Kind] = []
        var hidden: [String] = []
        switch source {
        case .codex: liftCodex(&lines, &facts)
        case .claude: liftClaude(&lines, &facts, &hidden)
        default: break
        }
        liftGeneric(&lines, &facts)
        guard !facts.isEmpty || !hidden.isEmpty else { return (text, [], []) }
        let ordered = facts.enumerated().sorted {
            let a = rank($0.element), b = rank($1.element)
            return a != b ? a < b : $0.offset < $1.offset
        }.map { AgentFact(kind: $0.element) }
        return (lines.joined(separator: "\n"), ordered, hidden)
    }

    private static func rank(_ k: AgentFact.Kind) -> Int {
        switch k {
        case .exitCode: return 0
        case .wallTime: return 1
        case .truncated: return 2
        case .persisted: return 3
        case .note: return 4
        }
    }

    // MARK: Patterns

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let chunkID = rx(#"^Chunk ID: \S+$"#)
    private static let wallTime = rx(#"^Wall time:? ([0-9.]+) seconds?$"#)
    private static let exited = rx(#"^Process exited with code (-?\d+)$"#)
    private static let sessionRunning = rx(#"^Process running with session ID \S+$"#)
    private static let exitCodeColon = rx(#"^Exit code: (-?\d+)$"#)
    private static let tokenCount = rx(#"^Original token count: \d+$"#)
    private static let script = rx(#"^Script (completed|failed|running with cell ID \S+)$"#)
    private static let truncWarning = rx(#"^Warning: truncated output \(original token count: (\d+)\)$"#)
    private static let totalLines = rx(#"^Total output lines: (\d+)$"#)
    private static let aborted = rx(#"^aborted by user after [0-9.]+s$"#)
    private static let claudeExit = rx(#"^Exit code (-?\d+)$"#)
    private static let cwdReset = rx(#"^Shell cwd was reset to .+$"#)
    private static let partialView = rx(#"^\[Truncated: PARTIAL view[^\]]*\]$"#)
    private static let persistedHeader = rx(#"^Output too large \(([^)]*)\)\. Full output saved to: (.+)$"#)
    private static let bracketExit = rx(#"^\[Process exited with code (-?\d+)\]$"#)
    private static let shellID = rx(#"^<shellId: \S+ completed with exit code (-?\d+)>$"#)
    private static let openCodeExit = rx(#"^Exit Code: (-?\d+)$"#)

    /// Capture groups of a full-line match, or nil.
    private static func match(_ re: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<max(1, m.numberOfRanges)).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func clean(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }

    // MARK: Line helpers

    private static func lastNonBlank(_ lines: [String]) -> Int? {
        lines.lastIndex { !clean($0).isEmpty }
    }

    /// Removes `lines[k...]` and the blank lines that then end the body.
    private static func dropTail(_ lines: inout [String], from k: Int) {
        lines.removeSubrange(k...)
        while let last = lines.last, clean(last).isEmpty { lines.removeLast() }
    }

    // MARK: Codex

    private static func liftCodex(_ lines: inout [String], _ facts: inout [AgentFact.Kind]) {
        var progressed = true
        while progressed {
            progressed = liftCodexHeader(&lines, &facts) || liftCodexTruncation(&lines, &facts)
        }
        if let first = lines.first, match(aborted, clean(first)) != nil {
            facts.append(.note(clean(first)))
            lines.removeFirst()
        } else if let k = lastNonBlank(lines), match(aborted, clean(lines[k])) != nil {
            facts.append(.note(clean(lines[k])))
            dropTail(&lines, from: k)
        }
    }

    /// `Chunk ID … Output:`, `Exit code: N / Wall time / Output:`, `Script … / Wall time / Output:`, `Wall time: X / Output:`.
    /// The block counts only when it reaches its `Output:` line through known header lines.
    private static func liftCodexHeader(_ lines: inout [String], _ facts: inout [AgentFact.Kind]) -> Bool {
        var local: [AgentFact.Kind] = []
        var i = 0
        while i < lines.count {
            let l = clean(lines[i])
            if l == "Output:" {
                guard i > 0 else { return false }
                lines.removeSubrange(0...i)
                facts.append(contentsOf: local)
                return true
            }
            if match(chunkID, l) != nil || match(tokenCount, l) != nil {
            } else if let c = match(wallTime, l), let t = Double(c[0]) {
                local.append(.wallTime(t))
            } else if let c = match(exited, l) ?? match(exitCodeColon, l), let n = Int(c[0]) {
                local.append(.exitCode(n))
            } else if match(sessionRunning, l) != nil {
                local.append(.note(l))
            } else if let c = match(script, l) {
                if c[0] != "completed" { local.append(.note("Script " + c[0])) }
            } else {
                return false
            }
            i += 1
        }
        return false
    }

    /// `Warning: truncated output (original token count: N)`, optional `Total output lines: N`, then a blank line.
    private static func liftCodexTruncation(_ lines: inout [String], _ facts: inout [AgentFact.Kind]) -> Bool {
        guard let first = lines.first, let c = match(truncWarning, clean(first)) else { return false }
        var used = 1
        var total: Int?
        if lines.count > 1, let t = match(totalLines, clean(lines[1])) {
            total = Int(t[0])
            used = 2
        }
        if lines.count > used, clean(lines[used]).isEmpty { used += 1 }
        lines.removeSubrange(0..<used)
        facts.append(.truncated(agent: "codex", originalTokens: Int(c[0]), totalLines: total))
        return true
    }

    // MARK: Claude

    private static func liftClaude(_ lines: inout [String], _ facts: inout [AgentFact.Kind], _ hidden: inout [String]) {
        if liftPersisted(&lines, &facts) { return }
        if let first = lines.first, let c = match(claudeExit, clean(first)), let n = Int(c[0]) {
            facts.append(.exitCode(n))
            lines.removeFirst()
        }
        if let first = lines.first, match(partialView, clean(first)) != nil {
            facts.append(.truncated(agent: "claude", originalTokens: nil, totalLines: nil))
            lines.removeFirst()
        }
        var changed = true
        while changed {
            changed = false
            guard let k = lastNonBlank(lines) else { break }
            let last = clean(lines[k])
            if match(cwdReset, last) != nil {
                facts.append(.note(last))
                dropTail(&lines, from: k)
                changed = true
            } else if match(partialView, last) != nil {
                facts.append(.truncated(agent: "claude", originalTokens: nil, totalLines: nil))
                dropTail(&lines, from: k)
                changed = true
            } else if last.hasSuffix("</system-reminder>"), let reminder = trailingReminder(lines, endingAt: k) {
                hidden.insert(reminder.note, at: 0)
                dropTail(&lines, from: reminder.start)
                changed = true
            }
        }
    }

    /// The `<system-reminder>` block that ends at line `k`: the nearest opening tag above, with no closing tag between.
    private static func trailingReminder(_ lines: [String], endingAt k: Int) -> (start: Int, note: String)? {
        var j = k
        while j >= 0 {
            let l = clean(lines[j])
            if j < k, l.contains("</system-reminder>") { return nil }
            if l.hasPrefix("<system-reminder>") {
                let block = lines[j...k].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let inner = block.dropFirst("<system-reminder>".count).dropLast("</system-reminder>".count)
                return (j, inner.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            j -= 1
        }
        return nil
    }

    /// `<persisted-output>` wraps the whole output: the header gives the saved path and size, the rest is a preview.
    private static func liftPersisted(_ lines: inout [String], _ facts: inout [AgentFact.Kind]) -> Bool {
        guard let first = lines.first, clean(first) == "<persisted-output>",
              let k = lastNonBlank(lines), clean(lines[k]) == "</persisted-output>", k >= 2,
              let c = match(persistedHeader, clean(lines[1])) else { return false }
        var body = Array(lines[2..<k])
        while let f = body.first, clean(f).isEmpty { body.removeFirst() }
        if let f = body.first, clean(f).hasPrefix("Preview (first"), clean(f).hasSuffix("):") { body.removeFirst() }
        facts.append(.persisted(path: c[1].trimmingCharacters(in: .whitespaces), bytes: byteCount(c[0])))
        lines = body
        return true
    }

    /// "38.4KB", "1.2 MB", "512B", "2 GB" → bytes.
    private static func byteCount(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, Double)] = [("GB", 1_073_741_824), ("MB", 1_048_576), ("KB", 1024), ("B", 1)]
        for (suffix, factor) in units where t.hasSuffix(suffix) {
            guard let n = Double(t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int((n * factor).rounded())
        }
        return nil
    }

    // MARK: Generic

    private static func liftGeneric(_ lines: inout [String], _ facts: inout [AgentFact.Kind]) {
        if let first = lines.first, let c = match(bracketExit, clean(first)), let n = Int(c[0]) {
            facts.append(.exitCode(n))
            lines.removeFirst()
        }
        guard let k = lastNonBlank(lines) else { return }
        let last = clean(lines[k])
        let code = (match(bracketExit, last) ?? match(shellID, last) ?? match(openCodeExit, last)).flatMap { Int($0[0]) }
        if let code {
            facts.append(.exitCode(code))
            dropTail(&lines, from: k)
        }
    }
}
