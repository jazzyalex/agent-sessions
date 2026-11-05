import AppKit
import Foundation

extension NSAttributedString.Key {
    /// The gutter cell of a numbered pane line: the leading tab, the line number and the tab after it
    /// (value `true`). It is not text: `RenderedToolBody.plainCopyText` leaves it out, and the
    /// selection-copy path skips it too (Task 14).
    static let toolGutter = NSAttributedString.Key("AgentSessions.toolGutter")
}

/// A control in a rendered tool body (spec §6.5). `.link` holds its `url`,
/// `toolfold:<kind>:<action>:<line>`; `line` is 0 when the kind has none, and `action` is 0 for
/// `showScript`. `action` indexes `ToolInvocation.actions` and is the key into `folds`; the script
/// output pane uses `actions.count`.
///
/// What the cell does with each (Task 13): `showMore` adds `ToolTextBudget.showMoreStep` to
/// `FoldState.extraLinesShown`; `showAll` sets `showAll`; `openLongLine` inserts `line` into
/// `openedLongLines` (output panes only); `showFullCommand` sets `commandShowAll`, which opens the
/// action's command, heredoc and input-field panes, cut lines included; `showScript` shows
/// `ToolInvocation.scriptSource`; `copyOutput` copies the pane's whole decoded output.
enum ToolFoldLink: Hashable, Sendable {
    case showMore(action: Int), showAll(action: Int), openLongLine(action: Int, line: Int), showFullCommand(action: Int)
    case showScript, copyOutput(action: Int)

    static let scheme = "toolfold"

    var payload: String {
        let kind: String
        var action = 0
        var line = 0
        switch self {
        case .showMore(let a): kind = "showMore"; action = a
        case .showAll(let a): kind = "showAll"; action = a
        case .openLongLine(let a, let l): kind = "openLongLine"; action = a; line = l
        case .showFullCommand(let a): kind = "showFullCommand"; action = a
        case .showScript: kind = "showScript"
        case .copyOutput(let a): kind = "copyOutput"; action = a
        }
        return "\(Self.scheme):\(kind):\(action):\(line)"
    }

    /// Never fails: the payload is ASCII letters, digits and colons.
    var url: URL { URL(string: payload)! }

    init?(payload: String) {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, String(parts[0]) == Self.scheme,
              let action = Int(parts[2]), let line = Int(parts[3]), action >= 0, line >= 0 else { return nil }
        switch parts[1] {
        case "showMore": self = .showMore(action: action)
        case "showAll": self = .showAll(action: action)
        case "openLongLine": self = .openLongLine(action: action, line: line)
        case "showFullCommand": self = .showFullCommand(action: action)
        case "showScript": self = .showScript
        case "copyOutput": self = .copyOutput(action: action)
        default: return nil
        }
    }

    init?(url: URL) { self.init(payload: url.absoluteString) }
}

/// One invocation's L2 body: the text the cell shows, plus what Copy, Find and the fold links need.
struct RenderedToolBody {
    var attributed: NSAttributedString
    /// The visible text in the current fold state: no gutter, no fold rows or other controls, nothing
    /// for folded lines. Actions are separated by a blank line, like `ToolInvocation.plainText`.
    var plainCopyText: String
    /// Rendered ranges of action text, mapped to (action index, UTF-16 range in that action's
    /// `plainText`). `actionIndex == invocation.actions.count` is the script output; its source range
    /// is in `scriptOutput.text`. Context, labels, fold rows, gutter and footer facts that the plain
    /// text does not hold map to nothing. Entries are in rendered order, do not overlap, and each
    /// entry's rendered text equals its source text.
    var sourceMap: [(rendered: NSRange, actionIndex: Int, source: NSRange)]
    /// Every control (fold row links, "… +N chars", "Show script") in rendered order.
    var foldLinks: [(range: NSRange, action: ToolFoldLink)]
}

/// Renders one `ToolInvocation` as one attributed string, the L2 detail (spec §6.5–6.7).
///
/// Per action, top to bottom, with a thin gap between parts and a wider one between actions:
/// 1. Context line (system 10.5 pt, tertiary): `cwd …   shell …   timeout …` and the
///    "exec script · command i of n" item.
/// 2. Input pane: for a shell action `$ ` and the display `command` (SF Mono at `fontSize − 0.5`,
///    2-character hanging indent, `ToolTextBudget.foldCommand`), then the heredoc body with a line
///    gutter, its fold row, and its terminator line. For any other action an aligned `key  value`
///    list: strings as they are (folded like a command), nested values as compact one-line JSON cut
///    at 200 characters.
/// 3. Output pane: `ToolTextBudget.fold`, error mode when the action failed. Line-numbered output
///    gets a gutter; images and binary data a muted placeholder line; every other shape monospace
///    text (markdown rendering is P2). stderr is not separate in P1.
/// 4. One muted "system note" line per hidden note (collapsed).
/// 5. Footer facts: exit code or failure word (red semibold when non-zero), duration, agent
///    truncation (orange), the saved-output pointer, agent notes.
/// After the actions: `scriptOutput` as its own output pane, then a "Show script" link.
///
/// Panes use the 4.2 code card's TextKit 1 technique (paragraph insets plus `.backgroundColor` with
/// the `.markdownCodeBlockBg` marker, so a find-highlight clear restores the fill). Mono panes wrap
/// by character and put tab stops every 4 columns from the text start, so the budget's visual-line
/// math matches the layout. `width` is the line-fragment width the text view lays out in.
///
/// Pure: no views and no main-actor state; colors are dynamic and resolve at draw time (Increase
/// Contrast is the cell's job). Call it off the main thread, like `ToolInvocationBuilder.build`.
enum ToolDetailRenderer {
    static func render(_ invocation: ToolInvocation, fontSize: CGFloat, width: CGFloat,
                       folds: [Int: FoldState], appearance: NSAppearance) -> RenderedToolBody {
        _ = appearance  // dynamic colors only; see the type comment
        var builder = Builder(invocation: invocation, fontSize: fontSize, width: width, folds: folds)
        builder.renderInvocation()
        return builder.finish()
    }
}

