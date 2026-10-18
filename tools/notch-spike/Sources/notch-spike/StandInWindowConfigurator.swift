import AppKit
import SwiftUI
import NotchSpikeCore

/// Holds the stand-in's `openWindow` action, captured from inside the scene
/// the way the app's `WindowOpenRegistrationView` captures the Quota Meter's.
@MainActor
enum StandInRouter {
    static let identifier = "notch-spike.standin"
    static var open: (() -> Void)?
    /// False until a handoff asks for the stand-in; a launch-time auto-open is closed at once.
    static var expectingOpen = false

    static func existingWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == identifier }
    }
}

/// Applies the production Quota Meter window settings (pinned variant) to the hosting window.
struct StandInWindowConfigurator: NSViewRepresentable {
    let log: SpikeLog

    func makeNSView(context: Context) -> ConfiguratorView { ConfiguratorView(log: log) }
    func updateNSView(_ nsView: ConfiguratorView, context: Context) {}

    final class ConfiguratorView: NSView {
        private let log: SpikeLog

        init(log: SpikeLog) {
            self.log = log
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            configure(window)
            if !StandInRouter.expectingOpen {
                log.write("standin.launch-autoopen", ["action": "close"])
                DispatchQueue.main.async { window.close() }
            }
        }

        private func configure(_ window: NSWindow) {
            window.identifier = NSUserInterfaceItemIdentifier(StandInRouter.identifier)
            var mask = window.styleMask
            mask.remove(.titled)
            mask.insert(.fullSizeContentView)
            window.styleMask = mask
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 380, height: 120)
            window.maxSize = NSSize(width: 380, height: 120)
            window.level = .statusBar
            window.collectionBehavior = window.collectionBehavior.union([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.hidesOnDeactivate = false
            log.write("standin.config", [
                "class": String(describing: type(of: window)),
                "styleMask": Self.describe(window.styleMask),
                "level": window.level == .statusBar ? "statusBar" : String(window.level.rawValue),
                "collection": Self.describe(window.collectionBehavior),
                "hidesOnDeactivate": String(window.hidesOnDeactivate),
                "opaque": String(window.isOpaque),
                "shadow": String(window.hasShadow),
            ])
        }

        static func describe(_ m: NSWindow.StyleMask) -> String {
            let names: [(NSWindow.StyleMask, String)] = [(.titled, "titled"), (.closable, "closable"),
                (.miniaturizable, "miniaturizable"), (.resizable, "resizable"),
                (.fullSizeContentView, "fullSizeContentView"), (.nonactivatingPanel, "nonactivatingPanel")]
            return names.filter { m.contains($0.0) }.map(\.1).joined(separator: ",")
        }

        static func describe(_ c: NSWindow.CollectionBehavior) -> String {
            let names: [(NSWindow.CollectionBehavior, String)] = [(.canJoinAllSpaces, "canJoinAllSpaces"),
                (.moveToActiveSpace, "moveToActiveSpace"), (.managed, "managed"), (.transient, "transient"),
                (.stationary, "stationary"), (.fullScreenAuxiliary, "fullScreenAuxiliary"),
                (.fullScreenPrimary, "fullScreenPrimary"), (.ignoresCycle, "ignoresCycle")]
            let found = names.filter { c.contains($0.0) }.map(\.1)
            return found.isEmpty ? "none" : found.joined(separator: ",")
        }
    }
}

/// Captures `openWindow` for the stand-in scene.
struct StandInRegistration: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            StandInRouter.open = { openWindow(id: StandInRouter.identifier) }
        }
    }
}
