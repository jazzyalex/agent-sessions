import SwiftUI
import AppKit

struct AgentCockpitHUDWindowConfigurator: NSViewRepresentable {
    let isPinned: Bool
    let shownSessionCount: Int
    let isCompact: Bool
    let compactContentHeight: CGFloat?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.applyStyle(
                isPinned: isPinned,
                shownSessionCount: shownSessionCount,
                isCompact: isCompact,
                compactContentHeight: compactContentHeight
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.applyStyle(
                isPinned: isPinned,
                shownSessionCount: shownSessionCount,
                isCompact: isCompact,
                compactContentHeight: compactContentHeight
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var baselineLevel: NSWindow.Level = .normal
        private var baselineCollectionBehavior: NSWindow.CollectionBehavior = []
        private var baselineHidesOnDeactivate: Bool = true
        private var baselineStyleMask: NSWindow.StyleMask = []
        private var wasCompact = false

        func attach(to newWindow: NSWindow) {
            guard window !== newWindow else { return }
            window = newWindow
            baselineLevel = newWindow.level
            baselineCollectionBehavior = newWindow.collectionBehavior
            baselineHidesOnDeactivate = newWindow.hidesOnDeactivate
            baselineStyleMask = newWindow.styleMask
        }

        func applyStyle(isPinned: Bool,
                        shownSessionCount: Int,
                        isCompact: Bool,
                        compactContentHeight: CGFloat?) {
            guard let window else { return }

            if window.identifier?.rawValue != "AgentCockpit" {
                window.identifier = NSUserInterfaceItemIdentifier("AgentCockpit")
            }

            window.isMovableByWindowBackground = true
            window.isRestorable = true

            if isCompact {
                applyCompactChrome(to: window)
                window.minSize = NSSize(width: 560, height: 128)
                if let compactContentHeight {
                    applyCompactHeight(compactContentHeight, to: window, forceShrink: !wasCompact)
                }
            } else {
                restoreStandardChrome(to: window)
                window.title = "Agent Cockpit (\(shownSessionCount))"
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.minSize = NSSize(width: 560, height: 220)
            }

            if isPinned {
                window.level = .screenSaver
                window.collectionBehavior = baselineCollectionBehavior.union([.canJoinAllSpaces, .fullScreenAuxiliary])
                window.hidesOnDeactivate = false
            } else {
                // Restore non-pinned behavior to the window's baseline values.
                window.level = baselineLevel
                window.collectionBehavior = baselineCollectionBehavior
                window.hidesOnDeactivate = baselineHidesOnDeactivate
            }

            if window.frameAutosaveName != "AgentCockpitHUDWindow" {
                window.setFrameAutosaveName("AgentCockpitHUDWindow")
            }
            wasCompact = isCompact
        }

        private func applyCompactChrome(to window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for buttonType in buttons {
                guard let button = window.standardWindowButton(buttonType) else { continue }
                button.isHidden = true
                button.isEnabled = false
            }
            if let container = window.standardWindowButton(.closeButton)?.superview {
                container.isHidden = true
            }
        }

        private func restoreStandardChrome(to window: NSWindow) {
            if !baselineStyleMask.isEmpty {
                window.styleMask = baselineStyleMask
            } else {
                window.styleMask.remove(.fullSizeContentView)
            }
            window.titlebarSeparatorStyle = .automatic
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for buttonType in buttons {
                guard let button = window.standardWindowButton(buttonType) else { continue }
                button.isHidden = false
                button.isEnabled = true
            }
            if let container = window.standardWindowButton(.closeButton)?.superview {
                container.isHidden = false
            }
        }

        private func applyCompactHeight(_ compactContentHeight: CGFloat,
                                        to window: NSWindow,
                                        forceShrink: Bool) {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let targetHeight = max(window.minSize.height, compactContentHeight + chromeHeight)
            let currentHeight = window.frame.height
            if !forceShrink, currentHeight > targetHeight {
                return
            }
            guard abs(currentHeight - targetHeight) > 1 else { return }

            var frame = window.frame
            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
