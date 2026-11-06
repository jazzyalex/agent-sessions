import AppKit
import SwiftUI

// Tool rows of the Session view (tool rendering Task 13, spec §6.1, §6.6, §6.7): a group header
// row (L0) and one row per invocation (L1 action lines, L2 detail below them when open). The
// rows of one group join into one card with one continuous accent bar; `BlockTableController`
// owns the state and the heights, these cells only draw.

// MARK: - Geometry

/// Tool row geometry, shared by the cells and the controller's height math.
enum ToolRowMetrics {
    /// One L1 action line, and the group header line (spec §6.1: 24 pt).
    static let lineHeight: CGFloat = 24
    /// Space between a card edge that does not join a neighbour and the line next to it.
    static let cardEdgePad: CGFloat = 2
    /// Group header card: its 24 pt line plus 4 pt (2 above, 2 below).
    static let headerCardHeight: CGFloat = lineHeight + 2 * cardEdgePad
    static let chevronWidth: CGFloat = 10
    static let iconWidth: CGFloat = 14
    /// Gap between the items of a line (the 4.2 card header's spacing).
    static let itemSpacing: CGFloat = 6
    /// The L2 body starts under the category icon.
    static let bodyLeadingIndent: CGFloat = chevronWidth + itemSpacing
    static let bodyTopGap: CGFloat = CardMetrics.headerToBodyGap
    static let bodyBottomInset: CGFloat = CardMetrics.bodyBottomInset
    /// Below this body width (before the first layout) no L2 render starts.
    static let minimumRenderWidth: CGFloat = 80

    /// An invocation card: one line per action, then the L2 body when it is shown, padded at
    /// the edges that do not join a neighbour.
    static func invocationCardHeight(lineCount: Int, edges: ToolCardEdges, bodyHeight: CGFloat?) -> CGFloat {
        var height = (edges.joinedTop ? 0 : cardEdgePad) + CGFloat(max(1, lineCount)) * lineHeight
        if let bodyHeight, bodyHeight > 0 { height += bodyTopGap + bodyHeight + bodyBottomInset }
        return height + (edges.joinedBottom ? 0 : cardEdgePad)
    }
}

/// How a tool row's card meets its neighbours (spec §6.7 joined chrome). The header row is the
/// top of its group's card; the open group's invocation rows continue it (`first` / `middle`
/// below the header, `last` closes it). A joined edge has no gap and square corners, so the
/// accent bar runs on into the next row. A lone invocation (`solo`, no group) is a full card;
/// a lone visible row of a filtered group (`solo` with a group id) closes its header's card.
struct ToolCardEdges: Equatable {
    var joinedTop: Bool
    var joinedBottom: Bool
    /// A hairline at the top: between two invocation rows of a group.
    var showsSeparator: Bool

    static func header(_ header: ToolGroupHeaderModel) -> ToolCardEdges {
        ToolCardEdges(joinedTop: false, joinedBottom: header.isOpen, showsSeparator: false)
    }

    static func invocation(_ model: ToolInvocationRowModel) -> ToolCardEdges {
        guard model.groupID != nil else {
            return ToolCardEdges(joinedTop: false, joinedBottom: false, showsSeparator: false)
        }
        return ToolCardEdges(joinedTop: true,
                             joinedBottom: model.position == .first || model.position == .middle,
                             showsSeparator: model.position == .middle || model.position == .last)
    }
}

// MARK: - Text

/// User-facing strings of the group header.
enum ToolGroupText {
    static func title(callCount: Int) -> String {
        String(localized: "\(callCount) tool calls",
               comment: "Header of a collapsed transcript card that groups several tool calls. The number is the call count.")
    }

    static func failed(_ count: Int) -> String {
        String(localized: "\(count) failed",
               comment: "Transcript tool group header pill: how many of the group's tool calls failed. %lld is the count.")
    }

    static func digestEntry(verb: String, count: Int) -> String {
        String(localized: "tool.group.digestEntry", defaultValue: "\(verb) \(count)",
               comment: "Transcript tool group header: a verb and how many of the group's actions used it, for example Ran 3. The first value is the verb, the second the count.")
    }

    /// "Ran 3 · Read 2 · Edited 1 · …" (spec §6.1: up to three verbs, then "…").
    static func digest(_ verbs: [VerbCount], hasMoreVerbs: Bool) -> String {
        var parts = verbs.map { digestEntry(verb: ToolVerb.text($0.verbKey), count: $0.count) }
        if hasMoreVerbs { parts.append("…") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - SwiftUI lines

/// One L1 line: an action of an invocation.
struct ToolActionLine: Equatable {
    var action: ToolRowAction
    /// The first action line carries the disclosure chevron and the duration.
    var isFirst: Bool
    var durationText: String?
}

struct ToolDisclosureChevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .frame(width: ToolRowMetrics.chevronWidth)
    }
}

/// The find-match count of a tool row whose matches do not paint in place.
struct ToolFindCountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            // Dynamic colors only: label text on a systemYellow tint reads in light, dark and
            // Increase Contrast (each resolves per appearance).
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(Color(nsColor: .systemYellow).opacity(0.55)))
            .help("\(count) find matches in this collapsed card")
            .accessibilityLabel("\(count) find matches, collapsed")
            .fixedSize()
    }
}

/// An L1 action line (spec §6.1, §6.6), fixed 24 pt: chevron (first line only), category icon
/// (red when the action failed), verb, object (SF Mono, or the system font for an agent label)
/// cut at the tail with its detail, result chips (the failure chip red), duration.
struct ToolActionRowHeader: View {
    let line: ToolActionLine
    let isOpen: Bool
    let findMatchCount: Int

