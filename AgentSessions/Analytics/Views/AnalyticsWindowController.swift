import AppKit
import SwiftUI

/// Window controller for the Analytics feature
@MainActor
final class AnalyticsWindowController: NSObject {
    private var window: NSWindow?
    private let service: AnalyticsService

    init(service: AnalyticsService) {
        self.service = service
        super.init()
    }

    /// Show the analytics window (creates if needed)
    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            createWindow()
        }
    }

    /// Hide the analytics window
    func hide() {
        window?.orderOut(nil)
    }

    /// Toggle the analytics window visibility
    func toggle() {
        if let window = window, window.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func createWindow() {
        // Create SwiftUI content
        let contentView = AnalyticsView(service: service)

        // Create hosting view
        let hostingView = NSHostingView(rootView: contentView)

        // Create window
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: AnalyticsDesign.defaultSize
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Analytics"
        window.contentView = hostingView
        window.minSize = AnalyticsDesign.minimumSize
        window.center()

        // Restore previous window frame if available
        window.setFrameAutosaveName("AnalyticsWindow")

        // Make window appear with animation
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AnalyticsDesign.defaultDuration
            window.animator().alphaValue = 1.0
        }

        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
