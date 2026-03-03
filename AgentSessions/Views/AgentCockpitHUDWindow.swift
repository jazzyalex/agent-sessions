import SwiftUI
import AppKit

struct AgentCockpitHUDWindowConfigurator: NSViewRepresentable {
    let isPinned: Bool
    let shownSessionCount: Int
    let isCompact: Bool
    let activeEnabled: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.applyStyle(
                isPinned: isPinned,
                shownSessionCount: shownSessionCount,
                isCompact: isCompact,
                activeEnabled: activeEnabled
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
                activeEnabled: activeEnabled
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private enum Mode {
            case full
            case compact
        }

        private weak var window: NSWindow?
        private var baselineLevel: NSWindow.Level = .normal
        private var baselineCollectionBehavior: NSWindow.CollectionBehavior = []
        private var baselineHidesOnDeactivate: Bool = true
        private var baselineStyleMask: NSWindow.StyleMask = []
        private let fallbackStandardStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        private var currentMode: Mode?

        private let fullAutosaveName = "AgentCockpitHUDWindow.full"
        private let compactAutosaveName = "AgentCockpitHUDWindow.compact"
        private let rowResizeStep: CGFloat = 31
        private let compactDefaultRows: CGFloat = 6
        private let compactMinimumRows: CGFloat = 3
        private let compactHeaderHeight: CGFloat = 44.5
        private let compactDisabledCalloutHeight: CGFloat = 56
        private let fullDefaultFrameSize = NSSize(width: 644, height: 320)

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
                        activeEnabled: Bool) {
            guard let window else { return }

            if window.identifier?.rawValue != "AgentCockpit" {
                window.identifier = NSUserInterfaceItemIdentifier("AgentCockpit")
            }

            window.isMovableByWindowBackground = true
            window.isRestorable = true
            // Keep vertical resize snapping aligned to row increments so partial rows
            // are not clipped at the window edge.
            window.resizeIncrements = NSSize(width: 1, height: rowResizeStep)
            window.contentResizeIncrements = NSSize(width: 1, height: rowResizeStep)

            if isCompact {
                applyCompactChrome(to: window)
                window.minSize = NSSize(
                    width: 560,
                    height: compactMinimumWindowHeight(
                        for: window,
                        includesDisabledCallout: !activeEnabled
                    )
                )
                applyModeTransition(to: .compact, window: window)
                window.title = ""
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            } else {
                captureBaselineStyleMaskIfNeeded(from: window.styleMask)
                restoreStandardChrome(to: window)
                window.minSize = NSSize(width: 560, height: 320)
                applyModeTransition(to: .full, window: window)
                window.title = "Agent Cockpit (\(shownSessionCount))"
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
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

        private func applyModeTransition(to mode: Mode, window: NSWindow) {
            guard currentMode != mode else { return }

            if let previousMode = currentMode {
                window.saveFrame(usingName: autosaveName(for: previousMode))
            }

            let targetAutosaveName = autosaveName(for: mode)
            if window.frameAutosaveName != targetAutosaveName {
                window.setFrameAutosaveName(targetAutosaveName)
            }

            let restored = window.setFrameUsingName(targetAutosaveName)
            if !restored {
                switch mode {
                case .compact:
                    applyCompactDefaultHeight(to: window)
                case .full:
                    applyFullDefaultSize(to: window)
                }
            }

            currentMode = mode
        }

        private func autosaveName(for mode: Mode) -> String {
            switch mode {
            case .full:
                return fullAutosaveName
            case .compact:
                return compactAutosaveName
            }
        }

        private func compactMinimumWindowHeight(for window: NSWindow,
                                                includesDisabledCallout: Bool) -> CGFloat {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = includesDisabledCallout ? compactDisabledCalloutHeight : 0
            return compactContentHeight(forRows: compactMinimumRows) + calloutHeight + chromeHeight
        }

        private func compactContentHeight(forRows rows: CGFloat) -> CGFloat {
            compactHeaderHeight + (rows * rowResizeStep)
        }

        private func applyCompactDefaultHeight(to window: NSWindow) {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let targetHeight = max(window.minSize.height, compactContentHeight(forRows: compactDefaultRows) + chromeHeight)
            let currentHeight = window.frame.height
            guard abs(currentHeight - targetHeight) > 1 else { return }

            var frame = window.frame
            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
            window.setFrame(frame, display: true, animate: true)
        }

        private func applyFullDefaultSize(to window: NSWindow) {
            var frame = window.frame
            let targetWidth = max(window.minSize.width, fullDefaultFrameSize.width)
            let targetHeight = max(window.minSize.height, fullDefaultFrameSize.height)
            let oldHeight = frame.height

            guard abs(frame.width - targetWidth) > 1 || abs(frame.height - targetHeight) > 1 else {
                return
            }

            frame.size.width = targetWidth
            frame.size.height = targetHeight
            // Preserve top edge when applying first-run defaults.
            frame.origin.y += oldHeight - targetHeight
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
