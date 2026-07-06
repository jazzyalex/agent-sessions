import AppKit

// MARK: - Shared thumbnail cache

/// Process-wide LRU of decoded inline-image thumbnails, keyed by
/// `InlineSessionImage.id` (stable per session+payload). Lets a cell that
/// scrolls back into view show its thumbnail without re-decoding off disk.
/// Bounded so a long session with many images can't grow it without limit.
/// Thumbnails are small (<= `InlineImageThumbnailGridView.maxPixelSize` px), so
/// a few hundred entries is a modest memory footprint.
enum InlineImageThumbnailCache {
    static let shared = LRUCache<String, NSImage>(maxEntries: 256)
}

// MARK: - Grid view

/// AppKit grid of inline-image thumbnails rendered below a user card's body in
/// the Rich block list. Deliberately self-contained (no SwiftUI/hosting view) so
/// it recycles cleanly inside an `NSTableView` cell:
///
/// - `configure(images:sessionID:)` rebuilds the tile set and kicks async,
///   cancelable decodes; `reset()` cancels every in-flight decode and clears the
///   tiles so a recycled cell never shows a stale image or races a late decode.
/// - Layout is a fixed-column flow whose total height is a pure function of the
///   image count + width (`Self.height(imageCount:width:)`), so the controller
///   can reserve the exact space in `measuredHeight` (no clip).
/// - Each tile is a real `NSButton` (image button), so clicks are handled
///   natively — no manual glyph hit-testing — and post `.showImagesForInlineImage`
///   to open the Image Browser, exactly like the Terminal view.
final class InlineImageThumbnailGridView: NSView {

    // Layout constants — single source of truth shared by the view and the
    // controller's height measurement.
    static let maxColumns = 5
    static let thumbSize: CGFloat = 132
    static let spacing: CGFloat = 8
    static let topInset: CGFloat = 6
    /// Decode pixel cap — matches the Terminal view's inline thumbnail budget.
    static let maxPixelSize = 480
    /// Hard cap on the decoded-bytes budget passed to the payload decoder,
    /// mirroring the Terminal inline-image path (guards a pathological base64).
    private static let maxDecodedBytes = 25 * 1024 * 1024

    private var images: [InlineSessionImage] = []
    private var sessionID: String = ""
    private var tiles: [InlineImageTileButton] = []
    private var decodeTasks: [Task<Void, Never>] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    override var isFlipped: Bool { true }

    // MARK: Column / height math (pure)

    static func columns(imageCount: Int, width: CGFloat) -> Int {
        guard imageCount > 0 else { return 0 }
        // How many `thumbSize` tiles + inter-tile spacing fit in `width`.
        let usable = max(0, width)
        var fit = Int((usable + spacing) / (thumbSize + spacing))
        fit = max(1, min(maxColumns, fit))
        return min(fit, imageCount)
    }

    static func rows(imageCount: Int, width: CGFloat) -> Int {
        let cols = columns(imageCount: imageCount, width: width)
        guard cols > 0 else { return 0 }
        return (imageCount + cols - 1) / cols
    }

    /// Total height the grid occupies for `imageCount` images at `width`, or 0
    /// when there are no images. Used verbatim by `measuredHeight` so the card
    /// reserves exactly the space the grid lays out into.
    static func height(imageCount: Int, width: CGFloat) -> CGFloat {
        let rowCount = rows(imageCount: imageCount, width: width)
        guard rowCount > 0 else { return 0 }
        return topInset + CGFloat(rowCount) * thumbSize + CGFloat(rowCount - 1) * spacing
    }

    // MARK: Configure / reset

    /// Cancel every in-flight decode and drop all tiles. Called on cell reuse
    /// (`prepareForReuse`) and whenever the row becomes a non-image row, so a
    /// recycled cell can never paint a stale image or leak a Task.
    func reset() {
        for task in decodeTasks { task.cancel() }
        decodeTasks.removeAll()
        for tile in tiles { tile.removeFromSuperview() }
        tiles.removeAll()
        images = []
        sessionID = ""
        isHidden = true
    }

