import AppKit
import SwiftUI

/// Window controller for the Analytics feature
@MainActor
final class AnalyticsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let service: AnalyticsService
    private var isShown: Bool = false

    init(service: AnalyticsService) {
        self.service = service
        super.init()
    }

    /// Show the analytics window (creates if needed)
    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isShown = true
        } else {
            createWindow()
        }
    }

    /// Hide the analytics window
    func hide() {
        window?.orderOut(nil)
        isShown = false
    }

    /// Toggle the analytics window visibility
    func toggle() {
        // Avoid querying isVisible on a possibly invalid window during early app load.
        if isShown {
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
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Analytics"
        window.contentView = hostingView
        // Fixed-size window to keep card layout stable
        window.minSize = AnalyticsDesign.defaultSize
        window.maxSize = AnalyticsDesign.defaultSize
        window.isReleasedWhenClosed = false
        window.delegate = self
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
        self.isShown = true
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        // Keep reference, but mark not shown so toggle() re-shows next time
        isShown = false
    }
}
