import XCTest
import AppKit
import Darwin
@testable import AgentSessions

/// Opt-in, read-only readability check of the tool pipeline over the owner's local sessions
/// (spec §10.2). Set `AS_TOOL_CORPUS_CHECK=1`; the normal suite skips it.
///
/// Every source is discovered the way the app discovers it, newest first, at most
/// `maxSessionsPerSource` sessions: files through `parseFullByPath`, database rows through
/// `parseFullByIdentity`. Each session goes through `SessionTranscriptBuilder.coalescedBlocks`,
/// `ToolInvocationIndex.build`, `ToolInvocationBuilder.build` and `ToolDetailRenderer.render`
/// with every fold open. The check fails when any of these counts is above 0:
/// 1. A `\n`, `\"` or `\/` escape the content does not hold (`contentEscapeCounts`: the raw call
///    input, output value or text and sidecar text, with only the log's encoding layers taken off).
///    Classes: `1.render` the rendered body holds more escapes than the presentation model;
///    `1.decode` the model's text parts that are not JSON presentations (pretty JSON, JSON lines,
///    nested input values) hold more escapes than the content; `1.label` the L1 object does.
/// 2. A rendered output pane starts with `[{"type"` or `{"text"`, or is content items shown as JSON.
/// 3. An invocation with a call shows the fallback label (verb "Output", or no label).
/// 4. Blocks that share a call id are in different invocations, beyond the 1:1 FIFO pairing of a
///    repeated id; or one invocation joins two call ids.
/// 5. A pane folded with the default `FoldState` shows more visual lines than its budget.
/// 6. `gAAAAA` ciphertext in `plainText` (also checked: the rendered body and the L1 object).
/// Report only, per tool family: structured (fallback renderer) and unnamed actions, orphan
/// outputs, and JSON panes whose string values show escapes.
///
/// Output: `scripts/probe_scan_output/tool_corpus/report.json` (git-ignored). It holds counts per
/// source and per tool family, and per violation only its source, file path or session id, block
/// index, tool name, invariant and a structural hint. Never message text, output or commands.
final class TranscriptToolCorpusCheckTests: XCTestCase {
    typealias Block = SessionTranscriptBuilder.LogicalBlock

    static let maxSessionsPerSource = 200
    static let maxFileBytes = 50 * 1024 * 1024
    static let perSessionSeconds: TimeInterval = 20
    static let watchdogSeconds = 1800
    /// Work stops here and the report is written; the watchdog only catches a blocked parser.
    static let budgetSeconds: TimeInterval = 1680
    /// Every source except the two largest gets at most this; Claude then half of what is left,
    /// Codex the rest.
    static let smallSourceSeconds: TimeInterval = 150
    static let fontSize: CGFloat = 13
    static let width: CGFloat = 900
    /// Violation entries kept in the list per class; the counts stay complete.
    static let listedPerClass = 40

    /// Classes that do not fail the check, each with its reason. Empty unless the controller rules
    /// a class to be a spec question rather than a bug.
    static let waived: [String: String] = [:]

    // MARK: - Report

    struct FamilyCounts: Codable {
        var invocations = 0
        var actions = 0
        var orphan_outputs = 0
        /// Report only: actions drawn by the generic structured renderer.
        var structured_actions = 0
        /// Report only: actions of an invocation without a tool name.
        var unnamed_actions = 0
        /// Report only: output panes the model presents as JSON (pretty JSON, JSON lines) whose
        /// string values show escapes. Not an invariant: spec §6.4 keeps that presentation.
        var json_panes_with_escapes = 0
        /// Violations by class whose invocation belongs to this family.
        var violations: [String: Int] = [:]
    }

    struct SourceCounts: Codable {
        var discovered = 0
        var sessions_checked = 0
        var sessions_with_tools = 0
        var parse_failed = 0
        var skipped_over_50mb = 0
        var timeouts = 0
        var not_reached = 0
        var invocations = 0
        var actions = 0
        var seconds = 0.0
        var violations: [String: Int] = [:]
        var families: [String: FamilyCounts] = [:]
    }

    struct Violation: Codable {
        var source: String
        var session: String
        var block: Int
        var tool: String
        var invariant: Int
        var kind: String
        var hint: String
    }

    struct Report: Codable {
        var complete = false
        var elapsed_seconds = 0.0
        var limits: [String: Int] = [:]
        var sources: [String: SourceCounts] = [:]
        var not_covered: [String: String] = [:]
        var no_local_sessions: [String] = []
        var totals: [String: Int] = [:]
        var violation_totals: [String: Int] = [:]
        var waived: [String: String] = [:]
        var violations: [Violation] = []
    }

    private struct Finding {
        var kind: String
        var block: Int
        var tool: String
        var hint: String
    }

    // MARK: - Test

