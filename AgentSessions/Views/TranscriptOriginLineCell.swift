import AppKit

/// Compact harness notice. Its selectable Markdown body uses the same source map as cards.
final class TranscriptOriginLineCell: NSTableCellView, TranscriptRowCell {
    static let reuseID = NSUserInterfaceItemIdentifier("TranscriptOriginLineCell")
    let bodyText = SelectableBlockTextView(frame: .zero)
    let disclosure = NSButton(title: "", target: nil, action: nil)
    let summaryLabel = NSTextField(labelWithString: "")
    private var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.isBordered = false
        disclosure.target = self
        disclosure.action = #selector(toggle)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.lineBreakMode = .byTruncatingTail
        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.drawsBackground = false
        bodyText.textContainerInset = .zero
        bodyText.textContainer?.lineFragmentPadding = 0
        bodyText.textContainer?.widthTracksTextView = true
        for view in [disclosure, summaryLabel, bodyText] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: BlockRowModel, renderedBody: RenderedBody?, isOpen: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        summaryLabel.stringValue = row.primaryBlock.presentation?.summary ?? ""
        if row.repeatCount > 1 { summaryLabel.stringValue += " ×\(row.repeatCount)" }
        disclosure.image = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right", accessibilityDescription: summaryLabel.stringValue)
        disclosure.isHidden = row.bodyText.isEmpty
        bodyText.isHidden = !isOpen || row.bodyText.isEmpty
        bodyText.clearFindHighlights()
        bodyText.textStorage?.setAttributedString(renderedBody?.attributed ?? NSAttributedString(string: row.bodyText))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let inset = CardMetrics.contentLeadingInset
        disclosure.frame = NSRect(x: inset, y: bounds.height - 22, width: 14, height: 22)
        summaryLabel.frame = NSRect(x: inset + 18, y: bounds.height - 19, width: max(1, bounds.width - inset - 30), height: 16)
        bodyText.frame = NSRect(x: inset, y: CardMetrics.bodyBottomInset, width: max(1, bounds.width - CardMetrics.horizontalChrome), height: max(0, bounds.height - 22 - CardMetrics.bodyBottomInset))
    }
    @objc private func toggle() { onToggle?() }
    func wireSelection(controller: BlockTableController?, ordinal: Int, coordinatorActive: Bool) {
        bodyText.selectionController = controller
        bodyText.blockOrdinal = ordinal
        bodyText.delegate = controller
        bodyText.forceActiveSelectionAppearance(coordinatorActive)
        if !coordinatorActive { bodyText.setSelectedRange(NSRange(location: 0, length: 0)) }
    }
    func applySelectionRange(_ range: NSRange) { bodyText.applyCoordinatorRange(range) }
    func clearFindHighlights() { bodyText.clearFindHighlights() }
    func setFlashAlpha(_ alpha: CGFloat) { }
    func animateFlashAlpha(to target: CGFloat) { }
}
