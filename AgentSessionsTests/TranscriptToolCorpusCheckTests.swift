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
/// It also fails per source (`coverageFailures`): a source with sessions on disk that had none
/// checked, or that lost more than 5% of its sample to timeouts and the time budget.
/// Report only, per tool family: structured (fallback renderer) and unnamed actions, orphan
/// outputs, and JSON panes whose string values show escapes. Parse failures are report-only too.
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
        /// `coverageFailures`: per-source gate messages (source names and counts only).
        var coverage_failures: [String] = []
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
        report.coverage_failures = Self.coverageFailures(report.sources)
        try save()

        // Counts only: an assertion message never carries session content.
        let failing = report.violation_totals.filter { Self.waived[$0.key] == nil && $0.value > 0 }
        XCTAssertTrue(failing.isEmpty, "tool corpus violations: \(failing.sorted { $0.key < $1.key })")
        XCTAssertGreaterThan(report.totals["invocations"] ?? 0, 0)
        XCTAssertTrue(report.not_covered.isEmpty, "sources without a discovery seam: \(report.not_covered.keys.sorted())")
        XCTAssertTrue(report.coverage_failures.isEmpty, "per-source coverage: \(report.coverage_failures)")
    }

    /// Most of a source's sample that may time out or stay unreached before the check fails.
    static let maxLostFraction = 0.05

    /// Per-source gate, so one source whose discovery or parser breaks cannot hide behind the others.
    /// For every source with sessions on disk: at least one session is checked, and timeouts plus
    /// sessions the time budget did not reach stay within 5% of its sample
    /// (`min(discovered, maxSessionsPerSource)`). `parse_failed` stays report-only: old-format files
    /// are legitimate. One message per failure, with the source name and counts only.
    static func coverageFailures(_ sources: [String: SourceCounts]) -> [String] {
        var failures: [String] = []
        for (name, counts) in sources.sorted(by: { $0.key < $1.key }) where counts.discovered > 0 {
            let sample = min(counts.discovered, maxSessionsPerSource)
            if counts.sessions_checked == 0 {
                failures.append("\(name): 0 of \(sample) sessions checked")
            }
            let lost = counts.timeouts + counts.not_reached
            if Double(lost) > Double(sample) * maxLostFraction {
                failures.append("\(name): \(lost) of \(sample) sessions timed out or not reached")
            }
        }
        return failures
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

    /// The per-source gate flags a source with sessions on disk but none checked, and one that lost
    /// more than 5% of its sample to timeouts and the time budget; it passes healthy sources, sources
    /// with nothing on disk, and parse failures (report-only).
    func testCoverageGateFlagsZeroCheckedAndLostSourcesOnly() {
        func counts(discovered: Int, checked: Int, parseFailed: Int = 0, timeouts: Int = 0,
                    notReached: Int = 0) -> SourceCounts {
            var c = SourceCounts()
            c.discovered = discovered
            c.sessions_checked = checked
            c.parse_failed = parseFailed
            c.timeouts = timeouts
            c.not_reached = notReached
            return c
        }
        let sources: [String: SourceCounts] = [
            "zero": counts(discovered: 12, checked: 0, parseFailed: 12),
            "lost": counts(discovered: 300, checked: 195, timeouts: 6, notReached: 5),     // 11 of 200
            "edge": counts(discovered: 300, checked: 195, timeouts: 5, notReached: 5),     // 10 of 200: allowed
            "small": counts(discovered: 20, checked: 19, timeouts: 2),                      // 2 of 20
            "parse": counts(discovered: 9, checked: 1, parseFailed: 8),
            "empty": counts(discovered: 0, checked: 0),
        ]
        XCTAssertEqual(Self.coverageFailures(sources), [
            "lost: 11 of 200 sessions timed out or not reached",
            "small: 2 of 20 sessions timed out or not reached",
            "zero: 0 of 12 sessions checked",
        ])
        XCTAssertEqual(Self.coverageFailures(["edge": sources["edge"]!, "parse": sources["parse"]!]), [])
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

// MARK: - Message readability corpus gate

extension TranscriptToolCorpusCheckTests {
    struct MessageFinding: Codable, Equatable {
        var source: String
        var session: String
        var block: Int
        var invariant: String
    }
    struct MessageTimeout: Codable {
        var source: String
        var session: String
        var block = -1
        var invariant: String
        var phase_seconds: [String: Double]
    }
    struct MessageReport: Codable {
        var complete = false
        var sources: [String: SourceCounts] = [:]
        var coverage_failures: [String] = []
        var violations: [MessageFinding] = []
        var violation_totals: [String: Int] = [:]
        var provenance: [String: [String: Int]] = [:]
        var unknown_provenance: [String: [String: Int]] = [:]
        var timeouts: [MessageTimeout] = []
        var rows = 0
    }

    // Independent oracle: original parser facts and source-specific harness signatures, never
    // a second invocation of the presentation classifier. Explicit typed literals win.
    private static func nonhuman(_ block: Block, source: SessionSource, childFirst: Bool) -> Bool {
        if block.rawJSON.utf8.prefix(65_537).count <= 65_536, let data = block.rawJSON.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if source == .claude, raw["type"] as? String == "user" {
                if raw["isCompactSummary"] as? Bool == true || raw["isMeta"] as? Bool == true { return true }
                if let kind = (raw["origin"] as? [String: Any])?["kind"] as? String, kind != "human" { return true }
            }
            if source == .codex {
                let payload = raw["payload"] as? [String: Any] ?? raw
                if payload["type"] as? String == "agent_message" { return true }
                let kinds = originalKinds(block.rawJSON, source: source).map { $0.components(separatedBy: " | ")[0] }
                if !kinds.isEmpty && !kinds.contains("user.text") { return true }
                if kinds.contains("user.text"), kinds.contains(where: { $0 != "user.text" }),
                   (payload["content"] as? [Any])?.count != kinds.count { return true }
            }
        }
        if let origin = block.messageOrigin { return origin != .typed || childFirst }
        if childFirst { return true }
        let text = String(decoding: block.text.utf8.prefix(65_536), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if ToolInvocationIndex.isInterruptNotice(text) { return true }
        let prefixes: [String]
        switch source {
        case .codex: prefixes = ["<environment_context>", "<user_instructions>", "# AGENTS.md instructions for", "<INSTRUCTIONS>", "Message Type:"]
        case .claude: prefixes = ["<task-notification>", "[SYSTEM NOTIFICATION - NOT USER INPUT]", "<side-sessions-event>", "Another Claude session sent a message:", "The coordinator sent a message while you were working:", "<command-name>", "<local-command-caveat>", "Caveat: The messages below were generated", "<local-command-stdout>", "<bash-input>", "<bash-stdout>", "<bash-stderr>"]
        case .hermes: prefixes = ["[SYSTEM: You are running as a scheduled cron job", "[IMPORTANT: You are running as a scheduled cron job", "You just executed tool calls but returned an empty response"]
        case .openclaw: prefixes = ["[OpenClaw heartbeat poll]", "Read HEARTBEAT.md if exists", "[cron:", "Conversation info (untrusted metadata):"]
        default: prefixes = []
        }
        if prefixes.contains(where: text.hasPrefix) { return true }
        // A leading reminder can precede real human text. Only a complete run of
        // reminder elements, with no outside prose, proves a harness-only record.
        guard block.text.utf8.prefix(65_537).count <= 65_536 else { return false }
        var remainder = text
        var sawReminder = false
        while remainder.hasPrefix("<system-reminder>"), let close = remainder.range(of: "</system-reminder>") {
            sawReminder = true
            remainder = String(remainder[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sawReminder && remainder.isEmpty
    }

    private static func messageFindings(blocks: [Block], rows: [BlockRowModel], source: SessionSource,
                                        child: Bool = false, images: Set<Int> = [],
                                        markers: [Int: [String]] = [:]) -> [(Int, String)] {
        var result: [(Int, String)] = []
        var owners: [Int: Int] = [:]
        var prior: (Int, MessagePresentation)?
        let firstUser = blocks.first(where: { $0.kind == .user })?.globalBlockIndex
        for row in rows {
            guard case .message(let block) = row.content else { prior = nil; continue }
            guard let p = block.presentation else { prior = nil; continue }
            let id = block.globalBlockIndex
            let members = row.representedBlockIndices
            for member in members {
                if owners.updateValue(id, forKey: member) != nil { result.append((id, "M5")) }
                guard blocks.indices.contains(member) else { result.append((id, "M5")); continue }
                let original = blocks[member]
                if p.origin == .typed && nonhuman(original, source: source, childFirst: child && member == firstUser) { result.append((id, "M1")) }
                if let other = original.presentation, (other.origin != p.origin || other.body != p.body) { result.append((id, "M5")) }
            }
            let body = p.body.trimmingCharacters(in: .whitespacesAndNewlines)
            func startsTag(_ tag: String) -> Bool {
                guard body.hasPrefix("<" + tag) else { return false }
                let boundary = body.dropFirst(tag.count + 1).first
                return boundary == ">" || boundary == " " || boundary == "\t" || boundary == "\n" || boundary == "\r"
            }
            // Transport recognition is source-specific. A custom tag sharing a prefix is
            // not a transport envelope; original explicit human provenance is authoritative.
            var tags = ["send_user_message_question_reply"]
            var prefixes: [String] = []
            switch source {
            case .cline: tags += ["user_input"]
            case .grok: tags += ["user_query"]
            case .cursor: tags += ["timestamp"]
            case .claude:
                tags += ["command-name", "local-command-stdout", "bash-input", "bash-stdout", "bash-stderr", "system-reminder"]
                prefixes = ["Another Claude session sent a message:", "The coordinator sent a message while you were working:"]
            case .kimi: tags += ["local-command-stdout", "bash-input", "bash-stdout", "bash-stderr"]
            default: break
            }
            if case .peer = p.origin { prefixes.append("Message Type:") }
            if block.messageOrigin != .typed, tags.contains(where: startsTag) || prefixes.contains(where: body.hasPrefix) { result.append((id, "M2")) }
            if case .peer = p.origin, body.contains("gAAAAA") { result.append((id, "M2")) }
            if block.kind == .assistant {
                if body.utf8.prefix(65_537).count <= 65_536 {
                    if let data = body.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { result.append((id, "M3")) }
                } else {
                    let rawPrefix = String(decoding: (block.messageDisplayText ?? block.text).utf8.prefix(65_536), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawIsOversized = (block.messageDisplayText ?? block.text).utf8.prefix(65_537).count > 65_536
                    if body.hasPrefix("{") || (rawIsOversized && rawPrefix.hasPrefix("{")) {
                        let fallback = MessageOriginText.largeStructured + "\n\n```json\n"
                        if !body.hasPrefix(fallback) || !body.hasSuffix("\n```") { result.append((id, "M3")) }
                    }
                }
            }
            switch p.rowStyle {
            case .card: if body.isEmpty && !images.contains(id) { result.append((id, "M4")) }
            case .line: if p.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { result.append((id, "M4")) }
            case .none: result.append((id, "M4"))
            }
            if let low = members.min(), let high = members.max(), low < high {
                for middle in low...high where blocks.indices.contains(middle) {
                    if blocks[middle].kind.isTool || blocks[middle].kind == .error || images.contains(middle) || (middle > low && markers[middle]?.isEmpty == false) { result.append((id, "M5")); break }
                }
            }
            if let (previousID, previous) = prior, previous.origin == p.origin, previous.body == p.body,
               !images.contains(previousID), !images.contains(id), markers[id]?.isEmpty != false {
                let between = (previousID + 1)..<max(previousID + 1, id)
                let barrier = between.contains { blocks.indices.contains($0) && (blocks[$0].kind.isTool || blocks[$0].kind == .error || images.contains($0) || markers[$0]?.isEmpty == false) }
                if !barrier { result.append((id, "M5")) }
            }
            prior = (id, p)
        }
        for block in blocks where !block.kind.isTool && block.kind != .error {
            guard let p = block.presentation, p.origin != .placeholder, p.origin?.isHiddenContext != true else { continue }
            if owners[block.globalBlockIndex] == nil { result.append((block.globalBlockIndex, "M5")) }
        }
        return result
    }

    private static func originalKinds(_ raw: String, source: SessionSource) -> [String] {
        guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if source == .claude { return ((object["origin"] as? [String: Any])?["kind"] as? String).map { [$0] } ?? [] }
        guard source == .codex else { return [] }
        let payload = object["payload"] as? [String: Any] ?? object
        let meta = (payload["internal_chat_message_metadata_passthrough"] ?? object["internal_chat_message_metadata_passthrough"]) as? [String: Any]
        return meta?["content_item_kinds"] as? [String] ?? []
    }
    private static func namedKind(_ raw: String, source: SessionSource) -> Bool {
        if source == .claude { return ["human", "peer", "task-notification"].contains(raw) }
        return raw.components(separatedBy: " | ")[0] == "user.text"
    }
    private static func messageCoverage(_ sources: [String: SourceCounts]) -> [String] {
        var failures = coverageFailures(sources)
        for source in SessionSource.allCases where sources[source.rawValue] == nil { failures.append(source.rawValue + ": missing source") }
        if sources.values.reduce(0, { $0 + $1.sessions_checked }) == 0 { failures.append("zero checked sessions") }
        return failures
    }

    private struct MessageImageAbsenceCache {
        private var stamps: [String: String] = [:]
        func contains(path: String, stamp: String?) -> Bool { stamp != nil && stamps[path] == stamp }
        mutating func record(path: String, before: String?, after: String?, foundImage: Bool, cancelled: Bool, succeeded: Bool) {
            guard let before, before == after, !foundImage, !cancelled, succeeded else { stamps[path] = nil; return }
            stamps[path] = before
        }
        static func stamp(_ url: URL) -> String? {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date,
                  let inode = a[.systemFileNumber] as? NSNumber else { return nil }
            return "\(inode)|\(size)|\(date.timeIntervalSince1970)"
        }
    }

    func testMessageImageAbsenceCacheRequiresCompletedUnchangedNegativeScan() {
        var cache = MessageImageAbsenceCache()
        cache.record(path: "db", before: "a", after: "a", foundImage: false, cancelled: false, succeeded: true)
        XCTAssertTrue(cache.contains(path: "db", stamp: "a"))
        XCTAssertFalse(cache.contains(path: "db", stamp: "b"))
        XCTAssertFalse(cache.contains(path: "other", stamp: "a"))
        for (after, positive, cancelled, succeeded) in [("b", false, false, true), ("a", true, false, true), ("a", false, true, true), ("a", false, false, false)] {
            cache.record(path: "db", before: "a", after: after, foundImage: positive, cancelled: cancelled, succeeded: succeeded)
            XCTAssertFalse(cache.contains(path: "db", stamp: "a"))
        }
        cache.record(path: "db", before: nil, after: nil, foundImage: false, cancelled: false, succeeded: true)
        XCTAssertFalse(cache.contains(path: "db", stamp: nil))
    }

    func testMessageCorpusReadability() throws {
        guard ProcessInfo.processInfo.environment["AS_TOOL_CORPUS_CHECK"] == "1" else { throw XCTSkip("Set AS_TOOL_CORPUS_CHECK=1 for message corpus") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("scripts/probe_scan_output/message_corpus")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report = MessageReport()
        func save() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .atomic)
        }
        let watchdog = Process(), completion = Pipe()
        watchdog.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        watchdog.arguments = [root.appendingPathComponent("scripts/replay_watchdog.py").path, "--seconds", String(Self.watchdogSeconds)]
        watchdog.standardInput = completion; watchdog.standardOutput = FileHandle.nullDevice; watchdog.standardError = FileHandle.nullDevice
        try watchdog.run()
        defer { try? completion.fileHandleForWriting.close(); watchdog.waitUntilExit() }
        fflush(nil)
        let savedOut = dup(STDOUT_FILENO), savedErr = dup(STDERR_FILENO), sink = open("/dev/null", O_WRONLY)
        guard savedOut >= 0, savedErr >= 0, sink >= 0 else { throw XCTSkip("Cannot isolate corpus output") }
        dup2(sink, STDOUT_FILENO); dup2(sink, STDERR_FILENO)
        defer { fflush(nil); dup2(savedOut, STDOUT_FILENO); dup2(savedErr, STDERR_FILENO); close(savedOut); close(savedErr); close(sink) }
        try save()
        var imageAbsence = MessageImageAbsenceCache()
        let start = Date(), large: [SessionSource] = [.claude, .codex]
        for source in SessionSource.allCases.filter({ !large.contains($0) }) + large {
            let remaining = Self.budgetSeconds - Date().timeIntervalSince(start)
            let budget = source == .codex ? remaining : (source == .claude ? remaining / 2 : min(Self.smallSourceSeconds, remaining))
            let sourceStart = Date(), descriptor = SessionSourceRegistry.descriptor(for: source)
            let candidates = Self.candidates(source)
            var counts = SourceCounts(); counts.discovered = candidates.count
            for (n, candidate) in candidates.prefix(Self.maxSessionsPerSource).enumerated() {
                if Date().timeIntervalSince(sourceStart) >= budget { counts.not_reached += 1; continue }
                autoreleasepool {
                    let sessionStart = Date(), session: Session?, label: String
                    switch candidate {
                    case .file(let url, let bytes, _):
                        if bytes > Self.maxFileBytes { counts.skipped_over_50mb += 1; return }
                        label = url.path; session = descriptor.parseFullByPath?(url)
                    case .identity(let url, let id, _): label = "id:" + id; session = descriptor.parseFullByIdentity?(url, id)
                    }
                    guard let session else { counts.parse_failed += 1; return }
                    let deadline = sessionStart.addingTimeInterval(Self.perSessionSeconds)
                    let timeoutsBefore = counts.timeouts
                    var phase = "parse", phaseStarted = sessionStart
                    var phaseSeconds: [String: Double] = [:]
                    func enter(_ next: String) {
                        phaseSeconds[phase, default: 0] += Date().timeIntervalSince(phaseStarted)
                        phase = next; phaseStarted = Date()
                    }
                    defer {
                        phaseSeconds[phase, default: 0] += Date().timeIntervalSince(phaseStarted)
                        if counts.timeouts > timeoutsBefore, report.timeouts.count < Self.listedPerClass {
                            report.timeouts.append(.init(source: source.rawValue, session: label, invariant: "coverage.timeout." + phase, phase_seconds: phaseSeconds))
                        }
                        SessionTranscriptBuilder._testResetCoalesceCache()
                    }
                    guard Date() < deadline else { counts.timeouts += 1; return }
                    enter("projection")
                    let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false, includeMessageContext: true)
                    guard Date() < deadline else { counts.timeouts += 1; return }
                    enter("images")
                    var imageAbsent = false
                    if (source == .hermes || source == .openclaw), case .identity(let url, _, _) = candidate {
                        let stamp = MessageImageAbsenceCache.stamp(url)
                        if imageAbsence.contains(path: url.path, stamp: stamp) { imageAbsent = true }
                        else {
                            var cancelled = false, succeeded = false, foundImage = true
                            let cancel: () -> Bool = { if Date() >= deadline { cancelled = true }; return cancelled }
                            do {
                                if source == .hermes { foundImage = try !Base64ImageDataURLScanner.scanFile(at: url, maxMatches: 1, shouldCancel: cancel).isEmpty }
                                else { foundImage = try !OpenClawBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: 1, shouldCancel: cancel).isEmpty }
                                succeeded = true
                            } catch { succeeded = false }
                            imageAbsence.record(path: url.path, before: stamp, after: MessageImageAbsenceCache.stamp(url), foundImage: foundImage, cancelled: cancelled || Date() >= deadline, succeeded: succeeded)
                            guard succeeded && !cancelled else { counts.timeouts += 1; return }
                            imageAbsent = imageAbsence.contains(path: url.path, stamp: stamp)
                        }
                    }
                    let images: Set<Int> = imageAbsent ? [] : Set(SessionInlineImageMapper.imagesByUserBlockIndex(for: session, includeMessageContext: true, shouldCancel: { Date() >= deadline }).filter { !$0.value.isEmpty }.keys)
                    guard Date() < deadline else { counts.timeouts += 1; return }
                    // Read original records: parser rawJSON is deliberately truncated. This pass
                    // also supplies the same source telemetry markers as the Session table.
                    enter("telemetry_provenance")
                    var provider = descriptor.makeTelemetryProvider?()
                    var rawReadFailed = false
                    if case .file(let url, _, _) = candidate {
                        let reader = CodexRolloutStorage.lineReader(for: url, maximumBytes: UInt64(Self.maxFileBytes), propagatesReadErrors: true)
                            ?? JSONLReader(url: url, maximumBytes: UInt64(Self.maxFileBytes), propagatesReadErrors: true)
                        var lineIndex = 0
                        do {
                            let completed = try reader.forEachLineWhile { line in
                                guard Date() < deadline else { return false }
                                provider?.consume(line: line, index: lineIndex); lineIndex += 1
                                if source == .codex || source == .claude {
                                    for kind in Self.originalKinds(line, source: source) {
                                        report.provenance[source.rawValue, default: [:]][kind, default: 0] += 1
                                        if !Self.namedKind(kind, source: source) { report.unknown_provenance[source.rawValue, default: [:]][kind, default: 0] += 1 }
                                    }
                                }
                                return true
                            }
                            if !completed { rawReadFailed = true }
                        } catch { rawReadFailed = true }
                    }
                    if rawReadFailed { counts.timeouts += 1; return }
                    let changes = provider?.finish().telemetry.configurationChanges ?? descriptor.scanTelemetry?(session)?.result.telemetry.configurationChanges ?? []
                    let markers = TranscriptTelemetryPresentation.markers(changes: changes, blocks: blocks)
                    guard Date() < deadline else { counts.timeouts += 1; return }
                    enter("group_emit")
                    let index = ToolInvocationIndex.build(blocks: blocks, source: source)
                    let groups = TranscriptMessageGroupIndex.build(blocks: blocks[...], source: source, markers: markers, noncollapsibleBlockIndices: images)
                    let rows = TranscriptToolRows.emit(blocks: blocks[...], index: index, rowSummary: { ToolInvocationBuilder.rowSummary($0, blocks: blocks, index: index, source: source) }, openGroups: [], openInvocations: [], activeRoles: Set(TranscriptRoleFilter.allCases), failedInvocationIDs: [], markers: markers, totalBlockCount: blocks.count, showsContext: false, source: source, messageGroups: groups)
                    guard Date() < deadline else { counts.timeouts += 1; return }
                    enter("oracle")
                    counts.sessions_checked += 1; report.rows += rows.count
                    for (block, invariant) in Self.messageFindings(blocks: blocks, rows: rows, source: source, child: session.parentSessionID != nil || session.subagentType != nil, images: images, markers: markers) {
                        counts.violations[invariant, default: 0] += 1; report.violation_totals[invariant, default: 0] += 1
                        if report.violations.filter({ $0.invariant == invariant }).count < Self.listedPerClass { report.violations.append(.init(source: source.rawValue, session: label, block: block, invariant: invariant)) }
                    }
                    if Date().timeIntervalSince(sessionStart) > Self.perSessionSeconds { counts.timeouts += 1 }
                }
                if n % 25 == 24 { report.sources[source.rawValue] = counts; try save() }
            }
            counts.seconds = Date().timeIntervalSince(sourceStart); report.sources[source.rawValue] = counts; try save()
        }
        report.coverage_failures = Self.messageCoverage(report.sources); report.complete = true; try save()
        XCTAssertTrue(report.violation_totals.isEmpty, "message invariant counts: \(report.violation_totals)")
        XCTAssertTrue(report.coverage_failures.isEmpty, "message coverage: \(report.coverage_failures)")
        XCTAssertGreaterThan(report.rows, 0)
    }

    private func messageFixture(_ body: String, origin: MessageOrigin? = .typed, kind: Block.Kind = .user, summary: String? = nil) -> Block {
        var block = TranscriptTestFixtures.block(kind, text: body)
        block.presentation = MessagePresentation(origin: origin, body: body, summary: summary)
        return block
    }
    private func fixtureFindings(_ input: [Block], images: Set<Int> = [], markers: [Int: [String]] = [:]) -> [String] {
        let blocks = TranscriptTestFixtures.sequence(input)
        let rows = blocks.map { BlockRowModel(id: $0.globalBlockIndex, content: .message($0), representedBlockIndices: [$0.globalBlockIndex]) }
        return Self.messageFindings(blocks: blocks, rows: rows, source: .claude, images: images, markers: markers).map(\.1)
    }
    func testMessageM1UsesOriginalProvenanceAndHarnessFacts() {
        var nonhuman = messageFixture("peer")
        nonhuman.messageOrigin = .peer(from: "worker")
        var rawFact = messageFixture("visible")
        rawFact.rawJSON = "{\"type\":\"user\",\"origin\":{\"kind\":\"peer\"}}"
        XCTAssertTrue(fixtureFindings([rawFact]).contains("M1"))
        XCTAssertTrue(fixtureFindings([nonhuman]).contains("M1"))
        XCTAssertTrue(fixtureFindings([messageFixture("Another Claude session sent a message: hello")]).contains("M1"))
        var typed = messageFixture("[Request interrupted by user]"); typed.messageOrigin = .typed
        XCTAssertFalse(fixtureFindings([typed]).contains("M1"))
        XCTAssertTrue(fixtureFindings([messageFixture("<system-reminder>context</system-reminder>")]).contains("M1"))
        XCTAssertFalse(fixtureFindings([messageFixture("<system-reminder>context</system-reminder>\nHuman request")]).contains("M1"))
    }
    func testMessageM2KnownEnvelopeAndTypedCustomMarkup() {
        XCTAssertTrue(fixtureFindings([messageFixture("<command-name>/test</command-name>", origin: .command(name: "test"))]).contains("M2"))
        var custom = messageFixture("<custom-widget>hello</custom-widget>"); custom.messageOrigin = .typed
        XCTAssertTrue(fixtureFindings([custom]).isEmpty)
        var prefixedCustom = messageFixture("<user_input_widget>hello</user_input_widget>")
        prefixedCustom.messageOrigin = .typed
        XCTAssertTrue(fixtureFindings([prefixedCustom]).isEmpty)
        prefixedCustom.messageOrigin = nil
        XCTAssertTrue(fixtureFindings([prefixedCustom]).isEmpty)
        let clineCustom = TranscriptTestFixtures.sequence([prefixedCustom])
        let customRow = BlockRowModel(id: 0, content: .message(clineCustom[0]), representedBlockIndices: [0])
        XCTAssertFalse(Self.messageFindings(blocks: clineCustom, rows: [customRow], source: .cline).contains { $0.1 == "M2" })
        var literal = messageFixture("<system-reminder>literal markup</system-reminder>")
        literal.messageOrigin = .typed
        XCTAssertTrue(fixtureFindings([literal]).isEmpty)
        let mixedText = "<system-reminder>harness context</system-reminder>\nHuman request"
        XCTAssertTrue(fixtureFindings([messageFixture(mixedText)]).contains("M2"))
        var mixed = TranscriptTestFixtures.block(.user, text: mixedText)
        mixed.presentation = MessageOriginClassifier.presentation(for: mixed, context: .init(source: .claude, isFirstUserBlock: true))
        XCTAssertEqual(mixed.presentation?.origin, .typed)
        XCTAssertEqual(mixed.presentation?.body, "Human request")
        XCTAssertTrue(fixtureFindings([mixed]).isEmpty)
        XCTAssertTrue(fixtureFindings([messageFixture("```sh\necho hi\n```", origin: .command(name: "test"))]).isEmpty)
    }
    func testMessageM3FinalAgentJSONBody() {
        XCTAssertTrue(fixtureFindings([messageFixture("{\"ok\":true}", origin: nil, kind: .assistant)]).contains("M3"))
        XCTAssertTrue(fixtureFindings([messageFixture("- **ok:** true", origin: nil, kind: .assistant)]).isEmpty)
        XCTAssertTrue(fixtureFindings([messageFixture("```json\n{\n  \"ok\": true\n}\n```", origin: nil, kind: .assistant)]).isEmpty)
        let compactFields = "{" + (0..<5_000).map { "\"k\($0)\":0" }.joined(separator: ",") + "}"
        XCTAssertLessThan(compactFields.utf8.count, 65_536)
        var expanded = TranscriptTestFixtures.block(.assistant, text: compactFields)
        expanded.presentation = MessageOriginClassifier.presentation(for: expanded, context: .init(source: .claude, isFirstUserBlock: false))
        XCTAssertGreaterThan(expanded.presentation?.body.utf8.count ?? 0, 65_536)
        XCTAssertTrue(fixtureFindings([expanded]).isEmpty)
        let large = "{\"value\":\"" + String(repeating: "x", count: 70_000) + "\"}"
        XCTAssertTrue(fixtureFindings([messageFixture(large, origin: nil, kind: .assistant)]).contains("M3"))
        var fallback = TranscriptTestFixtures.block(.assistant, text: large)
        fallback.presentation = MessageOriginClassifier.presentation(for: fallback, context: .init(source: .claude, isFirstUserBlock: false))
        XCTAssertTrue(fallback.presentation?.body.hasPrefix(MessageOriginText.largeStructured + "\n\n```json\n") == true)
        XCTAssertTrue(fixtureFindings([fallback]).isEmpty)
        fallback.presentation?.body = MessageOriginText.largeStructured + "\n\n" + large
        XCTAssertTrue(fixtureFindings([fallback]).contains("M3"))
    }
    func testMessageM4SummaryOnlyPeerAndImageContent() {
        XCTAssertTrue(fixtureFindings([messageFixture("  ")]).contains("M4"))
        XCTAssertTrue(fixtureFindings([messageFixture("", origin: .peer(from: "peer"), summary: "Encrypted message")]).isEmpty)
        XCTAssertTrue(fixtureFindings([messageFixture("", origin: .peer(from: "peer"))]).contains("M4"))
        XCTAssertTrue(fixtureFindings([messageFixture("")], images: [0]).isEmpty)
    }
    func testMessageM5DuplicateAndStructuralImageBarriers() {
        let same = messageFixture("same")
        XCTAssertTrue(fixtureFindings([same, same]).contains("M5"))
        XCTAssertTrue(fixtureFindings([same, same], images: [0, 1]).isEmpty)
        XCTAssertTrue(fixtureFindings([same, same], markers: [1: ["change"]]).isEmpty)
        let blocks = TranscriptTestFixtures.sequence([same, TranscriptTestFixtures.block(.toolCall, text: ""), same])
        let rows = [BlockRowModel(id: 0, content: .message(blocks[0]), representedBlockIndices: [0, 2])]
        XCTAssertTrue(Self.messageFindings(blocks: blocks, rows: rows, source: .claude).contains { $0.1 == "M5" })
        XCTAssertTrue(Self.messageFindings(blocks: blocks, rows: [], source: .claude).contains { $0.1 == "M5" })
    }
    func testMessageM6PreservesOriginalKindsAndReportsUnknown() {
        let raw = "{\"payload\":{\"internal_chat_message_metadata_passthrough\":{\"content_item_kinds\":[\"user.text | original\",\"future.kind\"]}}}"
        XCTAssertEqual(Self.originalKinds(raw, source: .codex), ["user.text | original", "future.kind"])
        XCTAssertTrue(Self.namedKind("user.text | original", source: .codex))
        XCTAssertFalse(Self.namedKind("future.kind", source: .codex))
        XCTAssertEqual(Self.originalKinds("{\"origin\":{\"kind\":\"peer\"}}", source: .claude), ["peer"])
        XCTAssertFalse(Self.namedKind("future", source: .claude))
    }
    func testMessageCoverageRejectsMissingZeroAndLostSources() {
        XCTAssertFalse(Self.messageCoverage([:]).isEmpty)
        var sources = Dictionary(uniqueKeysWithValues: SessionSource.allCases.map { ($0.rawValue, SourceCounts()) })
        XCTAssertFalse(Self.messageCoverage(sources).isEmpty)
        var counts = SourceCounts(); counts.discovered = 200; counts.sessions_checked = 200
        sources[SessionSource.codex.rawValue] = counts
        XCTAssertTrue(Self.messageCoverage(sources).isEmpty)
        counts.timeouts = 11; sources[SessionSource.codex.rawValue] = counts
        XCTAssertFalse(Self.messageCoverage(sources).isEmpty)
    }
}

// Append after Task8 releases corpus-file ownership. Shares that class's discovery.
extension TranscriptToolCorpusCheckTests {
    private struct GalleryFinding {
        let id: String
        let description: String
        let sources: Set<SessionSource>
        let matches: (Block, [Block], Session) -> Bool
    }

    private static var galleryFindings: [GalleryFinding] {
        func f(_ id: String, _ label: String, _ sources: [SessionSource], _ match: @escaping (Block, [Block], Session) -> Bool) -> GalleryFinding {
            .init(id: id, description: label, sources: Set(sources), matches: match)
        }
        func contains(_ b: Block, _ text: String) -> Bool { b.text.contains(text) }
        func duplicate(_ b: Block, _ all: [Block]) -> Bool {
            let i = b.globalBlockIndex
            guard i > 0, (b.kind == .user || b.kind == .assistant), all.indices.contains(i - 1) else { return false }
            return all[i - 1].kind == b.kind && all[i - 1].text == b.text
        }
        return [
            f("01", "Claude task notification", [.claude]) { b,_,_ in contains(b,"<task-notification>") },
            f("02", "Claude harness notice", [.claude]) { b,_,_ in contains(b,"[SYSTEM NOTIFICATION - NOT USER INPUT]") || contains(b,"<system-reminder>") && b.presentation?.origin?.isHiddenContext == true },
            f("03", "Claude peer", [.claude]) { b,_,_ in if case .peer = b.presentation?.origin { return true }; return false },
            f("04", "Claude compaction", [.claude]) { b,_,_ in b.presentation?.origin == .compaction },
            f("05", "Claude skill", [.claude]) { b,_,_ in if case .skill = b.presentation?.origin { return true }; return false },
            f("06", "Claude command", [.claude]) { b,_,_ in if case .command = b.presentation?.origin { return true }; return false },
            f("07", "Claude empty assistant", [.claude]) { b,_,_ in b.kind == .assistant && b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            f("08", "Codex page context", [.codex]) { b,_,_ in contains(b,"<external_codex_apps_") },
            f("09", "Codex answer JSON", [.codex]) { b,_,_ in contains(b,"<send_user_message_question_reply>") },
            f("10", "Codex memory citations", [.codex]) { b,_,_ in b.kind == .assistant && contains(b,"<oai-mem-citation>") },
            f("11-request", "Guardian approval request", [.codex]) { b,_,_ in b.presentation?.origin == .approvalRequest },
            f("11-verdict", "Guardian verdict", [.codex]) { b,_,_ in if case .approvalVerdict = b.presentation?.origin { return true }; return false },
            f("11-history", "Guardian history context", [.codex]) { b,_,s in s.subagentType == "guardian" && b.presentation?.origin?.isHiddenContext == true },
            f("12", "Codex agent_message", [.codex]) { b,_,_ in if case .peer = b.presentation?.origin { return true }; return false },
            f("13", "Grok query envelope", [.grok]) { b,_,_ in contains(b,"<user_query>") },
            f("14", "Cline input envelope", [.cline]) { b,_,_ in contains(b,"<user_input") },
            f("15", "Cursor timestamp", [.cursor]) { b,_,_ in contains(b,"<timestamp>") },
            f("16", "Cursor placeholder", [.cursor]) { b,_,_ in b.kind == .assistant && b.presentation?.origin == .placeholder },
            f("16-duplicate", "Cursor duplicate", [.cursor]) { b,a,_ in duplicate(b,a) },
            f("17-droid", "Droid reminder", [.droid]) { b,_,_ in contains(b,"<system-reminder>") },
            f("17-kimi", "Kimi reminder", [.kimi]) { b,_,_ in contains(b,"<system-reminder>") },
            f("18", "Kimi shell echo", [.kimi]) { b,_,_ in contains(b,"<bash-input>") || contains(b,"<bash-stdout>") },
            f("19-empty", "Hermes placeholder", [.hermes]) { b,_,_ in b.kind == .assistant && b.presentation?.origin == .placeholder },
            f("19-retry", "Hermes retry", [.hermes]) { b,_,_ in b.presentation?.origin == .harnessRetry },
            f("20-hermes", "Hermes scheduled", [.hermes]) { b,_,_ in if case .scheduled = b.presentation?.origin { return true }; return false },
            f("20-openclaw", "OpenClaw scheduled", [.openclaw]) { b,_,_ in if case .scheduled = b.presentation?.origin { return true }; return false },
            f("21", "Antigravity empty assistant", [.antigravity]) { b,_,_ in b.kind == .assistant && b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            f("22-opencode", "OpenCode duplicates", [.opencode]) { b,a,_ in duplicate(b,a) },
            f("22-openclaw", "OpenClaw duplicates", [.openclaw]) { b,a,_ in duplicate(b,a) },
            f("22-hermes", "Hermes duplicates", [.hermes]) { b,a,_ in duplicate(b,a) },
            f("23", "Typed user has no duration", Array(SessionSource.allCases)) { b,_,_ in b.isTypedUserMessage && !b.text.isEmpty }
        ]
    }

    @MainActor
    func testMessageRenderGallery() throws {
        guard ProcessInfo.processInfo.environment["AS_TOOL_CORPUS_CHECK"] == "1" else { throw XCTSkip("Opt-in real local gallery") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("scripts/probe_scan_output/message_gallery")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let auditURL = root.appendingPathComponent("scripts/probe_scan_output/message_audit/audit.json")
        let audit = (try? JSONSerialization.jsonObject(with: Data(contentsOf: auditURL))) as? [String: Any]
        let samples = audit?["samples"] as? [String: [[String: Any]]] ?? [:]
        var seedLabels: [String: Set<String>] = [:]
        for list in samples.values { for sample in list {
            if let source = sample["source"] as? String, let label = sample["label"] as? String { seedLabels[source, default: []].insert(label) }
        } }
        let extraSeedsURL = output.appendingPathComponent("seeds.json")
        if let data = try? Data(contentsOf: extraSeedsURL),
           let extra = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for (source, labels) in extra { seedLabels[source, default: []].formUnion(labels) }
        }
        var remaining = Self.galleryFindings
        var index: [[String: Any]] = []
        var visited: [String: Int] = [:]
        var scanEvidence: [[String: Any]] = []
        func saveIndex() throws {
            try JSONSerialization.data(withJSONObject: ["entries": index, "parsed_sessions": visited, "candidate_evidence": scanEvidence], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("index.json"), options: .atomic)
            let text = index.map { entry in entry.keys.sorted().map { "\($0)=\(entry[$0]!)" }.joined(separator: " | ") }.joined(separator: "\n")
            try (text + "\n").write(to: output.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
        }
        for source in SessionSource.allCases {
            guard remaining.contains(where: { $0.sources.contains(source) }) else { continue }
            let descriptor = SessionSourceRegistry.descriptor(for: source)
            let discovered = Self.candidates(source)
            func label(_ c: Candidate) -> String {
                switch c { case .file(let u,_,_): return u.path; case .identity(_,let id,_): return "id:" + id }
            }
            // Audit seeds first, each parsed once. Bounded newest fallback only for absent cases.
            let seeds = seedLabels[source.rawValue] ?? []
            let selected = discovered.filter { seeds.contains(label($0)) } + discovered.prefix(20).filter { !seeds.contains(label($0)) }
            for candidate in selected {
                guard remaining.contains(where: { $0.sources.contains(source) }) else { break }
                try autoreleasepool {
                    let session: Session?, location: String
                    switch candidate {
                    case .file(let url, let bytes, _):
                        guard bytes <= Self.maxFileBytes else { return }
                        session = descriptor.parseFullByPath?(url); location = url.path
                    case .identity(let url, let id, _):
                        session = descriptor.parseFullByIdentity?(url,id); location = url.path + "#" + id
                    }
                    guard let session else { return }
                    visited[source.rawValue, default: 0] += 1
                    defer { SessionTranscriptBuilder._testResetCoalesceCache() }
                    let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false, includeMessageContext: true)
                    let images = SessionInlineImageMapper.imagesByUserBlockIndex(for: session, includeMessageContext: true)
                    let changes = descriptor.scanTelemetry?(session)?.result.telemetry.configurationChanges ?? []
                    let markers = TranscriptTelemetryPresentation.markers(changes: changes, blocks: blocks)
                    let examinedFindings = remaining.filter { $0.sources.contains(source) }.map(\.id)
                    let matches = remaining.compactMap { finding -> (GalleryFinding, Block)? in
                        guard finding.sources.contains(source), let block = blocks.first(where: { block in
                            guard finding.matches(block, blocks, session) else { return false }
                            guard finding.id.contains("duplicate") || finding.id.hasPrefix("22-") else { return true }
                            let i = block.globalBlockIndex
                            return markers[i]?.isEmpty != false && images[i]?.isEmpty != false && images[i - 1]?.isEmpty != false
                        }) else { return nil }
                        return (finding,block)
                    }
                    scanEvidence.append(["source": source.rawValue, "location": location, "session": session.id,
                                         "block_count": blocks.count, "examined_findings": examinedFindings,
                                         "matched_findings": matches.map { $0.0.id }])
                    for (finding, block) in matches {
                        let captures = try galleryCapture(finding: finding, target: block, blocks: blocks, session: session, images: images, changes: changes, output: output)
                        for capture in captures {
                            var entry = capture
                            entry["finding"] = finding.id; entry["description"] = finding.description
                            entry["source"] = source.rawValue; entry["session"] = session.id
                            entry["location"] = location; entry["original_block"] = block.globalBlockIndex
                            index.append(entry)
                        }
                        remaining.removeAll { $0.id == finding.id }
                        try saveIndex()
                    }
                }
            }
        }
        for finding in remaining {
            index.append(["finding": finding.id, "description": finding.description, "status": "no-local-data", "scope": "audit-seeded identities plus newest 20 discovered sessions per source; not exhaustive absence"])
        }
        try saveIndex()
        XCTAssertGreaterThan(index.filter { $0["png"] != nil }.count, 0)
    }

    @MainActor
    private func galleryCapture(finding: GalleryFinding, target: Block, blocks: [Block], session: Session, images: [Int: [InlineSessionImage]], changes: [ConfigurationChange], output: URL) throws -> [[String: Any]] {
        var entries: [[String: Any]] = []
        let hidden = target.presentation?.origin?.isHiddenContext == true
        let states: [(String, Bool, Bool)] = hidden ? [("context-off",false,false),("context-on-expanded",true,true)] : [("visible",false,true)]
        let origin: String
        switch target.presentation?.origin {
        case .typed: origin = "typed"
        case .context: origin = "context"
        case .notification: origin = "notification"
        case .peer: origin = "peer"
        case .compaction: origin = "compaction"
        case .skill: origin = "skill"
        case .command: origin = "command"
        case .scheduled: origin = "scheduled"
        case .harnessRetry: origin = "harness-retry"
        case .parentTask: origin = "parent-task"
        case .approvalRequest: origin = "approval-request"
        case .approvalVerdict: origin = "approval-verdict"
        case .placeholder: origin = "placeholder"
        case nil: origin = "agent"
        }
        let toolIndex = ToolInvocationIndex.build(blocks: blocks, source: session.source)
        for (appearanceName, appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            for (state, showContext, expand) in states {
                let controller = BlockTableController()
                let views = BlockTableController.makeScrollView(selectionOwner: controller)
                let frame = NSRect(x: 0, y: 0, width: 900, height: 900)
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                views.scroll.frame = frame; window.contentView = views.scroll
                controller.attach(table: views.table, scroll: views.scroll)
                defer { window.close() }
                controller.apply(allBlocks: blocks, invocationIndex: toolIndex, totalBlockCount: blocks.count,
                                 fontSize: 13, source: session.source, sessionID: session.id, configurationChanges: changes,
                                 imagesByBlockIndex: images, inlineImagesEnabled: !images.isEmpty, showsContext: showContext)
                controller.scrollToBlock(target.globalBlockIndex)
                // Hidden/placeholder targets have no row: anchor to their nearest real neighbor.
                if !controller.rows.contains(where: { $0.representedBlockIndices.contains(target.globalBlockIndex) }),
                   let neighbor = controller.rows.min(by: { abs($0.primaryBlock.globalBlockIndex - target.globalBlockIndex) < abs($1.primaryBlock.globalBlockIndex - target.globalBlockIndex) }) {
                    controller.scrollToBlock(neighbor.primaryBlock.globalBlockIndex)
                }
                if expand, let row = controller.rows.first(where: { $0.representedBlockIndices.contains(target.globalBlockIndex) }), row.isOriginLine {
                    controller.toggleOriginLine(row.id)
                }
                let deadline = Date().addingTimeInterval(20)
                repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                while controller.hasPendingToolPresentations && Date() < deadline
                XCTAssertFalse(controller.hasPendingToolPresentations)
                // Pending table/SwiftUI work may restore the old scroll anchor; settle first,
                // then synchronously position the exact target immediately before drawing.
                controller.scrollToBlock(target.globalBlockIndex)
                if !controller.rows.contains(where: { $0.representedBlockIndices.contains(target.globalBlockIndex) }),
                   let neighbor = controller.rows.min(by: { abs($0.primaryBlock.globalBlockIndex - target.globalBlockIndex) < abs($1.primaryBlock.globalBlockIndex - target.globalBlockIndex) }) {
                    controller.scrollToBlock(neighbor.primaryBlock.globalBlockIndex)
                }
                window.contentView?.layoutSubtreeIfNeeded(); views.table.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded(); views.table.displayIfNeeded()
                let targetRow = controller.rows.first { $0.representedBlockIndices.contains(target.globalBlockIndex) }
                let absent = target.presentation?.rowStyle == MessageRowStyle.none || hidden && !showContext
                if absent { XCTAssertNil(targetRow) } else { XCTAssertNotNil(targetRow) }
                // A duplicate finding is an adjacent raw pair with no image/telemetry barrier.
                // Placeholders may both disappear; every shown pair must share the actual row.
                if finding.id.contains("duplicate") || finding.id.hasPrefix("22-") {
                    XCTAssertGreaterThan(target.globalBlockIndex, 0)
                    XCTAssertEqual(blocks[target.globalBlockIndex - 1].kind, target.kind)
                    XCTAssertEqual(blocks[target.globalBlockIndex - 1].text, target.text)
                    if !absent {
                        let grouped = try XCTUnwrap(targetRow)
                        XCTAssertGreaterThan(grouped.repeatCount, 1)
                        XCTAssertTrue(grouped.representedBlockIndices.contains(target.globalBlockIndex - 1))
                        XCTAssertTrue(grouped.representedBlockIndices.contains(target.globalBlockIndex))
                    }
                }
                if expand, let targetRow, targetRow.isOriginLine {
                    XCTAssertTrue(controller.openOriginLines.contains(targetRow.id))
                }
                let visible = views.table.rows(in: views.table.visibleRect)
                XCTAssertGreaterThan(visible.length, 0)
                let cells = (visible.location..<NSMaxRange(visible)).compactMap { views.table.view(atColumn: 0,row: $0,makeIfNecessary: false) }
                XCTAssertFalse(cells.isEmpty)
                let visibleIDs = (visible.location..<NSMaxRange(visible)).filter { controller.rows.indices.contains($0) }.map { controller.rows[$0].id }
                if let targetRow, !visibleIDs.contains(targetRow.id) {
                    XCTFail("Target row \(targetRow.id) must be in captured viewport for \(finding.id): \(visibleIDs)")
                    throw NSError(domain: "GalleryViewport", code: 1)
                }
                if finding.id == "23" {
                    let cell = try XCTUnwrap(cells.compactMap({ $0 as? BlockCardCellView }).first(where: { $0.displayedHeader?.roleLabel == "You" }))
                    XCTAssertEqual(cell.displayedHeader?.turnChipText, "")
                }
                let bitmap = try XCTUnwrap(views.scroll.bitmapImageRepForCachingDisplay(in: views.scroll.bounds))
                views.scroll.cacheDisplay(in: views.scroll.bounds, to: bitmap)
                // AppKit's table is intentionally transparent. Flatten against this window's
                // resolved background; PNG viewers otherwise expose unassociated-alpha colors.
                let opaque = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: opaque))
                let cg = graphics.cgContext
                let pixelRect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    cg.fill(pixelRect)
                }
                cg.setBlendMode(.normal)
                cg.draw(try XCTUnwrap(bitmap.cgImage), in: pixelRect)
                let png = try XCTUnwrap(opaque.representation(using: .png, properties: [:]))
                let name = "\(finding.id)-\(session.source.rawValue)-\(origin)-\(state)-\(appearanceName).png"
                try png.write(to: output.appendingPathComponent(name), options: .atomic)
                entries.append(["png": name,"appearance": appearanceName,"state": state,"target_absent": absent,"target_row_id": targetRow?.id ?? -1,"expanded": targetRow.map { controller.openOriginLines.contains($0.id) } ?? false,"visible_block_ids": (visible.location..<NSMaxRange(visible)).filter { controller.rows.indices.contains($0) }.map { controller.rows[$0].primaryBlock.globalBlockIndex },"row_count": controller.rows.count,"repeat_count": targetRow?.repeatCount ?? 0,"status": "captured"])
            }
        }
        return entries
    }
}

// Append to already-targeted TranscriptToolCorpusCheckTests.swift after approval.
// BASELINE_ADAPT markers are transformed only in the pinned source export.
extension TranscriptToolCorpusCheckTests {
    @MainActor
    func testMessageOpenPerformance() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AS_MESSAGE_PERF_CHECK"] == "1" else { throw XCTSkip("Opt-in Release open benchmark") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let configPath = env["AS_MESSAGE_PERF_INPUTS"] ?? root.appendingPathComponent(".superpowers/sdd/2026-11-07-transcript-message-readability/perf-inputs.json").path
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configPath))) as! [String: String]
        let output = URL(fileURLWithPath: try XCTUnwrap(env["AS_MESSAGE_PERF_OUTPUT"]))
        let sources: [SessionSource] = [.codex, .claude]
        var report: [String: Any] = ["variant": env["AS_MESSAGE_PERF_VARIANT"] ?? "current", "geometry": [900, 900], "samples_per_source": 5, "parse_timed": false, "ownership_timed": true]
        var results: [String: Any] = [:]
        for source in sources {
            let path = try XCTUnwrap(config[source.rawValue])
            let session = try XCTUnwrap(SessionSourceRegistry.descriptor(for: source).parseFullByPath?(URL(fileURLWithPath: path)))
            var samples: [[String: Double]] = []
            var rowCounts: [Int] = []
            for _ in 0..<5 {
                try autoreleasepool {
                    SessionTranscriptBuilder._testResetCoalesceCache()
                    let controller = BlockTableController()
                    let views = BlockTableController.makeScrollView(selectionOwner: controller)
                    let frame = NSRect(x: 0, y: 0, width: 900, height: 900)
                    let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: .aqua)
                    views.scroll.frame = frame
                    window.contentView = views.scroll
                    controller.attach(table: views.table, scroll: views.scroll)
                    defer { window.close() }
                    let start = CFAbsoluteTimeGetCurrent()
                    let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: true, reviewCardsEnabled: true, includeMessageContext: true) // BASELINE_ADAPT
                    let snapshot = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)
                    let snapshotEnd = CFAbsoluteTimeGetCurrent()
                    // Current apply builds full message groups when no supplied groups are given.
                    // Keep that first construction inside this timed region.
                    controller.apply(allBlocks: snapshot.blocks, invocationIndex: snapshot.invocationIndex,
                        failedInvocationIDs: snapshot.failedInvocationIDs, toolJumpIDs: snapshot.toolJumpIDs,
                        errorJumpIDs: snapshot.errorJumpIDs, totalBlockCount: snapshot.totalBlockCount,
                        fontSize: 13, source: source, sessionID: session.id,
                        sessionCwd: session.cwd, rowSummaries: snapshot.rowSummaries)
                    window.contentView?.layoutSubtreeIfNeeded()
                    views.table.layoutSubtreeIfNeeded()
                    window.contentView?.displayIfNeeded()
                    views.table.displayIfNeeded()
                    let end = CFAbsoluteTimeGetCurrent()
                    XCTAssertGreaterThan(views.table.numberOfRows, 0)
                    XCTAssertNotNil(views.table.view(atColumn: 0, row: max(0, views.table.rows(in: views.table.visibleRect).location), makeIfNecessary: false))
                    samples.append(["snapshot_ms": (snapshotEnd - start) * 1000,
                                    "table_including_ownership_ms": (end - snapshotEnd) * 1000,
                                    "end_to_end_ms": (end - start) * 1000])
                    rowCounts.append(views.table.numberOfRows)
                }
            }
            results[source.rawValue] = ["path": path, "bytes": session.fileSizeBytes ?? 0,
                                       "events": session.events.count, "row_counts": rowCounts, "samples": samples]
        }
        report["sources"] = results
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