    private var isFailed: Bool {
        if case .failed = line.action.status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: ToolRowMetrics.itemSpacing) {
            ToolDisclosureChevron(isOpen: isOpen)
                .opacity(line.isFirst ? 1 : 0)
            Image(systemName: ToolCategoryMap.symbolName(line.action.category))
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: isFailed ? .systemRed : .secondaryLabelColor))
                .frame(width: ToolRowMetrics.iconWidth)
            Text(verbatim: ToolVerb.text(line.action.verbKey))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .fixedSize()
            objectText
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(line.action.chips.enumerated()), id: \.offset) { offset, chip in
                let isFailureChip = offset == 0 && isFailed
                Text(verbatim: chip)
                    .font(.system(size: 10.5, weight: isFailureChip ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: isFailureChip ? .systemRed : .tertiaryLabelColor))
                    .lineLimit(1)
                    .fixedSize()
            }
            if findMatchCount > 0 {
                ToolFindCountPill(count: findMatchCount)
            }
            if let durationText = line.durationText {
                Text(verbatim: durationText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: ToolRowMetrics.lineHeight)
    }

    private var objectText: Text {
        let action = line.action
        let font: Font = action.objectIsAgentLabel ? .system(size: 12) : .system(size: 12, design: .monospaced)
        var text = Text(verbatim: action.object).font(font).foregroundStyle(Color(nsColor: .labelColor))
        if let detail = action.objectDetail, !detail.isEmpty {
            text = text + Text(verbatim: "  " + detail)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        return text
    }
}

/// An invocation's L1 lines. A click anywhere on a line toggles the invocation's L2; Option-click
/// toggles every invocation of its group. While the pointer is over a line, Copy and Raw buttons
/// appear at its trailing edge (spec §6.6).
struct ToolActionLines: View {
    let lines: [ToolActionLine]
    let isOpen: Bool
    let findMatchCount: Int
    let onToggle: (_ allInGroup: Bool) -> Void
    /// Copy the line's action (its plain text).
    var onCopy: (_ actionIndex: Int) -> Void = { _ in }
    /// Show the raw event of the invocation, anchored at the line.
    var onRaw: (_ actionIndex: Int) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                ToolActionLineButton(line: line, index: offset, isOpen: isOpen,
                                     findMatchCount: offset == 0 ? findMatchCount : 0,
                                     onToggle: onToggle, onCopy: onCopy, onRaw: onRaw)
            }
        }
    }
}

/// One L1 line as a button, with the hover Copy and Raw buttons and its VoiceOver label.
struct ToolActionLineButton: View {
    let line: ToolActionLine
    let index: Int
    let isOpen: Bool
    let findMatchCount: Int
    let onToggle: (_ allInGroup: Bool) -> Void
    let onCopy: (_ actionIndex: Int) -> Void
    let onRaw: (_ actionIndex: Int) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                onToggle(NSEvent.modifierFlags.contains(.option))
            } label: {
                ToolActionRowHeader(line: line, isOpen: isOpen, findMatchCount: findMatchCount)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ToolAccessibility.label(for: line.action))
            .accessibilityValue(ToolAccessibility.disclosureValue(isOpen: isOpen))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(verbatim: ToolMenuText.copy)) { onCopy(index) }
            .accessibilityAction(named: Text(verbatim: ToolMenuText.showRawEvent)) { onRaw(index) }

            if hovering {
                HStack(spacing: 2) {
                    ToolHoverButton(symbol: "doc.on.doc", help: ToolMenuText.copy, action: { onCopy(index) })
                    ToolHoverButton(symbol: "curlybraces", help: ToolMenuText.showRawEvent, action: { onRaw(index) })
                }
                .padding(.horizontal, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.trailing, 2)
            }
        }
        .frame(height: ToolRowMetrics.lineHeight)
        .onHover { hovering = $0 }
    }
}

/// A small icon button of the hover cluster.
struct ToolHoverButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Menu text

/// Titles of the invocation row's context menu and hover buttons.
enum ToolMenuText {
    static var copy: String {
        String(localized: "Copy", comment: "Command in a transcript or image context menu.")
    }
    static var copyCommand: String {
        String(localized: "Copy Command", comment: "Transcript tool row context menu: copies the shell command of the call.")
    }
    static var copyOutput: String {
        String(localized: "Copy Output", comment: "Transcript tool row context menu: copies the decoded output of the call.")
    }
    static var copyAsMarkdown: String {
        String(localized: "Copy as Markdown", comment: "Transcript tool row context menu: copies the call as Markdown, one fenced block per action.")
    }
    static var showRawEvent: String {
        String(localized: "Show Raw Event", comment: "Transcript tool row context menu and hover button: shows the raw JSON of the call and its output.")
    }
    static var expandAllInGroup: String {
        String(localized: "Expand All in Group", comment: "Transcript tool row context menu: opens every tool call of the group.")
    }
    static var speak: String {
        String(localized: "Speak", comment: "Command in a transcript or image context menu.")
    }
    static var stopSpeaking: String {
        String(localized: "Stop Speaking", comment: "Command in a transcript or image context menu.")
    }
    static var contextMenuTitle: String {
        String(localized: "Tool call", comment: "Title of the context menu of a transcript tool call row.")
    }
    static var rawNotice: String {
        String(localized: "Large strings were shortened when the app stored this event.",
               comment: "Notice in the raw event popover of a tool call: very long strings in the stored event were cut.")
    }
    static var rawMissing: String {
        String(localized: "No raw event was stored for this call.",
               comment: "Text in the raw event popover of a tool call when the session holds no raw event for it.")
    }
}

// MARK: - VoiceOver

/// VoiceOver text of the tool rows (spec §6.6): `"<verb> <object>, <status>, <chips joined>"`, with
/// the expanded state as the element's value.
enum ToolAccessibility {
    /// The status in a word; nil when the status is unknown.
    static func statusWord(_ status: ToolStatus) -> String? {
        switch status {
        case .success:
            return String(localized: "tool.status.succeeded", defaultValue: "succeeded",
                          comment: "VoiceOver status of a transcript tool call that finished without an error.")
        case .failed:
            return String(localized: "tool.status.failed", defaultValue: "failed",
                          comment: "VoiceOver status of a transcript tool call that failed.")
        case .rejected:
            return String(localized: "tool.status.rejected", defaultValue: "rejected",
                          comment: "VoiceOver status of a transcript tool call the user declined.")
        case .interrupted:
            return ToolChip.interrupted
        case .noResult:
            return String(localized: "tool.status.noResult", defaultValue: "no result",
                          comment: "VoiceOver status of a transcript tool call that has no stored result.")
        case .pending:
            return String(localized: "tool.status.running", defaultValue: "running",
                          comment: "VoiceOver status of a transcript tool call that has no result yet.")
        case .unknown:
            return nil
        }
    }