// MARK: - Style

private enum Style {
    static let paneHorizontalPadding: CGFloat = 9
    static let paneVerticalPadding: CGFloat = 5
    static let paneGap: CGFloat = 5
    static let partGap: CGFloat = 3
    static let actionGap: CGFloat = 10
    /// Space between the gutter numbers and the text, in character advances.
    static let gutterGapColumns: CGFloat = 2
    static let contextFontSize: CGFloat = 10.5
    static let foldFontSize: CGFloat = 11
    static let footerFontSize: CGFloat = 10.5
    /// Key column cap of the generic list; a longer key pushes its value right.
    static let fieldKeyMaxColumns = 20
    static let nestedValueLimit = 200
    static let contextSeparator = "   "
    static let factSeparator = " · "
    /// LINE SEPARATOR before a "… +N chars" control: the control starts its own visual line at the
    /// paragraph's indent instead of being split by character wrapping. Not copied, not mapped.
    static let controlBreak = "\u{2028}"
}

/// User-facing strings of the L2 body.
enum ToolDetailText {
    static func moreLines(_ count: Int) -> String {
        String(localized: "⋯ \(count) more lines",
               comment: "Transcript tool pane fold row: this many lines are hidden here. %lld is the count.")
    }

    static func moreLinesPastLimit(_ count: Int) -> String {
        String(localized: "⋯ \(count) more lines past the display limit",
               comment: "Transcript tool pane fold row after Show all stopped at its limit (20,000 lines or 2 MB). %lld is the count of lines not shown.")
    }

    static func showMore(_ count: Int) -> String {
        String(localized: "Show \(count) more",
               comment: "Transcript tool output fold link: shows the next hidden lines. %lld is the step, 500.")
    }

    static var showAll: String {
        String(localized: "Show all", comment: "Transcript tool pane fold link: shows every hidden line.")
    }

    static var copyOutput: String {
        String(localized: "Copy output", comment: "Transcript tool output fold link: copies the whole tool output.")
    }

    static func hiddenCharacters(_ count: Int) -> String {
        String(localized: "… +\(count) chars",
               comment: "Transcript tool pane: a long line or value stops here; this many characters follow. %lld is the count.")
    }

    static var showScript: String {
        String(localized: "Show script", comment: "Transcript tool detail link: shows the script the agent ran.")
    }

    static var systemNote: String {
        String(localized: "system note",
               comment: "Transcript tool detail: a collapsed note the agent's app added to the tool output (for example a system reminder).")
    }

    static func savedToFile(size: String?) -> String {
        guard let size else {
            return String(localized: "output saved to a file",
                          comment: "Transcript tool footer: the agent saved the full output to a file and kept a preview.")
        }
        return String(localized: "output saved to a file (\(size))",
                      comment: "Transcript tool footer: the agent saved the full output to a file and kept a preview. %@ is the file size, for example 38.4 KB.")
    }

    static func tokens(_ count: Int) -> String {
        String(localized: "\(count) tokens",
               comment: "Transcript tool footer: size of the output before the agent shortened it, in model tokens. %lld is the count.")
    }

    /// The label of a context item key ("cwd", "shell", "timeout"); other keys as they are.
    static func contextLabel(_ key: String) -> String {
        switch key {
        case "cwd": return String(localized: "tool.context.cwd", defaultValue: "cwd",
                                  comment: "Transcript tool context line label before the working directory of a command.")
        case "shell": return String(localized: "tool.context.shell", defaultValue: "shell",
                                    comment: "Transcript tool context line label before the shell that ran a command, for example zsh -lc.")
        case "timeout": return String(localized: "tool.context.timeout", defaultValue: "timeout",
                                      comment: "Transcript tool context line label before the command's time limit.")
        default: return key
        }
    }
}

// MARK: - Builder

private typealias Attrs = [NSAttributedString.Key: Any]

/// One pass over the invocation. The output is a list of blocks; a block is one or more lines that
/// share a base style, and the "\n" that ends a block carries that base style (so a pane line's fill
/// runs to the right edge and its paragraph style covers its newline).
private struct Builder {
    let invocation: ToolInvocation
    let folds: [Int: FoldState]
    let width: CGFloat
    let mono: NSFont
    let advance: CGFloat
    let pad = Style.paneHorizontalPadding

    let out = NSMutableAttributedString()
    var copyBlocks: [String] = []
    var sourceMap: [(rendered: NSRange, actionIndex: Int, source: NSRange)] = []
    var foldLinks: [(range: NSRange, action: ToolFoldLink)] = []

    private var blockOpen = false
    private var blockBase: Attrs = [:]
    private var blockCopy = ""
    private var blockCopyable = false
    /// The open block is a spacer line (its only character is the "\n" the next block appends).
    private var blockIsSpacer = false

    /// The current pane's fill: one instance per pane, used for both `.backgroundColor` and the
    /// find-restore marker (`clearFindHighlights` restores the exact instance).
    private var paneFill: NSColor = MarkdownStyle.codeBlockBackground