    /// Rebuild the grid for `images` and start async thumbnail decodes. Safe to
    /// call repeatedly on a reused cell — it resets first.
    func configure(images: [InlineSessionImage], sessionID: String) {
        reset()
        guard !images.isEmpty else { return }
        self.images = images
        self.sessionID = sessionID
        isHidden = false

        for image in images {
            let tile = InlineImageTileButton()
            tile.translatesAutoresizingMaskIntoConstraints = false
            tile.configure(image: image, sessionID: sessionID)
            addSubview(tile)
            tiles.append(tile)

            if let cached = InlineImageThumbnailCache.shared.get(image.id) {
                tile.setThumbnail(cached)
            } else {
                startDecode(for: image, into: tile)
            }
        }
        needsLayout = true
    }

    private func startDecode(for image: InlineSessionImage, into tile: InlineImageTileButton) {
        let payload = image.payload
        let imageID = image.id
        let cap = Self.maxDecodedBytes
        let pixel = Self.maxPixelSize
        let task = Task(priority: .utility) { [weak self, weak tile] in
            let thumb: NSImage? = {
                guard !Task.isCancelled else { return nil }
                guard let data = try? CodexSessionImagePayload.decodeImageData(
                    payload: payload,
                    maxDecodedBytes: cap,
                    shouldCancel: { Task.isCancelled }) else { return nil }
                guard !Task.isCancelled else { return nil }
                return CodexSessionImagePayload.makeThumbnail(from: data, maxPixelSize: pixel)
            }()
            guard !Task.isCancelled else { return }
            if let thumb {
                InlineImageThumbnailCache.shared.set(imageID, thumb)
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                // Recycle guard: only paint if this tile still belongs to the
                // current image set (the cell wasn't reconfigured to another row
                // while the decode was in flight).
                guard let tile, self.tiles.contains(where: { $0 === tile }),
                      tile.imageID == imageID else { return }
                if let thumb { tile.setThumbnail(thumb) } else { tile.setFailed() }
            }
        }
        decodeTasks.append(task)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let cols = Self.columns(imageCount: tiles.count, width: width)
        guard cols > 0 else { return }
        let size = Self.thumbSize
        let gap = Self.spacing
        for (idx, tile) in tiles.enumerated() {
            let col = idx % cols
            let row = idx / cols
            let x = CGFloat(col) * (size + gap)
            let y = Self.topInset + CGFloat(row) * (size + gap)
            tile.frame = NSRect(x: x, y: y, width: size, height: size)
        }
    }
}

// MARK: - Tile button

/// One thumbnail tile: a borderless image button with a rounded, aspect-fit
/// image well and a placeholder look while its decode is in flight. A native
/// button so clicks land without manual hit-testing.
final class InlineImageTileButton: NSButton {
    private(set) var imageID: String = ""
    private var sessionID: String = ""
    private let well = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        well.translatesAutoresizingMaskIntoConstraints = false
        well.imageScaling = .scaleProportionallyUpOrDown
        well.imageAlignment = .alignCenter
        well.wantsLayer = true
        addSubview(well)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        target = self
        action = #selector(handleClick)
        applyPlaceholderLook()
    }

    func configure(image: InlineSessionImage, sessionID: String) {
        self.imageID = image.id
        self.sessionID = sessionID
        well.image = nil
        applyPlaceholderLook()
        toolTip = "Open image"
    }

    func setThumbnail(_ image: NSImage) {
        layer?.backgroundColor = NSColor.clear.cgColor
        well.contentTintColor = nil
        well.imageScaling = .scaleProportionallyUpOrDown
        well.image = image
    }

    func setFailed() {
        applyPlaceholderLook(symbol: "exclamationmark.triangle")
    }

    private func applyPlaceholderLook(symbol: String = "photo") {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.35).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        well.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        well.contentTintColor = .tertiaryLabelColor
        // Center the placeholder symbol; setThumbnail restores proportional fit.
        well.imageScaling = .scaleNone
    }

    @objc private func handleClick() {
        guard !imageID.isEmpty, !sessionID.isEmpty else { return }
        NotificationCenter.default.post(
            name: .showImagesForInlineImage,
            object: sessionID,
            userInfo: ["selectedItemID": imageID]
        )
    }
}