    /// "Ran make, failed, exit 2".
    static func label(for action: ToolRowAction) -> String {
        let name = "\(ToolVerb.text(action.verbKey)) \(action.object)".trimmingCharacters(in: .whitespaces)
        var parts = [name]
        if let status = statusWord(action.status) { parts.append(status) }
        if !action.chips.isEmpty { parts.append(action.chips.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }

    static func disclosureValue(isOpen: Bool) -> String {
        isOpen
            ? String(localized: "tool.row.expanded", defaultValue: "expanded",
                     comment: "VoiceOver state of an open transcript tool row or group.")
            : String(localized: "tool.row.collapsed", defaultValue: "collapsed",
                     comment: "VoiceOver state of a closed transcript tool row or group.")
    }

    /// "3 tool calls, Ran 2 · Read 1, 1 failed".
    static func label(for header: ToolGroupHeaderModel) -> String {
        var parts = [ToolGroupText.title(callCount: header.callCount)]
        let digest = ToolGroupText.digest(header.verbDigest, hasMoreVerbs: header.hasMoreVerbs)
        if !digest.isEmpty { parts.append(digest) }
        if header.failedCount > 0 { parts.append(ToolGroupText.failed(header.failedCount)) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Copy forms

/// What an invocation row copies (spec §8). With `actionIndex` the form covers that action only.
enum ToolCopyKind: Equatable {
    case plain, command, output, markdown
}

enum ToolCopyFormat {
    /// A line index is a valid action index only when the L1 lines and the built actions have the
    /// same count (Task 9 guarantees the order). Nil otherwise: the caller falls back to the whole
    /// invocation.
    static func alignedIndex(_ index: Int, lineCount: Int, actionCount: Int) -> Int? {
        lineCount == actionCount && index >= 0 && index < actionCount ? index : nil
    }

    /// The text to copy, or nil when there is none (no shell command, no output).
    static func text(_ kind: ToolCopyKind, invocation: ToolInvocation, actionIndex: Int?) -> String? {
        let actions: [ToolAction]
        if let actionIndex, invocation.actions.indices.contains(actionIndex) {
            actions = [invocation.actions[actionIndex]]
        } else {
            actions = invocation.actions
        }
        let wholeInvocation = actions.count == invocation.actions.count
        let result: String
        switch kind {
        case .plain:
            result = wholeInvocation ? invocation.plainText : actions.map(\.plainText).joined(separator: "\n\n")
        case .command:
            result = actions.compactMap(\.exactCommand).filter { !$0.isEmpty }.joined(separator: "\n")
        case .output:
            var parts = actions.compactMap { $0.output?.text }.filter { !$0.isEmpty }
            if wholeInvocation, let script = invocation.scriptOutput?.text, !script.isEmpty { parts.append(script) }
            result = parts.joined(separator: "\n\n")
        case .markdown:
            result = actions.map { action in
                let fence = fence(for: action.plainText)
                return "**\(ToolVerb.text(action.verbKey)) \(action.object)**\n\(fence)\n\(action.plainText)\n\(fence)"
            }.joined(separator: "\n\n")
        }
        return result.isEmpty ? nil : result
    }

    /// Backticks, at least three and one more than the longest run inside `text`.
    private static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

/// The L0 group header line (spec §6.1): chevron, "N tool calls", the verb digest, a red
/// "N failed" pill, the total duration and the time. A click toggles the group; Option-click
/// also opens or closes every invocation in it.
struct ToolGroupHeaderView: View {
    let header: ToolGroupHeaderModel
    let accent: Color
    let findMatchCount: Int
    let onToggle: (_ allRows: Bool) -> Void

    var body: some View {
        Button {
            onToggle(NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: ToolRowMetrics.itemSpacing) {
                ToolDisclosureChevron(isOpen: header.isOpen)
                Text(verbatim: ToolGroupText.title(callCount: header.callCount))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .fixedSize()
                Text(verbatim: ToolGroupText.digest(header.verbDigest, hasMoreVerbs: header.hasMoreVerbs))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if header.failedCount > 0 {
                    // Dynamic colors only: systemRed text on a systemRed tint reads in light,
                    // dark and Increase Contrast (each resolves per appearance).
                    Text(verbatim: ToolGroupText.failed(header.failedCount))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(Color(nsColor: .systemRed).opacity(0.16)))
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if findMatchCount > 0 {
                    ToolFindCountPill(count: findMatchCount)
                }
                if let duration = header.durationSeconds {
                    Text(verbatim: TranscriptTurnTiming.formatDuration(duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .fixedSize()
                }
                if let timestamp = header.timestamp {
                    Text(timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .fixedSize()
                }
            }
            .frame(height: ToolRowMetrics.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ToolAccessibility.label(for: header))
        .accessibilityValue(ToolAccessibility.disclosureValue(isOpen: header.isOpen))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Cells

/// A 1 pt hairline in `separatorColor`, resolved per appearance at draw time.
final class ToolHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// Chrome shared by the tool rows: the 4.2 card (3 pt accent bar, 6% tint, 6 pt radius) cut by
/// `ToolCardEdges`, so a group's rows join into one card. At a joined edge the card runs past the
/// cell by its corner radius and the cell clips it: the rounded corner falls outside, the edge
/// reads square, and the accent bar meets the neighbouring row's bar exactly at the cell edge.
class ToolCardCellView: NSTableCellView, TranscriptRowCell {
    let cardBackground = DynamicFillView()
    /// The card's accent bar (tests read its frame).
    let accentBarView = DynamicFillView()
    private let separator = ToolHairlineView()
    /// TextKit 1, so the L2 layout matches `ToolPresentationRenderer.measuredHeight`. Only the
    /// invocation cell puts it in its view tree.
    let bodyText = SelectableBlockTextView(usingTextLayoutManager: false)
    private var cardTop: NSLayoutConstraint?
    private var cardBottom: NSLayoutConstraint?
    private let selectionTint = DynamicFillView()

    /// Alpha of the cross-block selection tint.
    static let selectionTintAlpha: CGFloat = 0.28

    /// A cross-block selection covers the row's lines (a header, a closed row, or the L1 lines of
    /// an open row): the card shows a selection tint, since SwiftUI lines cannot highlight text.
    /// Dynamic colors only; the unemphasized color applies while the window is not key.
    func setSelectionTint(_ on: Bool) {
        if on {
            let key = window?.isKeyWindow ?? true
            selectionTint.fillColor = key ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
            selectionTint.fillAlpha = Self.selectionTintAlpha
        }
        selectionTint.isHidden = !on
    }

    /// Whether the selection tint is showing (tests read it).
    var isSelectionTintVisible: Bool { !selectionTint.isHidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildChrome()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildChrome()
    }

    private func buildChrome() {
        wantsLayer = true
        clipsToBounds = true
        cardBackground.cornerRadius = CardMetrics.cornerRadius
        cardBackground.masksToBounds = true
        cardBackground.fillAlpha = CardMetrics.cardTintAlpha
        cardBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardBackground)

        // Cross-block selection tint: behind the lines and the body, over the card fill.
        selectionTint.translatesAutoresizingMaskIntoConstraints = false
        selectionTint.isHidden = true
        cardBackground.addSubview(selectionTint)
        NSLayoutConstraint.activate([
            selectionTint.leadingAnchor.constraint(equalTo: cardBackground.leadingAnchor),
            selectionTint.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor),
            selectionTint.topAnchor.constraint(equalTo: cardBackground.topAnchor),
            selectionTint.bottomAnchor.constraint(equalTo: cardBackground.bottomAnchor),
        ])

        accentBarView.translatesAutoresizingMaskIntoConstraints = false
        cardBackground.addSubview(accentBarView)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isHidden = true
        cardBackground.addSubview(separator)

        let top = cardBackground.topAnchor.constraint(equalTo: topAnchor)
        let bottom = cardBackground.bottomAnchor.constraint(equalTo: bottomAnchor)
        cardTop = top
        cardBottom = bottom
        NSLayoutConstraint.activate([
            cardBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            top,
            bottom,

            accentBarView.leadingAnchor.constraint(equalTo: cardBackground.leadingAnchor),
            accentBarView.topAnchor.constraint(equalTo: cardBackground.topAnchor),
            accentBarView.bottomAnchor.constraint(equalTo: cardBackground.bottomAnchor),
            accentBarView.widthAnchor.constraint(equalToConstant: CardMetrics.accentBarWidth),

            separator.leadingAnchor.constraint(equalTo: accentBarView.trailingAnchor,
                                               constant: CardMetrics.contentLeadingInset),
            separator.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor,
                                                constant: -CardMetrics.contentTrailingInset),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// Leading edge of the row's lines (after the accent bar and the card's content inset).
    var contentLeadingAnchor: NSLayoutXAxisAnchor { accentBarView.trailingAnchor }

    /// Distance from the cell's top to its first line: none at a joined top, else the half card
    /// gap and the card's edge pad.
    static func firstLineTop(_ edges: ToolCardEdges) -> CGFloat {
        edges.joinedTop ? 0 : CardMetrics.rowGap / 2 + ToolRowMetrics.cardEdgePad
    }

    /// The card's edges and accent. A joined edge overhangs the cell (clipped), so the
    /// neighbouring row's card continues the same card and accent bar.
    func applyChrome(_ edges: ToolCardEdges, accent: NSColor, increaseContrast: Bool = false) {
        let half = CardMetrics.rowGap / 2
        let overhang = CardMetrics.cornerRadius
        cardTop?.constant = edges.joinedTop ? -overhang : half
        cardBottom?.constant = edges.joinedBottom ? overhang : -half
        // Dynamic colors only: DynamicFillView resolves them at draw time.
        cardBackground.fillColor = accent
        accentBarView.fillColor = accent
        separator.isHidden = !edges.showsSeparator
        // Increase Contrast (spec §6.6): the tint gets stronger (x1.5) and the card gets a
        // separator-colored border. At a joined edge the border runs past the cell and is clipped.
        let tint = Self.restingTintAlpha(increaseContrast: increaseContrast)
        if tint != restingTintAlpha {
            // Only follow the resting value; a flash in progress keeps its raised alpha.
            let atRest = cardBackground.fillAlpha == restingTintAlpha
            restingTintAlpha = tint
            if atRest { cardBackground.fillAlpha = tint }
        }
        cardBackground.borderColor = increaseContrast ? .separatorColor : nil
    }

    static func restingTintAlpha(increaseContrast: Bool) -> CGFloat {
        CardMetrics.cardTintAlpha * (increaseContrast ? 1.5 : 1)
    }

    /// The card tint at rest (the flash returns to it).
    private(set) var restingTintAlpha = CardMetrics.cardTintAlpha

    // MARK: TranscriptRowCell

    func wireSelection(controller: BlockTableController?, ordinal: Int, coordinatorActive: Bool) {
        bodyText.selectionController = controller
        bodyText.blockOrdinal = ordinal
        bodyText.forceActiveSelectionAppearance(coordinatorActive)
        if !coordinatorActive {
            bodyText.setSelectedRange(NSRange(location: 0, length: 0))
            setSelectionTint(false)
        }
        // The controller handles the body's `toolfold:` and file links.
        bodyText.delegate = controller
    }

    func applySelectionRange(_ range: NSRange) { bodyText.applyCoordinatorRange(range) }

    func clearFindHighlights() { bodyText.clearFindHighlights() }

    /// The controller passes the 4.2 resting alpha (`CardMetrics.cardTintAlpha`); the cell maps it to
    /// its own resting value (stronger under Increase Contrast).
    func setFlashAlpha(_ alpha: CGFloat) {
        cardBackground.fillAlpha = alpha == CardMetrics.cardTintAlpha ? restingTintAlpha : alpha
    }

    func animateFlashAlpha(to target: CGFloat) {
        cardBackground.animateFillAlpha(to: target == CardMetrics.cardTintAlpha ? restingTintAlpha : target,
                                        duration: 0.45)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        bodyText.textStorage?.setAttributedString(NSAttributedString())
        bodyText.setSelectedRange(NSRange(location: 0, length: 0))
        bodyText.blockOrdinal = -1
        bodyText.forceActiveSelectionAppearance(false)
        setSelectionTint(false)
        cardBackground.fillAlpha = restingTintAlpha
        cardBackground.layer?.removeAnimation(forKey: "flash")
    }
}

/// The L0 header row of a group: the top of the group's card.
final class ToolGroupHeaderCellView: ToolCardCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("ToolGroupHeaderCellView")

    private let host = NSHostingView(rootView: ToolGroupHeaderView(
        header: ToolGroupHeaderModel(groupID: 0, callCount: 0, verbDigest: [], failedCount: 0,
                                     durationSeconds: nil, timestamp: nil, isOpen: false),
        accent: .secondary, findMatchCount: 0, onToggle: { _ in }))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildHeader()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildHeader()
    }

    private func buildHeader() {
        // No body: the (detached) text view stays hidden, so selection hit tests skip it.
        bodyText.isHidden = true
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        cardBackground.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: contentLeadingAnchor, constant: CardMetrics.contentLeadingInset),
            host.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor,
                                           constant: -CardMetrics.contentTrailingInset),
            host.topAnchor.constraint(equalTo: topAnchor,
                                      constant: Self.firstLineTop(ToolCardEdges(joinedTop: false, joinedBottom: false,
                                                                                showsSeparator: false))),
            host.heightAnchor.constraint(equalToConstant: ToolRowMetrics.lineHeight),
        ])
    }

    private var header = ToolGroupHeaderModel(groupID: 0, callCount: 0, verbDigest: [], failedCount: 0,
                                              durationSeconds: nil, timestamp: nil, isOpen: false)
    private var accent: NSColor = .secondaryLabelColor
    private var onToggle: (_ allRows: Bool) -> Void = { _ in }
    private(set) var findMatchCount = 0

    func configure(header: ToolGroupHeaderModel, accent: NSColor, findMatchCount: Int,
                   increaseContrast: Bool = false, onToggle: @escaping (_ allRows: Bool) -> Void) {
        self.header = header
        self.accent = accent
        self.onToggle = onToggle
        self.findMatchCount = findMatchCount
        applyChrome(.header(header), accent: accent, increaseContrast: increaseContrast)
        renderHeader()
    }

    /// What VoiceOver reads for the header (its element label) and its expanded state (its value).
    var accessibilityLabelText: String { ToolAccessibility.label(for: header) }
    var accessibilityDisclosureValue: String { ToolAccessibility.disclosureValue(isOpen: header.isOpen) }

    /// Find repaint: updates the pill only (no reconfigure).
    func updateFindMatchCount(_ count: Int) {
        guard count != findMatchCount else { return }
        findMatchCount = count
        renderHeader()
    }

    private func renderHeader() {
        host.rootView = ToolGroupHeaderView(header: header, accent: Color(nsColor: accent),
                                            findMatchCount: findMatchCount, onToggle: onToggle)
    }
}

/// The hosting view of an invocation's L1 lines. It answers `menu(for:)` and `rightMouseDown`
/// itself, so the row menu opens whatever SwiftUI does with a right-click.
final class ToolLinesHostingView: NSHostingView<ToolActionLines> {
    var rowMenuProvider: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        rowMenuProvider?(event) ?? super.menu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// One invocation: its L1 action lines and, when open and rendered, its L2 body (one attributed
/// string from `ToolDetailRenderer`, in a selectable TextKit 1 text view).
final class ToolInvocationCellView: ToolCardCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("ToolInvocationCellView")

    private let linesHost = ToolLinesHostingView(rootView: ToolActionLines(lines: [], isOpen: false, findMatchCount: 0,
                                                                           onToggle: { _ in }))
    /// The L1 lines view (tests hit-test into it).
    var linesView: NSView { linesHost }
    private var linesTop: NSLayoutConstraint?
    private var linesHeight: NSLayoutConstraint?
    private var bodyHeight: NSLayoutConstraint?
    /// The presentation string the body shows (identity) and the link-input generation it was
    /// linkified under: a reconfigure with the same pair keeps the text storage, its layout, its
    /// links and the reader's selection.
    private var shownBody: NSAttributedString?
    private var shownBodyGeneration = 0
    private var lines: [ToolActionLine] = []
    private var isOpen = false
    private var onToggle: (_ allInGroup: Bool) -> Void = { _ in }
    /// Hover Copy: the action index of the line.
    private var onCopy: (_ actionIndex: Int) -> Void = { _ in }
    /// Hover Raw: the rect to anchor the popover at (in this cell's coordinates).
    private var onRaw: (_ anchor: NSRect, _ view: NSView) -> Void = { _, _ in }
    /// The context menu for a click on action `index` (nil: the whole invocation); `selection` is
    /// the text selected in the body when the click is in the body.
    private var menuProvider: (_ actionIndex: Int?, _ selection: String?) -> NSMenu? = { _, _ in nil }
    private(set) var findMatchCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildInvocation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildInvocation()
    }

    private func buildInvocation() {
        linesHost.translatesAutoresizingMaskIntoConstraints = false
        linesHost.sizingOptions = []
        linesHost.rowMenuProvider = { [weak self] event in self?.menu(for: event) }
        cardBackground.addSubview(linesHost)

        bodyText.translatesAutoresizingMaskIntoConstraints = false
        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.drawsBackground = false
        bodyText.isRichText = true
        bodyText.textContainerInset = .zero
        bodyText.textContainer?.lineFragmentPadding = 0
        bodyText.textContainer?.widthTracksTextView = true
        bodyText.isVerticallyResizable = false
        bodyText.isHorizontallyResizable = false
        // Fold controls read as links without an underline (mockup `.fold a`); file links from
        // linkify set their own underline.
        bodyText.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        // Show all can hold 20,000 lines: lay out only what scrolls into view. The height comes
        // from the off-main measurement, not from this layout.
        bodyText.layoutManager?.allowsNonContiguousLayout = true
        bodyText.rowMenuProvider = { [weak self] event in self?.menu(for: event) }
        bodyText.isHidden = true
        cardBackground.addSubview(bodyText)

        let top = linesHost.topAnchor.constraint(equalTo: topAnchor)
        let lines = linesHost.heightAnchor.constraint(equalToConstant: ToolRowMetrics.lineHeight)
        let body = bodyText.heightAnchor.constraint(equalToConstant: 0)
        linesTop = top
        linesHeight = lines
        bodyHeight = body
        NSLayoutConstraint.activate([
            linesHost.leadingAnchor.constraint(equalTo: contentLeadingAnchor, constant: CardMetrics.contentLeadingInset),
            linesHost.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor,
                                                constant: -CardMetrics.contentTrailingInset),
            top,
            lines,

            bodyText.leadingAnchor.constraint(equalTo: linesHost.leadingAnchor,
                                              constant: ToolRowMetrics.bodyLeadingIndent),
            bodyText.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor,
                                               constant: -CardMetrics.contentTrailingInset),
            bodyText.topAnchor.constraint(equalTo: linesHost.bottomAnchor, constant: ToolRowMetrics.bodyTopGap),
            body,
        ])
    }

    /// - Parameters:
    ///   - body: the rendered L2 body when the row is open and a render landed; nil shows L1 only.
    ///   - bodyHeight: its measured height (TextKit 1, at this cell's body width).
    ///   - bodyGeneration: the controller's link-input generation; a new one resets the body
    ///     (dropping file links resolved under the old inputs).
    /// - Returns: true when the body text was set anew (the caller linkifies it then, and only then).
    @discardableResult
    func configure(model: ToolInvocationRowModel, lines: [ToolActionLine], accent: NSColor,
                   findMatchCount: Int, body: NSAttributedString?, bodyHeight: CGFloat, bodyGeneration: Int,
                   increaseContrast: Bool = false,
                   onToggle: @escaping (_ allInGroup: Bool) -> Void,
                   onCopy: @escaping (_ actionIndex: Int) -> Void = { _ in },
                   onRaw: @escaping (_ anchor: NSRect, _ view: NSView) -> Void = { _, _ in },
                   menuProvider: @escaping (_ actionIndex: Int?, _ selection: String?) -> NSMenu? = { _, _ in nil }) -> Bool {
        let edges = ToolCardEdges.invocation(model)
        applyChrome(edges, accent: accent, increaseContrast: increaseContrast)
        linesTop?.constant = Self.firstLineTop(edges)
        linesHeight?.constant = CGFloat(max(1, lines.count)) * ToolRowMetrics.lineHeight
        self.lines = lines
        self.isOpen = model.isOpen
        self.onToggle = onToggle
        self.onCopy = onCopy
        self.onRaw = onRaw
        self.menuProvider = menuProvider
        self.findMatchCount = findMatchCount
        renderLines()

        if model.isOpen, let body, bodyHeight > 0 {
            var reset = false
            if body !== shownBody || bodyGeneration != shownBodyGeneration {
                bodyText.textStorage?.setAttributedString(body)
                shownBody = body
                shownBodyGeneration = bodyGeneration
                bodyFindHighlights = []
                reset = true
            }
            self.bodyHeight?.constant = bodyHeight
            bodyText.isHidden = false
            return reset
        }
        if shownBody != nil { bodyText.textStorage?.setAttributedString(NSAttributedString()) }
        shownBody = nil
        bodyFindHighlights = []
        self.bodyHeight?.constant = 0
        bodyText.isHidden = true
        return false
    }

    /// The Find highlights painted in the body (Task 15), in body ranges. Empty when the body
    /// carries none, so a repaint of a body without matches costs nothing.
    private(set) var bodyFindHighlights: [(range: NSRange, isCurrent: Bool)] = []

    /// Whether the body shows `body` (the presentation string, by identity).
    func showsBody(_ body: NSAttributedString) -> Bool { shownBody === body && !bodyText.isHidden }

    /// Paints Find highlights in the L2 body, with the message rows' colors and mechanism
    /// (`SelectableBlockTextView.applyFindHighlights`).
    func applyBodyFindHighlights(_ highlights: [(range: NSRange, isCurrent: Bool)]) {
        guard !(highlights.isEmpty && bodyFindHighlights.isEmpty) else { return }
        bodyText.applyFindHighlights(highlights)
        bodyFindHighlights = highlights
    }

    override func clearFindHighlights() {
        super.clearFindHighlights()
        bodyFindHighlights = []
    }

    /// A rect in the body's text coordinates (`ToolPresentationRenderer.textRect`), in `view`'s.
    func convertBodyTextRect(_ textRect: NSRect, to view: NSView) -> NSRect {
        var rect = textRect
        let origin = bodyText.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return bodyText.convert(rect, to: view)
    }

    /// The rect of `range` of the body text, in `view`'s coordinates, from the body's own layout
    /// (laid out up to the range first, so it is exact; tests). Nil when the body is hidden or the
    /// range is outside it.
    func bodyRect(forCharacterRange range: NSRange, in view: NSView) -> NSRect? {
        guard !bodyText.isHidden, let manager = bodyText.layoutManager, let container = bodyText.textContainer,
              range.length > 0, NSMaxRange(range) <= bodyText.textStorage?.length ?? 0 else { return nil }
        layoutSubtreeIfNeeded()
        manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return convertBodyTextRect(manager.boundingRect(forGlyphRange: glyphs, in: container), to: view)
    }

    /// Find repaint: updates the L1 pill only (no reconfigure: the L2 body, its links and any
    /// native selection in it stay).
    func updateFindMatchCount(_ count: Int) {
        guard count != findMatchCount else { return }
        findMatchCount = count
        renderLines()
    }

    private func renderLines() {
        linesHost.rootView = ToolActionLines(
            lines: lines, isOpen: isOpen, findMatchCount: findMatchCount, onToggle: onToggle,
            onCopy: { [weak self] index in self?.performHoverCopy(actionIndex: index) },
            onRaw: { [weak self] index in self?.performHoverRaw(actionIndex: index) })
    }

    // MARK: Hover buttons

    /// The hover Copy button of line `actionIndex`.
    func performHoverCopy(actionIndex: Int) { onCopy(actionIndex) }

    /// The hover Raw button of line `actionIndex`: the popover anchors at that line's trailing end.
    func performHoverRaw(actionIndex: Int) {
        let line = ToolRowMetrics.lineHeight
        let y = linesHost.isFlipped ? CGFloat(actionIndex) * line : linesHost.bounds.height - CGFloat(actionIndex + 1) * line
        let local = NSRect(x: max(0, linesHost.bounds.maxX - 44), y: y, width: 40, height: line)
        onRaw(local, linesHost)
    }

    // MARK: VoiceOver

    /// What VoiceOver reads for each line (`"<verb> <object>, <status>, <chips>"`).
    var lineAccessibilityLabels: [String] { lines.map { ToolAccessibility.label(for: $0.action) } }

    /// The disclosure state VoiceOver reads for every line.
    var accessibilityDisclosureValue: String { ToolAccessibility.disclosureValue(isOpen: isOpen) }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        var actionIndex: Int?
        var selection: String?
        let inLines = linesHost.convert(event.locationInWindow, from: nil)
        if linesHost.bounds.contains(inLines), !lines.isEmpty {
            let y = linesHost.isFlipped ? inLines.y : linesHost.bounds.height - inLines.y
            actionIndex = min(max(Int(y / ToolRowMetrics.lineHeight), 0), lines.count - 1)
        } else if !bodyText.isHidden,
                  bodyText.bounds.contains(bodyText.convert(event.locationInWindow, from: nil)) {
            let range = bodyText.selectedRange()
            if range.length > 0 { selection = (bodyText.string as NSString).substring(with: range) }
        }
        return menuProvider(actionIndex, selection)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        shownBody = nil
        bodyFindHighlights = []
    }
}

// MARK: - Raw event

/// The raw events behind an invocation (spec §6.6 "Show Raw Event"): the stored JSON of the call
/// and of its outputs, pretty-printed.
enum ToolRawEvent {
    /// The parsers cut very long strings out of `rawJSON` and leave this marker.
    static let omittedMarker = "[OMITTED bytes="
    /// Above this size a stored event is shown as it is, without a parse and pretty-print pass.
    private static let prettyPrintLimit = 1_000_000

    /// One stored event as pretty-printed JSON. Claude stores `rawJSON` base64-encoded and Codex
    /// stores plain JSON; text that does not parse stays as it is. Nil for an empty event.
    static func prettyText(of rawJSON: String) -> String? {
        var text = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !(text.hasPrefix("{") || text.hasPrefix("[")),
           let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        }
        guard text.utf16.count <= prettyPrintLimit, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = ToolJSON.string(from: object, pretty: true) else { return text }
        return pretty
    }

    /// The events of `blocks` (the call, then its outputs), one after another with a blank line
    /// between them.
    static func text(for blocks: [SessionTranscriptBuilder.LogicalBlock]) -> String {
        text(forRawEvents: blocks.map(\.rawJSON))
    }

    /// Pure and off-main safe (up to 1 MB per event is parsed).
    static func text(forRawEvents rawEvents: [String]) -> String {
        let pieces = rawEvents.compactMap { prettyText(of: $0) }
        return pieces.isEmpty ? ToolMenuText.rawMissing : pieces.joined(separator: "\n\n")
    }
}

/// The content of the Show Raw Event popover: a notice (when the stored event was shortened) over a
/// selectable monospace text.
final class ToolRawEventViewController: NSViewController {
    let rawText: String
    /// Shown above the text when it holds `ToolRawEvent.omittedMarker`.
    let notice: String?
    /// Everything the popover shows.
    var displayedText: String { [notice, rawText].compactMap { $0 }.joined(separator: "\n") }