    init(invocation: ToolInvocation, fontSize: CGFloat, width: CGFloat, folds: [Int: FoldState]) {
        self.invocation = invocation
        self.folds = folds
        self.width = width
        mono = NSFont.monospacedSystemFont(ofSize: max(1, fontSize - 0.5), weight: .regular)
        let measured = ("0" as NSString).size(withAttributes: [.font: mono]).width
        advance = measured > 0 ? measured : mono.pointSize * 0.6
    }

    // MARK: Invocation

    mutating func renderInvocation() {
        let actions = invocation.actions
        for (index, action) in actions.enumerated() {
            if index > 0 { gap(Style.actionGap, copyable: true) }
            renderAction(action, index: index)
        }
        if let script = invocation.scriptOutput, !script.text.isEmpty {
            if !actions.isEmpty { gap(Style.actionGap, copyable: true) }
            outputPane(script, key: actions.count, isError: isFailure(invocation.ref.status),
                       mapIndex: actions.count, mapBase: 0)
        }
        if let source = invocation.scriptSource, !source.isEmpty,
           !actions.contains(where: { $0.exactCommand == source }) {
            if out.length > 0 { gap(Style.partGap) }
            startBlock(proseBase(size: Style.foldFontSize, color: .secondaryLabelColor))
            link(ToolDetailText.showScript, .showScript, base: blockBase)
        }
    }

    // MARK: Action

    private mutating func renderAction(_ action: ToolAction, index: Int) {
        let facts = footerFacts(action)
        let terminator = action.heredoc == nil ? nil : action.command.flatMap(Self.heredocTerminator)
        let layout = PlainLayout(action, bracket: facts.bracket, terminator: terminator)
        var parts = 0
        var lastWasContext = false

        if !action.context.isEmpty {
            contextLine(action.context)
            parts += 1
            lastWasContext = true
        }
        if let command = action.command {
            if parts > 0 { gap(lastWasContext ? Style.partGap : Style.paneGap) }
            commandPane(command, action: action, index: index, layout: layout, terminator: terminator)
            parts += 1
            lastWasContext = false
        } else if !action.inputFields.isEmpty {
            if parts > 0 { gap(lastWasContext ? Style.partGap : Style.paneGap) }
            fieldsPane(action, index: index, layout: layout)
            parts += 1
            lastWasContext = false
        }
        if let output = action.output, !output.text.isEmpty {
            if parts > 0 { gap(lastWasContext ? Style.partGap : Style.paneGap) }
            outputPane(output, key: index, isError: isFailure(action.status), mapIndex: index, mapBase: layout.output)
            parts += 1
        }
        if !action.hiddenNotes.isEmpty {
            if parts > 0 { gap(Style.partGap) }
            for _ in action.hiddenNotes {
                startBlock(proseBase(size: Style.footerFontSize, color: .tertiaryLabelColor))
                append(ToolDetailText.systemNote, blockBase)
            }
            parts += 1
        }
        if !facts.chips.isEmpty {
            if parts > 0 { gap(Style.partGap) }
            footerLine(facts.chips, index: index, bracketBase: layout.bracket)
        }
    }

    // MARK: Context and footer

    private mutating func contextLine(_ items: [ToolContextItem]) {
        let base = proseBase(size: Style.contextFontSize, color: .tertiaryLabelColor)
        var label = base
        label[.font] = NSFont.systemFont(ofSize: Style.contextFontSize, weight: .medium)
        label[.foregroundColor] = NSColor.secondaryLabelColor
        startBlock(base)
        for (n, item) in items.enumerated() {
            if n > 0 { append(Style.contextSeparator, base) }
            if item.key == "script" {
                append(item.value, base)
            } else {
                append(ToolDetailText.contextLabel(item.key), label)
                append(" " + item.value, base)
            }
        }
    }

    private struct FooterChip {
        enum Kind { case status, duration, other }
        var text: String
        var color: NSColor
        var bold: Bool
        var kind: Kind
    }

    /// Footer chips in the order exit, duration, truncation, persisted, notes, and the bracket the
    /// builder wrote into `plainText` from the same status and duration (`[exit 2 · 48s]`).
    private func footerFacts(_ action: ToolAction) -> (chips: [FooterChip], bracket: String?) {
        var chips: [FooterChip] = []
        var exitCode: Int?
        var wallTime: Double?
        for fact in action.facts {
            switch fact.kind {
            case .exitCode(let code): if exitCode == nil { exitCode = code }
            case .wallTime(let seconds): if wallTime == nil { wallTime = seconds }
            default: break
            }
        }
        if exitCode == nil, case .failed(let code?) = action.status { exitCode = code }
        if let exitCode {
            chips.append(FooterChip(text: ToolChip.exit(exitCode), color: exitCode == 0 ? .tertiaryLabelColor : .systemRed,
                                    bold: exitCode != 0, kind: .status))
        } else {
            switch action.status {
            case .failed(nil): chips.append(FooterChip(text: ToolChip.error, color: .systemRed, bold: true, kind: .status))
            case .rejected: chips.append(FooterChip(text: ToolChip.rejected, color: .tertiaryLabelColor, bold: false, kind: .status))
            case .interrupted: chips.append(FooterChip(text: ToolChip.interrupted, color: .tertiaryLabelColor, bold: false, kind: .status))
            default: break
            }
        }
        if let seconds = wallTime ?? (invocation.actions.count == 1 ? invocation.durationSeconds : nil) {
            chips.append(FooterChip(text: TranscriptTurnTiming.formatDuration(seconds), color: .tertiaryLabelColor,
                                    bold: false, kind: .duration))
        }
        let bracket = chips.isEmpty ? nil : chips.map(\.text).joined(separator: Style.factSeparator)
        for fact in action.facts {
            if case .truncated(let agent, let tokens, let lines) = fact.kind {
                var text = ToolChip.cutBy(agent)
                if let lines { text += Style.factSeparator + ToolChip.lines(lines) }
                else if let tokens { text += Style.factSeparator + ToolDetailText.tokens(tokens) }
                chips.append(FooterChip(text: text, color: .systemOrange, bold: false, kind: .other))
            }
        }
        for fact in action.facts {
            if case .persisted(_, let bytes) = fact.kind {
                let size = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                chips.append(FooterChip(text: ToolDetailText.savedToFile(size: size), color: .tertiaryLabelColor,
                                        bold: false, kind: .other))
            }
        }
        for fact in action.facts {
            if case .note(let note) = fact.kind {
                chips.append(FooterChip(text: note, color: .tertiaryLabelColor, bold: false, kind: .other))
            }
        }
        return (chips, bracket)
    }

