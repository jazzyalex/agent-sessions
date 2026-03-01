import SwiftUI
import AppKit

struct AgentCockpitHUDWindowConfigurator: NSViewRepresentable {
    let isPinned: Bool
    let shownSessionCount: Int

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.applyStyle(isPinned: isPinned, shownSessionCount: shownSessionCount)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.applyStyle(isPinned: isPinned, shownSessionCount: shownSessionCount)
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

        func attach(to newWindow: NSWindow) {
            guard window !== newWindow else { return }
            window = newWindow
            baselineLevel = newWindow.level
            baselineCollectionBehavior = newWindow.collectionBehavior
            baselineHidesOnDeactivate = newWindow.hidesOnDeactivate
        }

        func applyStyle(isPinned: Bool, shownSessionCount: Int) {
            guard let window else { return }

            if window.identifier?.rawValue != "AgentCockpit" {
                window.identifier = NSUserInterfaceItemIdentifier("AgentCockpit")
            }

            window.isMovableByWindowBackground = true
            window.title = "Agent Cockpit (\(shownSessionCount))"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isRestorable = true
            window.minSize = NSSize(width: 560, height: 220)

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
        }
    }
}