    func testToolCorpusReadability() throws {
        guard ProcessInfo.processInfo.environment["AS_TOOL_CORPUS_CHECK"] == "1" else {
            throw XCTSkip("Set AS_TOOL_CORPUS_CHECK=1 for the read-only local tool corpus check")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("scripts/probe_scan_output/tool_corpus")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reportURL = output.appendingPathComponent("report.json")

        // Independent process: even a blocked synchronous parser cannot keep the test host alive
        // past the watchdog. EOF disarms it.
        let watchdog = Process()
        let completion = Pipe()
        watchdog.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        watchdog.arguments = [root.appendingPathComponent("scripts/replay_watchdog.py").path,
                              "--seconds", String(Self.watchdogSeconds)]
        watchdog.standardInput = completion
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try watchdog.run()
        defer {
            try? completion.fileHandleForWriting.close()
            watchdog.waitUntilExit()
        }

        var report = Report()
        report.limits = ["max_sessions_per_source": Self.maxSessionsPerSource,
                         "max_file_bytes": Self.maxFileBytes,
                         "per_session_seconds": Int(Self.perSessionSeconds),
                         "watchdog_seconds": Self.watchdogSeconds,
                         "budget_seconds": Int(Self.budgetSeconds)]
        report.waived = Self.waived
        // Takes the report as an argument: `checkSource` holds `report` inout while it saves.
        func write(_ report: Report) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        }
        func save() throws { try write(report) }
        try save()

        // Production DEBUG parsers print paths. Mute them; the report is the only artifact.
        fflush(nil)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        let sink = open("/dev/null", O_WRONLY)
        guard savedOut >= 0, savedErr >= 0, sink >= 0 else { throw XCTSkip("Cannot isolate corpus check output") }
        dup2(sink, STDOUT_FILENO)
        dup2(sink, STDERR_FILENO)
        defer {
            fflush(nil)
            dup2(savedOut, STDOUT_FILENO)
            dup2(savedErr, STDERR_FILENO)
            close(savedOut)
            close(savedErr)
            close(sink)
        }

        let start = Date()
        let large: [SessionSource] = [.claude, .codex]
        let order = SessionSource.allCases.filter { !large.contains($0) } + large
        for source in order {
            let remaining = Self.budgetSeconds - Date().timeIntervalSince(start)
            let budget: TimeInterval
            switch source {
            case .claude: budget = remaining / 2
            case .codex: budget = remaining
            default: budget = min(Self.smallSourceSeconds, remaining)
            }
            try checkSource(source, budget: budget, report: &report, save: write)
            report.elapsed_seconds = Date().timeIntervalSince(start)
            try save()
        }
        report.complete = true
        report.elapsed_seconds = Date().timeIntervalSince(start)
        report.no_local_sessions = report.sources.filter { $0.value.discovered == 0 }.map(\.key).sorted()
        try save()

        // Counts only: an assertion message never carries session content.
        let failing = report.violation_totals.filter { Self.waived[$0.key] == nil && $0.value > 0 }
        XCTAssertTrue(failing.isEmpty, "tool corpus violations: \(failing.sorted { $0.key < $1.key })")
        XCTAssertGreaterThan(report.totals["invocations"] ?? 0, 0)
        XCTAssertTrue(report.not_covered.isEmpty, "sources without a discovery seam: \(report.not_covered.keys.sorted())")
    }

    // MARK: - Discovery

    private enum Candidate {
        case file(URL, bytes: Int, date: Date)
        case identity(URL, sessionID: String, date: Date)

        var date: Date {
            switch self {
            case .file(_, _, let date), .identity(_, _, let date): return date
            }
        }
    }

    /// The files the source's discovery finds. Every case is listed, so a new source must decide here.
    private static func fileDiscovery(_ source: SessionSource) -> (any SessionDiscovery)? {
        switch source {
        case .codex: return CodexSessionDiscovery()
        case .claude: return ClaudeSessionDiscovery()
        case .antigravity: return AntigravitySessionDiscovery()
        case .opencode: return OpenCodeSessionDiscovery()
        case .hermes: return HermesSessionDiscovery()
        case .copilot: return CopilotSessionDiscovery()
        case .droid: return DroidSessionDiscovery()
        case .openclaw: return OpenClawSessionDiscovery()
        case .cursor: return CursorSessionDiscovery()
        case .pi: return PiSessionDiscovery()
        case .kimi: return KimiSessionDiscovery()
        case .grok: return GrokSessionDiscovery()
        case .qwen: return QwenSessionDiscovery()
        case .devin: return nil   // one shared database: identity rows only
        case .fx: return FxSessionDiscovery()
        case .cline: return ClineSessionDiscovery()
        case .deepseekHarness: return DeepSeekHarnessDiscovery()
        }
    }

    /// Database rows of identity-backed sources, through the readers their indexers list with.
    private static func identityRows(_ source: SessionSource) -> [Candidate] {
        func rows(_ sessions: [Session], url: URL) -> [Candidate] {
            sessions.map { .identity(url, sessionID: $0.id, date: $0.endTime ?? $0.startTime ?? .distantPast) }
        }
        switch source {
        case .opencode:
            guard let database = OpenCodeSessionDiscovery().databaseURL() else { return [] }
            return rows(OpenCodeSqliteReader.listSessions(customRoot: database.path), url: database)
        case .hermes:
            let discovery = HermesSessionDiscovery()
            guard discovery.hasStateDB() else { return [] }
            let database = discovery.stateDBURL()
            return rows(HermesStateDBReader.listSessions(dbURL: database), url: database)
        case .devin:
            let discovery = DevinSessionDiscovery()
            guard discovery.hasDatabase() else { return [] }
            let database = discovery.databaseURL()
            return rows(DevinSqliteReader.listSessions(databasePath: database.path), url: database)
        case .openclaw:
            return OpenClawSessionDiscovery().discoverSessionDatabases().flatMap { database in
                rows(OpenClawSqliteReader.listSessions(databaseURL: database) ?? [], url: database)
            }
        default:
            return []
        }
    }

    private static func candidates(_ source: SessionSource) -> [Candidate] {
        var all = identityRows(source)
        for url in fileDiscovery(source)?.discoverSessionFiles() ?? [] {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            all.append(.file(url, bytes: values?.fileSize ?? 0, date: values?.contentModificationDate ?? .distantPast))
        }
        return all.sorted { $0.date > $1.date }
    }

    // MARK: - Per source