    /// `bracketBase` is where the bracket line's "[" sits in `plainText`, when it matches.
    private mutating func footerLine(_ chips: [FooterChip], index: Int, bracketBase: Int?) {
        let base = proseBase(size: Style.footerFontSize, color: .tertiaryLabelColor)
        startBlock(base)
        var bracketCursor = bracketBase.map { $0 + 1 }
        for (n, chip) in chips.enumerated() {
            if n > 0 { append(Style.factSeparator, base) }
            var attrs = base
            attrs[.foregroundColor] = chip.color
            if chip.bold { attrs[.font] = NSFont.systemFont(ofSize: Style.footerFontSize, weight: .semibold) }
            let range = append(chip.text, attrs)
            if chip.kind != .other, let cursor = bracketCursor {
                map(range, index: index, source: cursor)
                bracketCursor = cursor + range.length + (Style.factSeparator as NSString).length
            }
        }
    }

    // MARK: Command and heredoc

    private mutating func commandPane(_ command: String, action: ToolAction, index: Int, layout: PlainLayout,
                                      terminator: String?) {
        beginPane()
        let state = folds[index] ?? FoldState()
        let textStart = pad + 2 * advance
        let columns = ToolTextBudget.columns(width: width - textStart - pad, font: mono)
        let first = monoStyle(firstLine: pad, rest: textStart, tabBase: textStart, columns: columns)
        let rest = monoStyle(firstLine: textStart, rest: textStart, tabBase: textStart, columns: columns)
        var prompt = textAttrs()
        prompt[.foregroundColor] = NSColor.tertiaryLabelColor
        let lead = [LeadRun(text: "$ ", attrs: prompt, copy: true, source: layout.prompt)]

        let folded = ToolTextBudget.foldCommand(command, columns: columns, state: inputState(state, for: command))
        monoText(command, folded: folded, kind: .input(action: index), lead: .firstLine(lead),
                 firstStyle: first, restStyle: rest, columns: columns, mapIndex: index, mapBase: layout.command)

        if let heredoc = action.heredoc, !heredoc.text.isEmpty {
            let lineCount = Self.lineCount(heredoc.text)
            let gutter = gutterStyle(maxNumber: lineCount)
            let folded = ToolTextBudget.foldCommand(heredoc.text, columns: gutter.columns,
                                                    state: inputState(state, for: heredoc.text))
            monoText(heredoc.text, folded: folded, kind: .input(action: index), lead: .gutter(nil),
                     firstStyle: gutter.style, restStyle: gutter.style, columns: gutter.columns,
                     mapIndex: index, mapBase: layout.heredoc)
        }
        if let terminator {
            paneBlock(rest)
            let range = append(terminator, textAttrs())
            if let source = layout.terminator { map(range, index: index, source: source) }
        }
        endPane()
    }

    /// The command-pane fold state: `commandShowAll` opens everything, cut lines included; otherwise
    /// no cut line is open (`openedLongLines` belongs to the output pane).
    private func inputState(_ state: FoldState, for text: String) -> FoldState {
        var result = FoldState()
        result.commandShowAll = state.commandShowAll
        if state.commandShowAll { result.openedLongLines = Set(0..<Self.lineCount(text)) }
        return result
    }

    /// The word a heredoc opener on the first line names (`<<'EOF'`, `<<"EOF"`, `<<EOF`, `<<-EOF`):
    /// the same opener rule as the builder's split, which keeps only the terminator's line out of
    /// `heredoc`. Nil when there is none.
    static func heredocTerminator(_ command: String) -> String? {
        let first = command[..<(command.firstIndex(of: "\n") ?? command.endIndex)]
        var cursor = first.startIndex
        while let hit = first.range(of: "<<", options: .literal, range: cursor..<first.endIndex) {
            cursor = first.index(after: hit.lowerBound)
            let before = hit.lowerBound > first.startIndex ? first[first.index(before: hit.lowerBound)] : " "
            let after = hit.upperBound < first.endIndex ? first[hit.upperBound] : " "
            guard before != "<", after != "<" else { continue }
            var rest = first[hit.upperBound...]
            if rest.first == "-" { rest = rest.dropFirst() }
            rest = rest.drop { $0 == " " }
            if let quote = rest.first, quote == "'" || quote == "\"" {
                let body = rest.dropFirst()
                guard let close = body.firstIndex(of: quote) else { return nil }
                return body[..<close].isEmpty ? nil : String(body[..<close])
            }
            let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
            return word.isEmpty ? nil : String(word)
        }
        return nil
    }

