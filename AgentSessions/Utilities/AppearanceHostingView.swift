import AppKit
import SwiftUI

/// NSHostingView wrapper that notifies when its effectiveAppearance changes.
@MainActor
final class AppearanceHostingView: NSHostingView<AnyView> {
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}