    private func checkSource(_ source: SessionSource, budget: TimeInterval, report: inout Report,
                             save: (Report) throws -> Void) throws {
        let descriptor = SessionSourceRegistry.descriptor(for: source)
        if descriptor.parseFullByPath == nil, descriptor.parseFullByIdentity == nil {
            report.not_covered[source.rawValue] = "no full parser"
            return
        }
        if Self.fileDiscovery(source) == nil, descriptor.parseFullByIdentity == nil {
            report.not_covered[source.rawValue] = "no discovery seam"
            return
        }
        var counts = SourceCounts()
        let started = Date()
        let candidates = Self.candidates(source)
        counts.discovered = candidates.count
        for (n, candidate) in candidates.prefix(Self.maxSessionsPerSource).enumerated() {
            if Date().timeIntervalSince(started) > budget {
                counts.not_reached += 1
                continue
            }
            autoreleasepool {
                let sessionStart = Date()
                let session: Session?
                let label: String
                switch candidate {
                case .file(let url, let bytes, _):
                    label = url.path
                    if bytes > Self.maxFileBytes {
                        counts.skipped_over_50mb += 1
                        return
                    }
                    session = descriptor.parseFullByPath?(url)
                case .identity(let url, let sessionID, _):
                    label = "id:" + sessionID
                    session = descriptor.parseFullByIdentity?(url, sessionID)
                }
                guard let session else {
                    counts.parse_failed += 1
                    return
                }
                counts.sessions_checked += 1
                let finished = Self.check(session, label: label,
                                          deadline: sessionStart.addingTimeInterval(Self.perSessionSeconds),
                                          counts: &counts, report: &report)
                if !finished { counts.timeouts += 1 }
                SessionTranscriptBuilder._testResetCoalesceCache()
            }
            if n % 25 == 24 {
                counts.seconds = Date().timeIntervalSince(started)
                report.sources[source.rawValue] = counts
                try save(report)
            }
        }
        counts.seconds = Date().timeIntervalSince(started)
        report.sources[source.rawValue] = counts
    }

    // MARK: - Per session

    /// False when the per-session time cap stopped the check.
    private static func check(_ session: Session, label: String, deadline: Date,
                              counts: inout SourceCounts, report: inout Report) -> Bool {
        let source = session.source
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let index = ToolInvocationIndex.build(blocks: blocks, source: source)
        if !index.invocations.isEmpty { counts.sessions_with_tools += 1 }

        func record(_ finding: Finding) {
            counts.violations[finding.kind, default: 0] += 1
            counts.families[finding.tool, default: FamilyCounts()].violations[finding.kind, default: 0] += 1
            report.violation_totals[finding.kind, default: 0] += 1
            let listed = report.violations.lazy.filter { $0.kind == finding.kind }.count
            guard listed < listedPerClass else { return }
            let invariant = Int(finding.kind.prefix { $0.isNumber }) ?? 0
            report.violations.append(Violation(source: source.rawValue, session: label, block: finding.block,
                                               tool: finding.tool, invariant: invariant, kind: finding.kind,
                                               hint: finding.hint))
        }

        for finding in pairingFindings(blocks, index: index) { record(finding) }

        let appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        for ref in index.invocations {
            if Date() > deadline { return false }
            let invocation = ToolInvocationBuilder.build(ref, blocks: blocks, index: index, source: source, duration: nil)
            let rendered = ToolDetailRenderer.render(invocation, fontSize: fontSize, width: width,
                                                     folds: openFolds(invocation), appearance: appearance)
            let tool = familyKey(invocation.displayToolName)

            counts.invocations += 1
            counts.actions += invocation.actions.count
            report.totals["invocations", default: 0] += 1
            report.totals["actions", default: 0] += invocation.actions.count
            var family = counts.families[tool] ?? FamilyCounts()
            family.invocations += 1
            family.actions += invocation.actions.count
            if ref.callBlockIndex == nil { family.orphan_outputs += 1 }
            family.structured_actions += invocation.actions.filter { $0.category == .structured }.count
            if invocation.displayToolName.isEmpty { family.unnamed_actions += invocation.actions.count }
            let panes = invocation.actions.compactMap(\.output) + [invocation.scriptOutput].compactMap { $0 }
            family.json_panes_with_escapes += panes.filter {
                ($0.shape == .json || $0.shape == .jsonLines) && escapeCounts($0.text) != [0, 0, 0]
            }.count
            counts.families[tool] = family

            var findings: [(kind: String, hint: String)] = []
            findings += escapeFindings(invocation, rendered: rendered, ref: ref, blocks: blocks)
            findings += contentItemFindings(invocation, rendered: rendered)
            findings += fallbackLabelFindings(invocation, ref: ref)
            findings += budgetFindings(invocation)
            findings += ciphertextFindings(invocation, rendered: rendered)
            for finding in findings {
                record(Finding(kind: finding.kind, block: ref.id, tool: tool, hint: finding.hint))
            }
        }
        return true
    }

    /// Every fold open: Show all, every long line opened, full command (spec "all folds open").
    static func openFolds(_ invocation: ToolInvocation) -> [Int: FoldState] {
        var folds: [Int: FoldState] = [:]
        for (index, action) in invocation.actions.enumerated() {
            folds[index] = FoldState(showAll: true, openedLongLines: allLines(action.output?.text), commandShowAll: true)
        }
        folds[invocation.actions.count] = FoldState(showAll: true, openedLongLines: allLines(invocation.scriptOutput?.text),
                                                    commandShowAll: true)
        return folds
    }

    private static func allLines(_ text: String?) -> Set<Int> {
        guard let text, !text.isEmpty else { return [] }
        return Set(0..<min(lineBounds(text).count, ToolTextBudget.showAllLineCap + 1))
    }