    // MARK: Generic fields

    private mutating func fieldsPane(_ action: ToolAction, index: Int, layout: PlainLayout) {
        beginPane()
        let state = folds[index] ?? FoldState()
        let keyWidths = action.inputFields.map { ToolTextBudget.visualWidth(of: Substring($0.key)) }
        let keyColumns = min(Style.fieldKeyMaxColumns, keyWidths.max() ?? 0)
        let valueStart = pad + CGFloat(keyColumns + 2) * advance
        let columns = ToolTextBudget.columns(width: width - valueStart - pad, font: mono)
        let first = monoStyle(firstLine: pad, rest: valueStart, tabBase: valueStart, columns: columns)
        let rest = monoStyle(firstLine: valueStart, rest: valueStart, tabBase: valueStart, columns: columns)
        var keyAttrs = textAttrs()
        keyAttrs[.foregroundColor] = NSColor.secondaryLabelColor

        for (n, field) in action.inputFields.enumerated() {
            let padding = String(repeating: " ", count: max(2, keyColumns + 2 - keyWidths[n]))
            let lead = [LeadRun(text: field.key, attrs: keyAttrs, copy: true, source: layout.fieldKeys[n]),
                        LeadRun(text: padding, attrs: textAttrs(), copy: true, source: nil)]
            let valueBase = layout.fieldValues[n]
            if case .string(let text) = field.value {
                let folded = ToolTextBudget.foldCommand(text, columns: columns, state: inputState(state, for: text))
                monoText(text, folded: folded, kind: .input(action: index), lead: .firstLine(lead),
                         firstStyle: first, restStyle: rest, columns: columns, mapIndex: index, mapBase: valueBase)
                continue
            }
            paneBlock(first)
            appendLead(lead, index: index)
            let value = ToolInvocationBuilder.plainValue(field.value)
            let shown = value.count > Style.nestedValueLimit ? String(value.prefix(Style.nestedValueLimit)) : value
            let range = append(shown, textAttrs())
            if let valueBase { map(range, index: index, source: valueBase) }
            if shown.count < value.count {
                var muted = textAttrs()
                muted[.foregroundColor] = NSColor.tertiaryLabelColor
                muted[.font] = NSFont.systemFont(ofSize: Style.foldFontSize)
                append(Style.controlBreak, textAttrs(), copy: false)
                append(ToolDetailText.hiddenCharacters(value.count - shown.count), muted, copy: false)
            }
        }
        endPane()
    }

    // MARK: Output

    private mutating func outputPane(_ decoded: DecodedText, key: Int, isError: Bool, mapIndex: Int, mapBase: Int?) {
        beginPane()
        switch decoded.shape {
        case .image, .binary:
            let style = monoStyle(firstLine: pad, rest: pad, tabBase: pad, columns: 1)
            paneBlock(style)
            var muted = textAttrs()
            muted[.foregroundColor] = NSColor.tertiaryLabelColor
            let range = append(decoded.text, muted)
            if let mapBase { map(range, index: mapIndex, source: mapBase) }
        case .lineNumbered(let numbers):
            let gutter = gutterStyle(maxNumber: numbers.compactMap { $0 }.max() ?? 0)
            let folded = ToolTextBudget.fold(decoded.text, columns: gutter.columns, isError: isError,
                                             state: folds[key] ?? FoldState())
            monoText(decoded.text, folded: folded, kind: .output(key: key), lead: .gutter(numbers),
                     firstStyle: gutter.style, restStyle: gutter.style, columns: gutter.columns,
                     mapIndex: mapIndex, mapBase: mapBase)
        case .plain, .json, .jsonLines, .markdown:
            let columns = ToolTextBudget.columns(width: width - 2 * pad, font: mono)
            let style = monoStyle(firstLine: pad, rest: pad, tabBase: pad, columns: columns)
            let folded = ToolTextBudget.fold(decoded.text, columns: columns, isError: isError,
                                             state: folds[key] ?? FoldState())
            monoText(decoded.text, folded: folded, kind: .output(key: key), lead: .none,
                     firstStyle: style, restStyle: style, columns: columns, mapIndex: mapIndex, mapBase: mapBase)
        }
        endPane()
    }

    // MARK: Mono text

    private enum PaneKind {
        /// An output pane; `key` is the action index (`actions.count` for the script output).
        case output(key: Int)
        /// A command, heredoc or input-field pane of action `action`.
        case input(action: Int)
    }

    private struct LeadRun {
        var text: String
        var attrs: Attrs
        var copy: Bool
        /// Where the run's text sits in the mapped plain text, when it does.
        var source: Int?
    }

    private enum Lead {
        case none
        /// Runs before the first logical line (the `$ ` prompt, a field key).
        case firstLine([LeadRun])
        /// A gutter number before every line: `numbers[i]`, or `i + 1` when `numbers` is nil.
        case gutter([Int?]?)
    }

