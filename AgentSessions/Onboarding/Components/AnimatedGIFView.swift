import SwiftUI
import AppKit

/// Plays a looping animated GIF loaded from an asset-catalog **data set**.
/// SwiftUI can't loop a GIF natively, so this wraps an `NSImageView` whose
/// `image` is a multi-frame animated `NSImage` (NSImageView auto-animates).
///
/// When `animates` is false (e.g. Reduce Motion is on) the first frame is shown
/// static instead of animating.
struct AnimatedGIFView: NSViewRepresentable {
    /// Name of the asset-catalog data set containing the GIF.
    let assetName: String
    var animates: Bool = true

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = animates
        imageView.image = Self.animatedImage(named: assetName)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image == nil {
            nsView.image = Self.animatedImage(named: assetName)
        }
        nsView.animates = animates
    }

    /// True if the GIF asset resolves — lets callers avoid framing an empty box.
    static func hasAsset(named name: String) -> Bool {
        NSDataAsset(name: NSDataAsset.Name(name)) != nil
    }

    private static func animatedImage(named name: String) -> NSImage? {
        guard let data = NSDataAsset(name: NSDataAsset.Name(name))?.data else { return nil }
        return NSImage(data: data)
    }
}