    /// Tool family: the invocation's display name, or a placeholder when it is not an identifier.
    static func familyKey(_ name: String) -> String {
        if name.isEmpty { return "(unnamed)" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.:/@ ›"))
        guard name.count <= 80, name.unicodeScalars.allSatisfy(allowed.contains) else { return "(non-identifier name)" }
        return name
    }

    // MARK: - Invariant 1: escapes

    static let escapeNames = ["\\n", "\\\"", "\\/"]

    /// Counts of the two-character sequences `\n`, `\"` and `\/`, in that order: every backslash
    /// followed by `n`, `"` or `/`. A doubled backslash is not treated as one escaped backslash:
    /// a shell or JavaScript string `'\\n'` reaches the command display as `'\n'`, and both count once.
    static func escapeCounts(_ text: String) -> [Int] {
        var counts = [0, 0, 0]
        var text = text
        text.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return }
            let n = bytes.count
            var i = 0
            while i + 1 < n {
                guard let hit = memchr(base + i, 0x5C, n - i) else { break }
                i = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                guard i + 1 < n else { break }
                switch base[i + 1] {
                case 0x6E: counts[0] += 1
                case 0x22: counts[1] += 1
                case 0x2F: counts[2] += 1
                default: break
                }
                i += 1
            }
        }
        return counts
    }

    private static func add(_ a: inout [Int], _ b: [Int]) {
        for k in a.indices { a[k] += b[k] }
    }

    private static func isPollVerb(_ verbKey: String) -> Bool {
        verbKey == ToolVerb.polled || verbKey == ToolVerb.sentInput
    }

    /// A text the model presents as JSON by design: pretty JSON (§6.4 step 3), JSON lines (step 4),
    /// or whole-string JSON kept as text above the pretty-print limit.
    private static func isJSONPresentation(_ decoded: DecodedText) -> Bool {
        switch decoded.shape {
        case .json, .jsonLines: return true
        case .plain:
            guard let first = decoded.text.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
                  let data = decoded.text.data(using: .utf8) else { return false }
            return (try? JSONSerialization.jsonObject(with: data)) != nil
        default: return false
        }
    }

    private static func escapeFindings(_ invocation: ToolInvocation, rendered: RenderedToolBody,
                                       ref: ToolInvocationRef, blocks: [Block]) -> [(kind: String, hint: String)] {
        let r = escapeCounts(rendered.attributed.string)
        var model = [0, 0, 0]      // every L2 text the renderer draws
        var plainParts = [0, 0, 0] // the parts that are not JSON presentations
        var labels: [[Int]] = []
        func both(_ text: String) {
            let c = escapeCounts(text)
            add(&model, c)
            add(&plainParts, c)
        }
        for action in invocation.actions {
            for item in action.context { both(item.value) }
            if let command = action.command { both(command) }
            if let heredoc = action.heredoc?.text { both(heredoc) }
            for field in action.inputFields {
                add(&model, escapeCounts(field.key))
                if case .string(let value) = field.value {
                    both(value)
                } else {
                    add(&model, escapeCounts(ToolInvocationBuilder.plainValue(field.value)))
                }
            }
            if let output = action.output, !output.text.isEmpty {
                let c = escapeCounts(output.text)
                add(&model, c)
                if c != [0, 0, 0], !isJSONPresentation(output) { add(&plainParts, c) }
            }
            for chip in ToolDetailRenderer.footerChipTexts(of: action, in: invocation) { both(chip) }
            if !isPollVerb(action.verbKey) {
                labels.append(escapeCounts(action.object + "\n" + (action.objectDetail ?? "")))
            }
        }
        if let script = invocation.scriptOutput, !script.text.isEmpty {
            let c = escapeCounts(script.text)
            add(&model, c)
            if c != [0, 0, 0], !isJSONPresentation(script) { add(&plainParts, c) }
        }

        var findings: [(kind: String, hint: String)] = []
        for k in 0..<3 where r[k] > model[k] {
            findings.append(("1.render", "\(escapeNames[k]) rendered=\(r[k]) model=\(model[k])"))
        }
        let labelMax = (0..<3).map { k in labels.map { $0[k] }.max() ?? 0 }
        guard plainParts.contains(where: { $0 > 0 }) || labelMax.contains(where: { $0 > 0 }) else { return findings }
        let content = contentEscapeCounts(ref, blocks: blocks)
        for k in 0..<3 where plainParts[k] > content[k] {
            findings.append(("1.decode", "\(escapeNames[k]) text_parts=\(plainParts[k]) content=\(content[k])"))
        }
        for k in 0..<3 where labelMax[k] > content[k] {
            findings.append(("1.label", "\(escapeNames[k]) object=\(labelMax[k]) content=\(content[k])"))
        }
        return findings
    }

    /// Escapes in the invocation's content: what the agent and its tools wrote, with only the log's
    /// own encoding layers taken off (spec §6.4 steps 1–3, §7):
    /// - the call input's JSON object, its values as written, except that a value which is a JSON
    ///   string literal is unwrapped once (Antigravity double-encodes every argument);
    /// - an output's content items, as a structured value or as JSON text;
    /// - a JSON string literal around an output text, up to 3 deep;
    /// - Codex code-mode chunk records (`{"chunk_id"…}`): their `output`.
    /// A whole-string JSON object or array that is not content items stays as written: the decoders
    /// pretty-print it (a presentation), and the escapes it holds are content. So are the escapes in
    /// a shell or JavaScript string (`printf '\\n'`), which the command display unquotes.
    static func contentEscapeCounts(_ ref: ToolInvocationRef, blocks: [Block]) -> [Int] {
        var total = [0, 0, 0]
        func sidecar(_ block: Block) {
            for text in [block.toolSidecar?.stdout, block.toolSidecar?.stderr] {
                if let text { add(&total, outputTextContent(text, depth: 0)) }
            }
            if let label = block.toolSidecar?.agentLabel { add(&total, escapeCounts(label)) }
        }
        if let call = ref.callBlockIndex, blocks.indices.contains(call) {
            if let input = blocks[call].toolInput { add(&total, inputContent(input)) }
            sidecar(blocks[call])
        }
        for position in ref.outputBlockIndices where blocks.indices.contains(position) {
            let block = blocks[position]
            if let value = block.toolOutputValue {
                add(&total, outputValueContent(value, depth: 0))
            } else {
                add(&total, outputTextContent(block.text, depth: 0))
            }
            sidecar(block)
        }
        return total
    }

    private static func parsedJSON(_ text: String) -> Any? {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" || first == "\"",
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func inputContent(_ input: String) -> [Int] {
        guard let parsed = parsedJSON(input) else { return escapeCounts(input) }
        if let inner = parsed as? String { return escapeCounts(inner) }
        guard case .object(let object)? = ToolPayloadValue(jsonObject: parsed) else { return escapeCounts(input) }
        var total = [0, 0, 0]
        for (key, value) in object {
            add(&total, escapeCounts(key))
            if case .string(let s) = value, s.hasPrefix("\""), let inner = parsedJSON(s) as? String {
                add(&total, escapeCounts(inner))
            } else {
                add(&total, leavesAsWritten(value))
            }
        }
        return total
    }

    /// Content items: an array of them, or one item object (the decoders accept both).
    static func contentItems(_ value: ToolPayloadValue) -> [ToolJSON.ContentItemPart]? {
        if let items = ToolJSON.contentItemParts(value) { return items }
        if case .object = value { return ToolJSON.contentItemParts(.array([value])) }
        return nil
    }

    private static func outputValueContent(_ value: ToolPayloadValue, depth: Int) -> [Int] {
        if let items = contentItems(value) {
            var total = [0, 0, 0]
            for case .text(let text) in items { add(&total, outputTextContent(text, depth: depth + 1)) }
            return total
        }
        if case .string(let s) = value { return outputTextContent(s, depth: depth) }
        return leavesAsWritten(value)
    }

    private static func outputTextContent(_ text: String, depth: Int) -> [Int] {
        if depth < ToolTextDecoding.maxJSONStringDepth, let parsed = parsedJSON(text) {
            if let inner = parsed as? String { return outputTextContent(inner, depth: depth + 1) }
            if let value = ToolPayloadValue(jsonObject: parsed), contentItems(value) != nil {
                return outputValueContent(value, depth: depth + 1)
            }
        }
        // Codex code-mode chunk records inside an item's text (`CodexExecOutput`).
        let marker = "{\"chunk_id\""
        if depth < ToolTextDecoding.maxJSONStringDepth, text.contains(marker) {
            var total = [0, 0, 0]
            let pieces = text.components(separatedBy: marker)
            add(&total, escapeCounts(pieces[0]))
            for piece in pieces.dropFirst() {
                let record = marker + piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = record.data(using: .utf8),
                   let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if let output = parsed["output"] as? String { add(&total, outputTextContent(output, depth: depth + 1)) }
                } else {
                    add(&total, escapeCounts(piece))
                }
            }
            return total
        }
        return escapeCounts(text)
    }

    private static func leavesAsWritten(_ value: ToolPayloadValue) -> [Int] {
        switch value {
        case .string(let s):
            return escapeCounts(s)
        case .array(let items):
            var total = [0, 0, 0]
            for item in items { add(&total, leavesAsWritten(item)) }
            return total
        case .object(let object):
            var total = [0, 0, 0]
            for (key, item) in object {
                add(&total, escapeCounts(key))
                add(&total, leavesAsWritten(item))
            }
            return total
        case .number, .bool, .null:
            return [0, 0, 0]
        }
    }

    // MARK: - Invariant 2: content-item bodies

    /// Spec §10.2 prefixes, compared with whitespace removed (pretty JSON indents them).
    private static let contentItemPrefixes = ["[{\"type\"", "{\"text\""]

    /// A pane the decoders left as JSON that is content items (pretty-printing sorts `text` before
    /// `type`, so the literal prefixes miss it): the text parses to an item array or one item object.
    private static func isContentItemJSON(_ decoded: DecodedText) -> Bool {
        guard decoded.shape == .json || decoded.shape == .plain,
              let first = decoded.text.first(where: { !$0.isWhitespace }), first == "[" || first == "{",
              decoded.text.utf8.count <= ToolTextDecoding.prettyJSONMaxBytes,
              let data = decoded.text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let value = ToolPayloadValue(jsonObject: parsed) else { return false }
        return contentItems(value) != nil
    }

    private static func contentItemFindings(_ invocation: ToolInvocation,
                                            rendered: RenderedToolBody) -> [(kind: String, hint: String)] {
        let string = rendered.attributed.string as NSString
        func renderedStart(actionIndex: Int, sourceLocation: Int) -> String? {
            guard let entry = rendered.sourceMap.first(where: {
                $0.actionIndex == actionIndex && $0.source.location == sourceLocation
            }) else { return nil }
            let length = min(80, string.length - entry.rendered.location)
            return length > 0 ? string.substring(with: NSRange(location: entry.rendered.location, length: length)) : nil
        }
        func startsAsContentItems(_ text: String) -> Bool {
            let squeezed = String(text.prefix(80).filter { !$0.isWhitespace })
            return contentItemPrefixes.contains { squeezed.hasPrefix($0) }
        }
        var findings: [(kind: String, hint: String)] = []
        for (index, action) in invocation.actions.enumerated() {
            guard let decoded = action.output, !decoded.text.isEmpty else { continue }
            let output = decoded.text
            let location = action.plainText.utf16.count - output.utf16.count
            let shown = renderedStart(actionIndex: index, sourceLocation: location) ?? output
            if startsAsContentItems(shown) || startsAsContentItems(output) {
                findings.append(("2", "output pane of action \(index) starts as content items"))
            } else if isContentItemJSON(decoded) {
                findings.append(("2", "output pane of action \(index) is content items shown as JSON"))
            }
        }
        if let decoded = invocation.scriptOutput, !decoded.text.isEmpty {
            let script = decoded.text
            let shown = renderedStart(actionIndex: invocation.actions.count, sourceLocation: 0) ?? script
            if startsAsContentItems(shown) || startsAsContentItems(script) {
                findings.append(("2", "script output pane starts as content items"))
            } else if isContentItemJSON(decoded) {
                findings.append(("2", "script output pane is content items shown as JSON"))
            }
        }
        return findings
    }

    // MARK: - Invariant 3: fallback label

    private static func fallbackLabelFindings(_ invocation: ToolInvocation,
                                              ref: ToolInvocationRef) -> [(kind: String, hint: String)] {
        guard ref.callBlockIndex != nil else { return [] }
        var findings: [(kind: String, hint: String)] = []
        for (index, action) in invocation.actions.enumerated() {
            let line = [ToolVerb.text(action.verbKey), action.object, action.objectDetail ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            if action.verbKey == ToolVerb.output {
                findings.append(("3", "action \(index) of a call has the Output fallback verb"))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                findings.append(("3", "action \(index) of a call has an empty label"))
            }
        }
        return findings
    }

    // MARK: - Invariant 4: pairing by call id

    private static func pairingFindings(_ blocks: [Block], index: ToolInvocationIndex) -> [Finding] {
        var callCount: [String: Int] = [:]
        var invocationsByID: [String: [Int]] = [:]
        var firstBlockByID: [String: Int] = [:]
        var findings: [Finding] = []
        for block in blocks {
            guard let id = block.toolCallID else { continue }
            switch block.kind {
            case .toolCall: callCount[id, default: 0] += 1
            case .toolOut, .error: break
            default: continue
            }
            if firstBlockByID[id] == nil { firstBlockByID[id] = block.globalBlockIndex }
            guard let invocation = index.invocationIDByBlock[block.globalBlockIndex] else {
                findings.append(Finding(kind: "4", block: block.globalBlockIndex, tool: familyKey(block.toolName ?? ""),
                                        hint: "block with a call id is in no invocation"))
                continue
            }
            if !(invocationsByID[id]?.contains(invocation) ?? false) { invocationsByID[id, default: []].append(invocation) }
        }
        for (id, invocations) in invocationsByID {
            let calls = callCount[id] ?? 0
            guard invocations.count > max(1, calls) else { continue }
            let first = firstBlockByID[id] ?? invocations[0]
            findings.append(Finding(kind: "4", block: first, tool: familyKey(blocks[first].toolName ?? ""),
                                    hint: "call id in \(invocations.count) invocations for \(calls) calls"))
        }
        for ref in index.invocations {
            var ids = Set<String>()
            if let call = ref.callBlockIndex, let id = blocks[call].toolCallID { ids.insert(id) }
            for output in ref.outputBlockIndices { if let id = blocks[output].toolCallID { ids.insert(id) } }
            if ids.count > 1 {
                let name = ref.callBlockIndex.flatMap { blocks[$0].toolName } ?? ""
                findings.append(Finding(kind: "4", block: ref.id, tool: familyKey(name),
                                        hint: "one invocation joins \(ids.count) call ids"))
            }
        }
        return findings
    }

    // MARK: - Invariant 5: folded budgets

    /// Byte bounds of the logical lines, split on "\n" like `ToolTextBudget` (one trailing "\n" adds
    /// no line).
    static func lineBounds(_ text: String) -> [(start: Int, end: Int)] {
        var text = text
        return text.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return [] }
            var out: [(start: Int, end: Int)] = []
            let n = bytes.count
            var pos = 0
            while pos < n {
                var end = n
                if let hit = memchr(base + pos, 0x0A, n - pos) { end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) }
                out.append((pos, end))
                pos = end + 1
            }
            return out
        }
    }

    /// Visual lines a folded pane shows: each line of a `.lines` range at its own wrapped height,
    /// measured here with `visualWidth` rather than taken from the budget, and each cut line at 4.
    static func shownVisualLines(_ text: String, folded: FoldedText, columns: Int) -> Int {
        let bounds = lineBounds(text)
        var text = text
        return text.withUTF8 { bytes in
            var total = 0
            for segment in folded.segments {
                switch segment {
                case .lines(let range):
                    for i in range where i < bounds.count {
                        let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[bounds[i].start..<bounds[i].end]),
                                          as: UTF8.self)
                        total += max(1, (ToolTextBudget.visualWidth(of: Substring(line)) + columns - 1) / max(1, columns))
                    }
                case .longLineCut:
                    total += ToolTextBudget.longLineVisualLines
                case .fold:
                    break
                }
            }
            return total
        }
    }

    /// Pane columns as `ToolDetailRenderer` computes them (its pane padding is 9 pt).
    private struct Columns {
        let mono = NSFont.monospacedSystemFont(ofSize: max(1, TranscriptToolCorpusCheckTests.fontSize - 0.5), weight: .regular)
        let advance: CGFloat
        let pad: CGFloat = 9
        let width = TranscriptToolCorpusCheckTests.width

        init() {
            let measured = ("0" as NSString).size(withAttributes: [.font: mono]).width
            advance = measured > 0 ? measured : mono.pointSize * 0.6
        }

        var output: Int { ToolTextBudget.columns(width: width - 2 * pad, font: mono) }
        var command: Int { ToolTextBudget.columns(width: width - (pad + 2 * advance) - pad, font: mono) }
        func gutter(maxNumber: Int) -> Int {
            let digits = max(2, String(max(0, maxNumber)).count)
            let textStart = pad + CGFloat(digits) * advance + 2 * advance
            return ToolTextBudget.columns(width: width - textStart - pad, font: mono)
        }
        func fieldValue(keys: [String]) -> Int {
            let keyColumns = min(20, keys.map { ToolTextBudget.visualWidth(of: Substring($0)) }.max() ?? 0)
            return ToolTextBudget.columns(width: width - (pad + CGFloat(keyColumns + 2) * advance) - pad, font: mono)
        }
    }

    private static let columns = Columns()

    private static func budgetFindings(_ invocation: ToolInvocation) -> [(kind: String, hint: String)] {
        var findings: [(kind: String, hint: String)] = []
        func checkCommand(_ text: String, columns: Int, pane: String) {
            guard !text.isEmpty else { return }
            let folded = ToolTextBudget.foldCommand(text, columns: columns, state: FoldState())
            let shown = shownVisualLines(text, folded: folded, columns: columns)
            if shown > ToolTextBudget.commandLines {
                findings.append(("5", "\(pane) pane shows \(shown) visual lines, budget \(ToolTextBudget.commandLines)"))
            }
        }
        func checkOutput(_ decoded: DecodedText, isError: Bool, pane: String) {
            guard !decoded.text.isEmpty else { return }
            let paneColumns: Int
            switch decoded.shape {
            case .image, .binary: return
            case .lineNumbered(let numbers): paneColumns = columns.gutter(maxNumber: numbers.compactMap { $0 }.max() ?? 0)
            default: paneColumns = columns.output
            }
            let folded = ToolTextBudget.fold(decoded.text, columns: paneColumns, isError: isError, state: FoldState())
            let shown = shownVisualLines(decoded.text, folded: folded, columns: paneColumns)
            let budget = isError ? ToolTextBudget.errorTailLines : ToolTextBudget.headLines + ToolTextBudget.tailLines
            if shown > budget {
                findings.append(("5", "\(pane) pane shows \(shown) visual lines, budget \(budget)"))
            }
        }
        for (index, action) in invocation.actions.enumerated() {
            if let command = action.command { checkCommand(command, columns: columns.command, pane: "command \(index)") }
            if let heredoc = action.heredoc?.text {
                let lines = heredoc.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
                checkCommand(heredoc, columns: columns.gutter(maxNumber: lines), pane: "heredoc \(index)")
            }
            if action.command == nil {
                let valueColumns = columns.fieldValue(keys: action.inputFields.map(\.key))
                for field in action.inputFields {
                    if case .string(let value) = field.value { checkCommand(value, columns: valueColumns, pane: "field \(index)") }
                }
            }
            if let output = action.output { checkOutput(output, isError: isFailure(action.status), pane: "output \(index)") }
        }
        if let script = invocation.scriptOutput {
            checkOutput(script, isError: isFailure(invocation.ref.status), pane: "script output")
        }
        return findings
    }

    private static func isFailure(_ status: ToolStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    // MARK: - Invariant 6: ciphertext

    /// Length of the first `gAAAAA` token longer than 40 characters, or nil.
    static func ciphertextLength(in text: String) -> Int? {
        guard text.contains("gAAAAA") else { return nil }
        let units = Array(text.utf16)
        let prefix = Array("gAAAAA".utf16)
        func isTokenUnit(_ u: UInt16) -> Bool {
            (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x2D || u == 0x5F || u == 0x3D
        }
        var i = 0
        while i + prefix.count <= units.count {
            if units[i] == prefix[0], Array(units[i..<(i + prefix.count)]) == prefix, i == 0 || !isTokenUnit(units[i - 1]) {
                var end = i + prefix.count
                while end < units.count, isTokenUnit(units[end]) { end += 1 }
                if end - i > 40 { return end - i }
                i = end
                continue
            }
            i += 1
        }
        return nil
    }

    private static func ciphertextFindings(_ invocation: ToolInvocation,
                                           rendered: RenderedToolBody) -> [(kind: String, hint: String)] {
        var findings: [(kind: String, hint: String)] = []
        if let length = ciphertextLength(in: invocation.plainText) {
            findings.append(("6", "plainText holds a gAAAAA token of \(length) chars"))
        }
        if let length = ciphertextLength(in: rendered.attributed.string) {
            findings.append(("6", "rendered body holds a gAAAAA token of \(length) chars"))
        }
        for (index, action) in invocation.actions.enumerated() {
            if let length = ciphertextLength(in: action.object + " " + (action.objectDetail ?? "")) {
                findings.append(("6", "object of action \(index) holds a gAAAAA token of \(length) chars"))
            }
        }
        return findings
    }

    // MARK: - Self-checks of the instruments (synthetic, always run)

    func testEscapeCountsCountEveryBackslashPair() {
        XCTAssertEqual(Self.escapeCounts(#"a\nb \"c\" \/d"#), [1, 2, 1])
        XCTAssertEqual(Self.escapeCounts(#"a\\nb"#), [1, 0, 0])
        XCTAssertEqual(Self.escapeCounts("plain\ntext"), [0, 0, 0])
        XCTAssertEqual(Self.escapeCounts(#"\"#), [0, 0, 0])
    }

    func testContentEscapesDecodeContentItemsAndChunkRecords() {
        func output(_ value: ToolPayloadValue?, text: String) -> [Block] {
            var block = Block(kind: .toolOut, text: text, timestamp: nil, messageID: nil, toolName: "exec",
                              isDelta: false, toolInput: nil, isErrorOutput: false, eventID: "e", rawJSON: "")
            block.globalBlockIndex = 0
            block.toolOutputValue = value
            return [block]
        }
        let ref = ToolInvocationRef(id: 0, callBlockIndex: nil, outputBlockIndices: [0], status: .success)
        // A content-item array whose text holds a chunk record with an escaped newline: no real escape.
        let chunk = "Script completed\nOutput:\n" + #"{"chunk_id":"a","output":"line1\nline2"}"#
        let items = ToolPayloadValue.array([.object(["type": .string("input_text"), "text": .string(chunk)])])
        XCTAssertEqual(Self.contentEscapeCounts(ref, blocks: output(items, text: "")), [0, 0, 0])
        // Text that literally holds a backslash-n keeps it.
        XCTAssertEqual(Self.contentEscapeCounts(ref, blocks: output(nil, text: #"printf "a\n""#)), [1, 0, 0])
        // A JSON string literal around the text is a log layer; content items as JSON text are too.
        XCTAssertEqual(Self.contentEscapeCounts(ref, blocks: output(nil, text: #""x\ny \"q\"""#)), [0, 0, 0])
        XCTAssertEqual(Self.contentEscapeCounts(ref, blocks: output(nil, text: #"[{"type":"text","text":"x\ny"}]"#)), [0, 0, 0])
        // A whole-string JSON object stays as written: pretty-printing it is a presentation.
        XCTAssertEqual(Self.contentEscapeCounts(ref, blocks: output(nil, text: #"{"a":"x\ny","p":"\/tmp"}"#)), [1, 0, 1])
    }

    /// Positive control: an output whose model text kept the JSON escapes of its raw string is a
    /// `1.decode` finding; the same text with the content decoded is none.
    func testEscapeCheckFlagsUndecodedOutputOnly() {
        var block = Block(kind: .toolOut, text: #""line1\nline2""#, timestamp: nil, messageID: nil, toolName: "Bash",
                          isDelta: false, toolInput: nil, isErrorOutput: false, eventID: "e", rawJSON: "")
        block.globalBlockIndex = 0
        let ref = ToolInvocationRef(id: 0, callBlockIndex: nil, outputBlockIndices: [0], status: .success)
        func invocation(_ text: String) -> ToolInvocation {
            let output = DecodedText(text: text, sourceMap: [], shape: .plain)
            let action = ToolAction(category: .shell, verbKey: ToolVerb.output, object: "Bash", objectIsAgentLabel: false,
                                    objectDetail: nil, context: [], command: nil, exactCommand: nil, heredoc: nil,
                                    inputFields: [], output: output, facts: [], hiddenNotes: [], status: .success,
                                    plainText: "Output Bash\n" + text)
            return ToolInvocation(ref: ref, displayToolName: "Bash", actions: [action], scriptSource: nil,
                                  scriptOutput: nil, durationSeconds: nil)
        }
        for (text, expected) in [(#"line1\nline2"#, ["1.decode"]), ("line1\nline2", [])] {
            let model = invocation(text)
            let rendered = ToolDetailRenderer.render(model, fontSize: Self.fontSize, width: Self.width,
                                                     folds: Self.openFolds(model), appearance: NSAppearance(named: .aqua)!)
            XCTAssertEqual(Self.escapeFindings(model, rendered: rendered, ref: ref, blocks: [block]).map(\.kind), expected)
        }
    }

    /// Positive controls for invariants 2, 3 and 4: each check fires on a synthetic case that breaks
    /// it and stays quiet on the matching good case.
    func testContentItemFallbackLabelAndPairingChecksFire() {
        typealias F = TranscriptTestFixtures
        let ref = ToolInvocationRef(id: 1, callBlockIndex: 1, outputBlockIndices: [2], status: .success)
        func model(verbKey: String, output: DecodedText) -> ToolInvocation {
            let action = ToolAction(category: .structured, verbKey: verbKey, object: "x", objectIsAgentLabel: false,
                                    objectDetail: nil, context: [], command: nil, exactCommand: nil, heredoc: nil,
                                    inputFields: [], output: output, facts: [], hiddenNotes: [], status: .success,
                                    plainText: ToolVerb.text(verbKey) + " x\n" + output.text)
            return ToolInvocation(ref: ref, displayToolName: "tool", actions: [action], scriptSource: nil,
                                  scriptOutput: nil, durationSeconds: nil)
        }
        func render(_ invocation: ToolInvocation) -> RenderedToolBody {
            ToolDetailRenderer.render(invocation, fontSize: Self.fontSize, width: Self.width,
                                      folds: Self.openFolds(invocation), appearance: NSAppearance(named: .aqua)!)
        }
        // 2: content items shown as pretty JSON (sorted keys put "text" first), and the spec prefix.
        let items = DecodedText(text: "[\n  {\n    \"text\" : \"a\",\n    \"type\" : \"text\"\n  }\n]", sourceMap: [], shape: .json)
        let prefixed = DecodedText(text: #"{"text":"a"}"#, sourceMap: [], shape: .plain)
        let links = DecodedText(text: "[\n  {\n    \"text\" : \"a\",\n    \"url\" : \"b\"\n  }\n]", sourceMap: [], shape: .json)
        for (output, expected) in [(items, ["2"]), (prefixed, ["2"]), (links, [])] {
            let invocation = model(verbKey: "tool", output: output)
            XCTAssertEqual(Self.contentItemFindings(invocation, rendered: render(invocation)).map(\.kind), expected)
        }
        // 3: a call whose action reads the "Output" fallback verb.
        let plain = DecodedText(text: "ok", sourceMap: [], shape: .plain)
        XCTAssertEqual(Self.fallbackLabelFindings(model(verbKey: ToolVerb.output, output: plain), ref: ref).map(\.kind), ["3"])
        XCTAssertEqual(Self.fallbackLabelFindings(model(verbKey: "tool", output: plain), ref: ref).map(\.kind), [])
        // 4: an output logged before its call stays apart from it; a repeated id pairing 1:1 is fine.
        let early = F.sequence([F.block(.user, text: "go"), F.block(.toolOut, id: "a", text: "x"),
                                F.block(.toolCall, id: "a", toolInput: "{}")])
        XCTAssertEqual(Self.pairingFindings(early, index: ToolInvocationIndex.build(blocks: early, source: .claude)).map(\.kind),
                       ["4"])
        let repeated = F.sequence([F.block(.user, text: "go"), F.block(.toolCall, id: "a", toolInput: "{}"),
                                   F.block(.toolOut, id: "a", text: "x"), F.block(.toolCall, id: "a", toolInput: "{}"),
                                   F.block(.toolOut, id: "a", text: "y")])
        XCTAssertEqual(Self.pairingFindings(repeated, index: ToolInvocationIndex.build(blocks: repeated, source: .claude)).count, 0)
    }

    func testFoldedBudgetMeasureCountsCutLinesAsFour() {
        let long = String(repeating: "x", count: 1_000)
        let text = (0..<40).map { $0 == 3 ? long : "line \($0)" }.joined(separator: "\n")
        let folded = ToolTextBudget.fold(text, columns: 80, isError: false, state: FoldState())
        XCTAssertLessThanOrEqual(Self.shownVisualLines(text, folded: folded, columns: 80),
                                 ToolTextBudget.headLines + ToolTextBudget.tailLines)
        let all = FoldedText(segments: [.lines(0..<40)], hitShowAllCap: false)
        XCTAssertEqual(Self.shownVisualLines(text, folded: all, columns: 80), 39 + 13)
    }

    func testCiphertextLengthNeedsMoreThanFortyCharacters() {
        let token = "gAAAAA" + String(repeating: "b", count: 40)
        XCTAssertEqual(Self.ciphertextLength(in: "x " + token + " y"), 46)
        XCTAssertNil(Self.ciphertextLength(in: "gAAAAAshort"))
        XCTAssertNil(Self.ciphertextLength(in: "xgAAAAA" + String(repeating: "b", count: 40)))
    }
}