    /// Renders folded text into the open pane: one block per run of plain lines (one run per line
    /// when each line has a lead), cut lines with their "… +N chars" control, fold rows.
    private mutating func monoText(_ text: String, folded: FoldedText, kind: PaneKind, lead: Lead,
                                   firstStyle: NSParagraphStyle, restStyle: NSParagraphStyle, columns: Int,
                                   mapIndex: Int, mapBase: Int?) {
        if folded.segments.isEmpty {
            if case .firstLine(let runs) = lead {
                paneBlock(firstStyle)
                appendLead(runs, index: mapIndex)
            }
            return
        }
        var text = text
        let ascii = text.utf8.count == text.utf16.count
        let attrs = textAttrs()
        text.withUTF8 { bytes in
            let lines = LineTable(bytes, ascii: ascii)
            for (position, segment) in folded.segments.enumerated() {
                switch segment {
                case .lines(let range):
                    switch lead {
                    case .gutter(let numbers):
                        for line in range {
                            paneBlock(firstStyle)
                            appendGutter(number(line, numbers))
                            appendLines(bytes, lines, line..<(line + 1), attrs, mapIndex: mapIndex, mapBase: mapBase)
                        }
                    case .firstLine(let runs) where range.lowerBound == 0:
                        paneBlock(firstStyle)
                        appendLead(runs, index: mapIndex)
                        appendLines(bytes, lines, 0..<1, attrs, mapIndex: mapIndex, mapBase: mapBase)
                        if range.count > 1 {
                            paneBlock(restStyle)
                            appendLines(bytes, lines, 1..<range.upperBound, attrs, mapIndex: mapIndex, mapBase: mapBase)
                        }
                    default:
                        paneBlock(range.lowerBound == 0 ? firstStyle : restStyle)
                        appendLines(bytes, lines, range, attrs, mapIndex: mapIndex, mapBase: mapBase)
                    }
                case .longLineCut(let line, let hiddenChars):
                    paneBlock(line == 0 ? firstStyle : restStyle)
                    switch lead {
                    case .gutter(let numbers): appendGutter(number(line, numbers))
                    case .firstLine(let runs) where line == 0: appendLead(runs, index: mapIndex)
                    default: break
                    }
                    let full = String(decoding: UnsafeBufferPointer(rebasing: bytes[lines.u8Start[line]..<lines.u8End[line]]),
                                      as: UTF8.self)[...]
                    let keptEnd = ToolTextBudget.keptPrefixEnd(of: full, columns: columns)
                    assert(full.distance(from: keptEnd, to: full.endIndex) == hiddenChars,
                           "the shown prefix and the budget's hiddenChars must agree")
                    let range = append(String(full[..<keptEnd]), attrs)
                    if let mapBase { map(range, index: mapIndex, source: mapBase + lines.u16Start[line]) }
                    let control: ToolFoldLink
                    switch kind {
                    case .output(let key): control = .openLongLine(action: key, line: line)
                    case .input(let action): control = .showFullCommand(action: action)
                    }
                    var linkBase = attrs
                    linkBase[.font] = NSFont.systemFont(ofSize: Style.foldFontSize)
                    append(Style.controlBreak, attrs, copy: false)
                    link(ToolDetailText.hiddenCharacters(hiddenChars), control, base: linkBase)
                case .fold(let hidden):
                    let capped = folded.hitShowAllCap && position == folded.segments.count - 1
                    foldRow(hidden: hidden, kind: kind, capped: capped)
                }
            }
        }
    }

    private func number(_ line: Int, _ numbers: [Int?]?) -> Int? {
        guard let numbers else { return line + 1 }
        return line < numbers.count ? numbers[line] : nil
    }

