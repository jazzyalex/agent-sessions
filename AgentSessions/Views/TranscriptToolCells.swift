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
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(Color(nsColor: .systemYellow).opacity(0.9)))
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

/// An invocation's L1 lines. A click anywhere on them toggles its L2; Option-click toggles every
/// invocation of its group.
struct ToolActionLines: View {
    let lines: [ToolActionLine]
    let isOpen: Bool
    let findMatchCount: Int
    let onToggle: (_ allInGroup: Bool) -> Void

    var body: some View {
        Button {
            onToggle(NSEvent.modifierFlags.contains(.option))
        } label: {
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                    ToolActionRowHeader(line: line, isOpen: isOpen, findMatchCount: offset == 0 ? findMatchCount : 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    func applyChrome(_ edges: ToolCardEdges, accent: NSColor) {
        let half = CardMetrics.rowGap / 2
        let overhang = CardMetrics.cornerRadius
        cardTop?.constant = edges.joinedTop ? -overhang : half
        cardBottom?.constant = edges.joinedBottom ? overhang : -half
        // Dynamic colors only: DynamicFillView resolves them at draw time.
        cardBackground.fillColor = accent
        accentBarView.fillColor = accent
        separator.isHidden = !edges.showsSeparator
    }

    // MARK: TranscriptRowCell

    func wireSelection(controller: BlockTableController?, ordinal: Int, coordinatorActive: Bool) {
        bodyText.selectionController = controller
        bodyText.blockOrdinal = ordinal
        bodyText.forceActiveSelectionAppearance(coordinatorActive)
        if !coordinatorActive { bodyText.setSelectedRange(NSRange(location: 0, length: 0)) }
        // The controller handles the body's `toolfold:` and file links.
        bodyText.delegate = controller
    }

    func applySelectionRange(_ range: NSRange) { bodyText.applyCoordinatorRange(range) }

    func clearFindHighlights() { bodyText.clearFindHighlights() }

    func setFlashAlpha(_ alpha: CGFloat) { cardBackground.fillAlpha = alpha }

    func animateFlashAlpha(to target: CGFloat) { cardBackground.animateFillAlpha(to: target, duration: 0.45) }

    override func prepareForReuse() {
        super.prepareForReuse()
        bodyText.textStorage?.setAttributedString(NSAttributedString())
        bodyText.setSelectedRange(NSRange(location: 0, length: 0))
        bodyText.blockOrdinal = -1
        bodyText.forceActiveSelectionAppearance(false)
        cardBackground.fillAlpha = CardMetrics.cardTintAlpha
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
                   onToggle: @escaping (_ allRows: Bool) -> Void) {
        self.header = header
        self.accent = accent
        self.onToggle = onToggle
        self.findMatchCount = findMatchCount
        applyChrome(.header(header), accent: accent)
        renderHeader()
    }

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

/// One invocation: its L1 action lines and, when open and rendered, its L2 body (one attributed
/// string from `ToolDetailRenderer`, in a selectable TextKit 1 text view).
final class ToolInvocationCellView: ToolCardCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("ToolInvocationCellView")

    private let linesHost = NSHostingView(rootView: ToolActionLines(lines: [], isOpen: false, findMatchCount: 0,
                                                                    onToggle: { _ in }))
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
                   onToggle: @escaping (_ allInGroup: Bool) -> Void) -> Bool {
        let edges = ToolCardEdges.invocation(model)
        applyChrome(edges, accent: accent)
        linesTop?.constant = Self.firstLineTop(edges)
        linesHeight?.constant = CGFloat(max(1, lines.count)) * ToolRowMetrics.lineHeight
        self.lines = lines
        self.isOpen = model.isOpen
        self.onToggle = onToggle
        self.findMatchCount = findMatchCount
        renderLines()

        if model.isOpen, let body, bodyHeight > 0 {
            var reset = false
            if body !== shownBody || bodyGeneration != shownBodyGeneration {
                bodyText.textStorage?.setAttributedString(body)
                shownBody = body
                shownBodyGeneration = bodyGeneration
                reset = true
            }
            self.bodyHeight?.constant = bodyHeight
            bodyText.isHidden = false
            return reset
        }
        if shownBody != nil { bodyText.textStorage?.setAttributedString(NSAttributedString()) }
        shownBody = nil
        self.bodyHeight?.constant = 0
        bodyText.isHidden = true
        return false
    }

    /// Find repaint: updates the L1 pill only (no reconfigure: the L2 body, its links and any
    /// native selection in it stay).
    func updateFindMatchCount(_ count: Int) {
        guard count != findMatchCount else { return }
        findMatchCount = count
        renderLines()
    }

    private func renderLines() {
        linesHost.rootView = ToolActionLines(lines: lines, isOpen: isOpen, findMatchCount: findMatchCount,
                                             onToggle: onToggle)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        shownBody = nil
    }
}

// MARK: - Off-main L2 presentation

/// One open invocation's L2 body: rendered (`ToolDetailRenderer`) and measured off the main thread.
struct ToolPresentation {
    var folds: [Int: FoldState]
    var scriptShown: Bool
    var attributed: NSAttributedString
    var bodyHeight: CGFloat
}

/// Everything one L2 render needs, captured on the main thread.
struct ToolPresentationRequest {
    var ref: ToolInvocationRef
    /// "id|contentStamp|status": the `ToolInvocationBuilder.build` result's cache key.
    var invocationKey: String
    /// `invocationKey` plus the font and width buckets: the presentation's cache key.
    var key: String
    var folds: [Int: FoldState]
    var scriptShown: Bool
    var fontSize: CGFloat
    var width: CGFloat
    var duration: Double?

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
                       fontSize: CGFloat, width: CGFloat) -> ToolPresentation {
        // The renderer uses dynamic colors only, so any appearance renders every appearance.
        let appearance = NSAppearance(named: .aqua) ?? NSAppearance(named: .darkAqua)!
        var attributed = ToolDetailRenderer.render(invocation, fontSize: fontSize, width: width, folds: folds,
                                                   appearance: appearance).attributed
        if scriptShown, let script = invocation.scriptSource, !script.isEmpty {
            attributed = appendingScriptPane(to: attributed, invocation: invocation, script: script, folds: folds,
                                             fontSize: fontSize, width: width, appearance: appearance)
        }
        return ToolPresentation(folds: folds, scriptShown: scriptShown, attributed: attributed,
                                bodyHeight: measuredHeight(of: attributed, width: width))
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

    /// "Show script" (spec §9): the script the agent ran, as a folded mono pane under the body.
    /// It renders as the output pane of a one-action invocation; its controls are re-addressed to
    /// `scriptFoldKey`, so its folds live beside the invocation's own.
    private static func appendingScriptPane(to body: NSAttributedString, invocation: ToolInvocation, script: String,
                                            folds: [Int: FoldState], fontSize: CGFloat, width: CGFloat,
                                            appearance: NSAppearance) -> NSAttributedString {
        let key = scriptFoldKey(invocation)
        let action = ToolAction(category: .shell, verbKey: ToolVerb.ranScript, object: "", objectIsAgentLabel: false,
                                objectDetail: nil, context: [], command: nil, exactCommand: nil, heredoc: nil,
                                inputFields: [], output: DecodedText(text: script, sourceMap: [], shape: .plain),
                                facts: [], hiddenNotes: [], status: .unknown, plainText: script)
        let pane = ToolInvocation(ref: invocation.ref, displayToolName: invocation.displayToolName, actions: [action],
                                  scriptSource: nil, scriptOutput: nil, durationSeconds: nil)
        let rendered = NSMutableAttributedString(attributedString: ToolDetailRenderer.render(
            pane, fontSize: fontSize, width: width, folds: [0: folds[key] ?? FoldState()],
            appearance: appearance).attributed)
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let url = value as? URL, let link = ToolFoldLink(url: url) else { return }
            rendered.addAttribute(.link, value: readdressed(link, to: key).url, range: range)
        }
        let combined = NSMutableAttributedString(attributedString: body)
        combined.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        combined.append(rendered)
        return combined
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
