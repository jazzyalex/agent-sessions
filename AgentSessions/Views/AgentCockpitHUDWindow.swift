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
        private let fallbackStandardStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        private var wasCompact = false

        func attach(to newWindow: NSWindow) {
            guard window !== newWindow else { return }
            window = newWindow
            baselineLevel = newWindow.level
            baselineCollectionBehavior = newWindow.collectionBehavior
            baselineHidesOnDeactivate = newWindow.hidesOnDeactivate
            captureBaselineStyleMaskIfNeeded(from: newWindow.styleMask)
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
            // Keep vertical resize snapping aligned to row increments so partial rows
            // are not clipped at the window edge.
            let rowResizeStep: CGFloat = 31
            window.resizeIncrements = NSSize(width: 1, height: rowResizeStep)
            window.contentResizeIncrements = NSSize(width: 1, height: rowResizeStep)

            if isCompact {
                applyCompactChrome(to: window)
                window.minSize = NSSize(width: 560, height: 128)
                if let compactContentHeight {
                    applyCompactHeight(compactContentHeight, to: window, forceShrink: !wasCompact)
                }
            } else {
                captureBaselineStyleMaskIfNeeded(from: window.styleMask)
                restoreStandardChrome(to: window)
                window.title = "Agent Cockpit (\(shownSessionCount))"
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                let expandedMinHeight: CGFloat = 320
                let nonResizingMinHeight = min(expandedMinHeight, window.frame.height)
                window.minSize = NSSize(width: 560, height: nonResizingMinHeight)
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
            var compactMask = window.styleMask
            compactMask.remove(.titled)
            compactMask.insert(.fullSizeContentView)
            window.styleMask = compactMask
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
            var restoredMask = baselineStyleMask
            if !restoredMask.contains(.titled) {
                restoredMask.formUnion(fallbackStandardStyleMask)
                restoredMask.remove(.fullSizeContentView)
            }
            window.styleMask = restoredMask
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

        private func captureBaselineStyleMaskIfNeeded(from styleMask: NSWindow.StyleMask) {
            guard styleMask.contains(.titled) else {
                if baselineStyleMask.isEmpty {
                    baselineStyleMask = fallbackStandardStyleMask
                }
                return
            }
            baselineStyleMask = styleMask
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