    private mutating func appendLines(_ bytes: UnsafeBufferPointer<UInt8>, _ lines: LineTable, _ range: Range<Int>,
                                      _ attrs: Attrs, mapIndex: Int, mapBase: Int?) {
        let start = lines.u8Start[range.lowerBound], end = lines.u8End[range.upperBound - 1]
        let rendered = append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self), attrs)
        if let mapBase { map(rendered, index: mapIndex, source: mapBase + lines.u16Start[range.lowerBound]) }
    }

    private mutating func appendLead(_ runs: [LeadRun], index: Int) {
        for run in runs {
            let range = append(run.text, run.attrs, copy: run.copy)
            if let source = run.source { map(range, index: index, source: source) }
        }
    }

    private mutating func appendGutter(_ number: Int?) {
        var attrs = textAttrs()
        attrs[.foregroundColor] = NSColor.tertiaryLabelColor
        attrs[.toolGutter] = true
        append("\t" + (number.map(String.init) ?? "") + "\t", attrs, copy: false)
    }

    private mutating func foldRow(hidden: Int, kind: PaneKind, capped: Bool) {
        paneBlock(foldStyle(), font: NSFont.systemFont(ofSize: Style.foldFontSize), color: .secondaryLabelColor)
        let base = blockBase
        switch kind {
        case .output(let key):
            if capped {
                append(ToolDetailText.moreLinesPastLimit(hidden), base, copy: false)
            } else {
                append(ToolDetailText.moreLines(hidden), base, copy: false)
                if hidden > ToolTextBudget.showMoreStep {
                    append(Style.factSeparator, base, copy: false)
                    link(ToolDetailText.showMore(ToolTextBudget.showMoreStep), .showMore(action: key), base: base)
                }
                append(Style.factSeparator, base, copy: false)
                link(ToolDetailText.showAll, .showAll(action: key), base: base)
            }
            append(Style.factSeparator, base, copy: false)
            link(ToolDetailText.copyOutput, .copyOutput(action: key), base: base)
        case .input(let action):
            append(ToolDetailText.moreLines(hidden), base, copy: false)
            append(Style.factSeparator, base, copy: false)
            link(ToolDetailText.showAll, .showFullCommand(action: action), base: base)
        }
    }

    // MARK: Blocks

    /// Starts a block. The open block ends first, with a "\n" in its own base attributes.
    private mutating func startBlock(_ base: Attrs) {
        if blockOpen {
            if blockCopyable { copyBlocks.append(blockCopy) }
            out.append(NSAttributedString(string: "\n", attributes: blockBase))
        }
        blockOpen = true
        blockBase = base
        blockCopy = ""
        blockCopyable = false
        blockIsSpacer = false
    }

    /// An empty line `height` points tall: unfilled between parts, filled as a pane's top and
    /// bottom padding. `copyable` makes it a blank line in the copy text.
    private mutating func gap(_ height: CGFloat, copyable: Bool = false, filled: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        var base: Attrs = [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style]
        if filled {
            base[.backgroundColor] = paneFill
            base[.markdownCodeBlockBg] = paneFill
        }
        startBlock(base)
        blockCopyable = copyable
        blockIsSpacer = true
    }

    /// Appends a run inside the open block; the block's base attributes fill in what `attrs` leaves
    /// out (above all the paragraph style, which every character of a paragraph must carry).
    @discardableResult
    private mutating func append(_ text: String, _ attrs: Attrs, copy: Bool = true) -> NSRange {
        let start = out.length
        out.append(NSAttributedString(string: text, attributes: attrs.merging(blockBase) { run, _ in run }))
        if copy {
            blockCopy += text
            blockCopyable = true
        }
        return NSRange(location: start, length: out.length - start)
    }

    private mutating func link(_ title: String, _ action: ToolFoldLink, base: Attrs) {
        var attrs = base
        attrs[.link] = action.url
        attrs[.foregroundColor] = NSColor.linkColor
        if let font = base[.font] as? NSFont {
            attrs[.font] = NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
        }
        let range = append(title, attrs, copy: false)
        foldLinks.append((range: range, action: action))
    }

    private mutating func map(_ rendered: NSRange, index: Int, source: Int) {
        guard rendered.length > 0 else { return }
        sourceMap.append((rendered: rendered, actionIndex: index, source: NSRange(location: source, length: rendered.length)))
    }

    // MARK: Panes

    /// Opens a pane with a filled padding line. Filled lines, not paragraph spacing: TextKit 1 paints
    /// `.backgroundColor` over whole line fragments only from the run's second line on (its first
    /// line starts at the first glyph), and never over paragraph spacing. A spacer line whose "\n"
    /// sits at x = 0 starts the fill at the left edge, so every pane line is filled edge to edge.
    private mutating func beginPane() {
        paneFill = MarkdownStyle.codeBlockBackground
        gap(Style.paneVerticalPadding, filled: true)
    }

    /// Starts a pane line block: pane fill, the given paragraph style, mono text unless overridden.
    private mutating func paneBlock(_ style: NSParagraphStyle, font: NSFont? = nil, color: NSColor = .labelColor) {
        startBlock([.font: font ?? mono, .foregroundColor: color, .paragraphStyle: style,
                    .backgroundColor: paneFill, .markdownCodeBlockBg: paneFill])
    }

    /// Closes a pane with a filled padding line.
    private mutating func endPane() {
        gap(Style.paneVerticalPadding, filled: true)
    }

    // MARK: Attributes

    private func textAttrs() -> Attrs {
        [.font: mono, .foregroundColor: NSColor.labelColor, .backgroundColor: paneFill, .markdownCodeBlockBg: paneFill]
    }

    private func proseBase(size: CGFloat, color: NSColor) -> Attrs {
        [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: NSParagraphStyle.default]
    }

    /// Mono pane lines: inset by the pane padding, wrapped by character, tab stops every 4 columns
    /// from `tabBase` (the text start), so the layout matches `ToolTextBudget`'s column math.
    private func monoStyle(firstLine: CGFloat, rest: CGFloat, tabBase: CGFloat, columns: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = firstLine
        style.headIndent = rest
        style.tailIndent = -pad
        style.lineBreakMode = .byCharWrapping
        style.tabStops = tabStops(from: tabBase, columns: columns)
        style.defaultTabInterval = 4 * advance
        return style
    }

    /// A numbered pane: the number right-aligned in its column, the text after a 2-column gap.
    private func gutterStyle(maxNumber: Int) -> (style: NSParagraphStyle, columns: Int) {
        let digits = max(2, String(max(0, maxNumber)).count)
        let numberEnd = pad + CGFloat(digits) * advance
        let textStart = numberEnd + Style.gutterGapColumns * advance
        let columns = ToolTextBudget.columns(width: width - textStart - pad, font: mono)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = pad
        style.headIndent = textStart
        style.tailIndent = -pad
        style.lineBreakMode = .byCharWrapping
        style.tabStops = [NSTextTab(textAlignment: .right, location: numberEnd),
                          NSTextTab(textAlignment: .left, location: textStart)]
            + tabStops(from: textStart, columns: columns)
        style.defaultTabInterval = 4 * advance
        return (style, columns)
    }

    private func tabStops(from base: CGFloat, columns: Int) -> [NSTextTab] {
        (1...(max(0, columns) / 4 + 2)).map { NSTextTab(textAlignment: .left, location: base + CGFloat($0 * 4) * advance) }
    }

    private func foldStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = pad
        style.headIndent = pad
        style.tailIndent = -pad
        return style
    }

    // MARK: Finish

    /// A body that ends with a pane keeps the pane's bottom padding line (its "\n" is the last
    /// character; the extra line fragment after it takes the spacer's fixed height).
    mutating func finish() -> RenderedToolBody {
        if blockOpen, blockCopyable { copyBlocks.append(blockCopy) }
        if blockOpen, blockIsSpacer { out.append(NSAttributedString(string: "\n", attributes: blockBase)) }
        blockOpen = false
        return RenderedToolBody(attributed: NSAttributedString(attributedString: out),
                                plainCopyText: copyBlocks.joined(separator: "\n"),
                                sourceMap: sourceMap, foldLinks: foldLinks)
    }

    // MARK: Helpers

    private func isFailure(_ status: ToolStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    /// Logical lines in `ToolTextBudget`'s sense, at most one too many (enough for an open-all set).
    static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }
}