    init(rawText: String) {
        self.rawText = rawText
        notice = rawText.contains(ToolRawEvent.omittedMarker) ? ToolMenuText.rawNotice : nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let size = NSSize(width: 560, height: 360)
        let root = NSView(frame: NSRect(origin: .zero, size: size))

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextView(frame: NSRect(origin: .zero, size: size))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = rawText
        scroll.documentView = text
        root.addSubview(scroll)

        var constraints = [
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: size.width),
            root.heightAnchor.constraint(equalToConstant: size.height),
        ]
        if let notice {
            let label = NSTextField(wrappingLabelWithString: notice)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(label)
            constraints += [
                label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
                label.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
                scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            ]
        } else {
            constraints.append(scroll.topAnchor.constraint(equalTo: root.topAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        view = root
    }
}

// MARK: - Off-main L2 presentation

/// One open invocation's L2 body: rendered (`ToolDetailRenderer`) and measured off the main thread.
struct ToolPresentation {
    var folds: [Int: FoldState]
    var scriptShown: Bool
    var attributed: NSAttributedString
    var bodyHeight: CGFloat
    /// `RenderedToolBody.plainCopyText` for a whole-body copy, with the open "Show script" pane's
    /// copy text after a blank line.
    var plainCopyText: String?
    /// Decoded Find matches → ranges of `attributed` (Task 15). The "Show script" pane maps nothing.
    var findMap: ToolFindMap = .empty
    /// The body's fold controls, in rendered order (Find opens the one that hides a match).
    var foldLinks: [ToolFoldLink] = []
}

/// Everything one L2 render needs, captured on the main thread.
struct ToolPresentationRequest {
    var ref: ToolInvocationRef
    /// "session|id|contentStamp|status" (`ToolSearchTextStore.invocationKey`): the
    /// `ToolInvocationBuilder.build` result's cache key.
    var invocationKey: String
    /// `invocationKey` plus the font and width buckets: the presentation's cache key.
    var key: String
    var folds: [Int: FoldState]
    var scriptShown: Bool
    var fontSize: CGFloat
    var width: CGFloat
    var duration: Double?
    /// The system Increase Contrast setting when the request was made (part of `key`).
    var increaseContrast = false

    /// Both produce the same presentation.
    func matches(_ other: ToolPresentationRequest) -> Bool {
        key == other.key && folds == other.folds && scriptShown == other.scriptShown
    }

    /// A cached presentation under `key` shows this request's fold state.
    func isSatisfied(by presentation: ToolPresentation) -> Bool {
        presentation.folds == folds && presentation.scriptShown == scriptShown
    }
}

/// Renders and measures an L2 body. Pure; call it off the main thread.
enum ToolPresentationRenderer {
    /// Fold key of the "Show script" pane: past the actions (`0..<count`) and the script output
    /// pane (`count`).
    static func scriptFoldKey(_ invocation: ToolInvocation) -> Int { invocation.actions.count + 1 }

    static func render(_ invocation: ToolInvocation, folds: [Int: FoldState], scriptShown: Bool,
                       fontSize: CGFloat, width: CGFloat, increaseContrast: Bool = false) -> ToolPresentation {
        // The renderer uses dynamic colors only, so any appearance renders every appearance.
        let appearance = NSAppearance(named: .aqua) ?? NSAppearance(named: .darkAqua)!
        let rendered = ToolDetailRenderer.render(invocation, fontSize: fontSize, width: width, folds: folds,
                                                 appearance: appearance, scriptShown: scriptShown,
                                                 increaseContrast: increaseContrast)
        var attributed = rendered.attributed
        var plainCopyText: String? = rendered.plainCopyText
        if scriptShown, let script = invocation.scriptSource, !script.isEmpty {
            let pane = appendingScriptPane(to: attributed, invocation: invocation, script: script, folds: folds,
                                           fontSize: fontSize, width: width, appearance: appearance,
                                           increaseContrast: increaseContrast)
            attributed = pane.attributed
            // The open script pane is visible text, so a whole-body copy holds it too (after a
            // blank line, like another action).
            plainCopyText = [rendered.plainCopyText, pane.plainCopyText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return ToolPresentation(folds: folds, scriptShown: scriptShown, attributed: attributed,
                                bodyHeight: measuredHeight(of: attributed, width: width),
                                plainCopyText: plainCopyText,
                                findMap: ToolFindMap(segments: ToolSearchText.segments(of: invocation),
                                                     sourceMap: rendered.sourceMap),
                                foldLinks: rendered.foldLinks.map(\.action))
    }

    /// Cache cost of a built invocation: its text in UTF-16 units (outputs, plain forms, script
    /// output and source), which dominates its memory.
    static func cost(of invocation: ToolInvocation) -> Int {
        var units = 0
        for action in invocation.actions {
            units += action.plainText.utf16.count + (action.output?.text.utf16.count ?? 0)
        }
        units += invocation.scriptOutput?.text.utf16.count ?? 0
        units += invocation.scriptSource?.utf16.count ?? 0
        return units
    }

    /// Height of `attributed` laid out at `width` with TextKit 1 and no line-fragment padding —
    /// the layout of the cell's body text view (and of the message cards' bodies).
    static func measuredHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// The rect of `range` in `attributed` laid out at `width` like the cell's body (TextKit 1, no
    /// line-fragment padding), in text coordinates. Lays out the text up to the range's end, so
    /// call it off the main thread (Find scrolls a match in a Show-all body into view with it).
    static func textRect(of range: NSRange, in attributed: NSAttributedString, width: CGFloat) -> NSRect {
        guard range.length > 0, NSMaxRange(range) <= attributed.length else { return .zero }
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// "Show script" (spec §9): the script the agent ran, as a folded mono pane under the body.
    /// It renders as the output pane of a one-action invocation; its controls are re-addressed to
    /// `scriptFoldKey`, so its folds live beside the invocation's own.
    private static func appendingScriptPane(to body: NSAttributedString, invocation: ToolInvocation, script: String,
                                            folds: [Int: FoldState], fontSize: CGFloat, width: CGFloat,
                                            appearance: NSAppearance,
                                            increaseContrast: Bool) -> (attributed: NSAttributedString, plainCopyText: String) {
        let key = scriptFoldKey(invocation)
        let action = ToolAction(category: .shell, verbKey: ToolVerb.ranScript, object: "", objectIsAgentLabel: false,
                                objectDetail: nil, context: [], command: nil, exactCommand: nil, heredoc: nil,
                                inputFields: [], output: DecodedText(text: script, sourceMap: [], shape: .plain),
                                facts: [], hiddenNotes: [], status: .unknown, plainText: script)
        let pane = ToolInvocation(ref: invocation.ref, displayToolName: invocation.displayToolName, actions: [action],
                                  scriptSource: nil, scriptOutput: nil, durationSeconds: nil)
        let paneBody = ToolDetailRenderer.render(
            pane, fontSize: fontSize, width: width, folds: [0: folds[key] ?? FoldState()],
            appearance: appearance, increaseContrast: increaseContrast)
        let rendered = NSMutableAttributedString(attributedString: paneBody.attributed)
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let url = value as? URL, let link = ToolFoldLink(url: url) else { return }
            rendered.addAttribute(.link, value: readdressed(link, to: key).url, range: range)
        }
        let combined = NSMutableAttributedString(attributedString: body)
        combined.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        combined.append(rendered)
        return (combined, paneBody.plainCopyText)
    }

    private static func readdressed(_ link: ToolFoldLink, to key: Int) -> ToolFoldLink {
        switch link {
        case .showMore: return .showMore(action: key)
        case .showAll: return .showAll(action: key)
        case .openLongLine(_, let line): return .openLongLine(action: key, line: line)
        case .showFullCommand: return .showFullCommand(action: key)
        case .copyOutput: return .copyOutput(action: key)
        case .showScript: return .showScript
        }
    }
}