// MARK: - Plain-text layout

/// Where an action's pieces sit in its `plainText` (UTF-16 locations), from the builder's form:
/// `$ <exactCommand>` (or the verb line and `key: value` lines), the `[bracket]` line, the output.
/// A piece is nil when the plain text does not hold it verbatim at that place, so a mismatch maps
/// nothing rather than something wrong.
private struct PlainLayout {
    var prompt: Int?
    var command: Int?
    var heredoc: Int?
    var terminator: Int?
    var fieldKeys: [Int?] = []
    var fieldValues: [Int?] = []
    /// The bracket line's "[".
    var bracket: Int?
    var output: Int?

    init(_ action: ToolAction, bracket bracketText: String?, terminator word: String?) {
        fieldKeys = Array(repeating: nil, count: action.inputFields.count)
        fieldValues = fieldKeys
        var plain = action.plainText
        let plainLength = plain.utf16.count
        plain.withUTF8 { bytes in
            var cursor8 = 0, cursor16 = 0
            var inputMatched = false
            if let exact = action.exactCommand {
                let head = "$ " + exact
                if bytes.holds(head, at: 0) {
                    inputMatched = true
                    prompt = 0
                    cursor8 = head.utf8.count
                    cursor16 = head.utf16.count
                    locateCommand(in: exact, action: action, terminator: word)
                }
            } else {
                let verbLine = [ToolVerb.text(action.verbKey), action.object].filter { !$0.isEmpty }.joined(separator: " ")
                if bytes.holds(verbLine, at: 0) {
                    inputMatched = true
                    cursor8 = verbLine.utf8.count
                    cursor16 = verbLine.utf16.count
                    for (n, field) in action.inputFields.enumerated() {
                        let key = "\n" + field.key + ": "
                        let line = key + ToolInvocationBuilder.plainValue(field.value)
                        guard bytes.holds(line, at: cursor8) else { inputMatched = false; break }
                        fieldKeys[n] = cursor16 + 1
                        fieldValues[n] = cursor16 + key.utf16.count
                        cursor8 += line.utf8.count
                        cursor16 += line.utf16.count
                    }
                }
            }
            if inputMatched, let bracketText, bytes.holds("\n[" + bracketText + "]", at: cursor8) {
                bracket = cursor16 + 1
            }
            if let text = action.output?.text, !text.isEmpty, bytes.holds(text, at: bytes.count - text.utf8.count) {
                output = plainLength - text.utf16.count
            }
        }
    }

    /// The display command, heredoc body and terminator inside `exact`, in order (offset 2 for "$ ").
    private mutating func locateCommand(in exact: String, action: ToolAction, terminator word: String?) {
        guard let command = action.command, !command.isEmpty,
              let found = exact.range(of: command, options: .literal) else { return }
        func location(_ index: String.Index) -> Int { 2 + exact.utf16.distance(from: exact.startIndex, to: index) }
        self.command = location(found.lowerBound)
        var after = found.upperBound
        if let body = action.heredoc?.text, !body.isEmpty {
            guard let range = exact.range(of: body, options: .literal, range: after..<exact.endIndex) else { return }
            heredoc = location(range.lowerBound)
            after = range.upperBound
        }
        if let word, let range = exact.range(of: word, options: .literal, range: after..<exact.endIndex) {
            terminator = location(range.lowerBound)
        }
    }
}

// MARK: - Lines

/// Logical lines of a UTF-8 buffer, split on "\n" exactly like `ToolTextBudget` (one trailing "\n"
/// adds no line), with byte and UTF-16 bounds.
private struct LineTable {
    var u8Start: [Int] = []
    var u8End: [Int] = []
    var u16Start: [Int] = []

    init(_ bytes: UnsafeBufferPointer<UInt8>, ascii: Bool) {
        guard let base = bytes.baseAddress else { return }
        let n = bytes.count
        var pos = 0
        var u16 = 0
        while pos < n {
            var end = n
            if let hit = memchr(base + pos, 0x0A, n - pos) {
                end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
            var length = end - pos
            if !ascii {
                length = 0
                var i = pos
                while i < end {
                    let b = base[i]
                    if b & 0xC0 != 0x80 { length += b >= 0xF0 ? 2 : 1 }
                    i += 1
                }
            }
            u8Start.append(pos)
            u8End.append(end)
            u16Start.append(u16)
            u16 += length + 1
            pos = end + 1
        }
    }
}

private extension UnsafeBufferPointer where Element == UInt8 {
    /// True when the UTF-8 of `text` sits at byte `offset`.
    func holds(_ text: String, at offset: Int) -> Bool {
        var text = text
        return text.withUTF8 { needle in
            guard offset >= 0, offset + needle.count <= count else { return false }
            guard let base = baseAddress, let other = needle.baseAddress else { return needle.isEmpty }
            return memcmp(base + offset, other, needle.count) == 0
        }
    }
}
