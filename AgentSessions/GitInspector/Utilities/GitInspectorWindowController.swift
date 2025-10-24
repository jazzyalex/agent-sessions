import SwiftUI
import AppKit

/// Window controller for the Git Context Inspector
/// Manages a separate, non-blocking window that updates when session selection changes
@MainActor
class GitInspectorWindowController: NSObject, NSWindowDelegate {
    static let shared = GitInspectorWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<GitInspectorWindowWrapper>?
    private var currentSessionID: String?

    /// Show the Git Inspector window for a specific session
    /// - Parameters:
    ///   - session: The session to inspect
    ///   - onResume: Callback when user clicks Resume button
    func show(for session: Session, onResume: @escaping (Session) -> Void) {
        // If window exists and session hasn't changed, just bring to front
        if let existingWindow = window, currentSessionID == session.id {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Update current session
        currentSessionID = session.id

        // Create or update content
        let contentView = GitInspectorWindowWrapper(
            session: session,
            onResume: { [weak self] sess in
                onResume(sess)
                self?.window?.close()
            }
        )

        if let existingWindow = window, let hostingController = hostingController {
            // Update existing window content
            hostingController.rootView = contentView
            existingWindow.title = "Git Context: \(session.title.prefix(40))"
            existingWindow.makeKeyAndOrderFront(nil)
        } else {
            // Create new window
            hostingController = NSHostingController(rootView: contentView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )

            window.title = "Git Context: \(session.title.prefix(40))"
            window.contentViewController = hostingController
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("GitInspectorWindow")
            window.isReleasedWhenClosed = false
            // Minimum size for usability on small displays
            window.minSize = NSSize(width: 700, height: 500)
            // Initial content size; user’s later resizing persists via autosave
            window.setContentSize(NSSize(width: 900, height: 700))
            window.makeKeyAndOrderFront(nil)

            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close the Git Inspector window
    func close() {
        window?.close()
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        currentSessionID = nil
        // Keep window and controller alive for reuse
    }
}

/// Wrapper view for the Git Inspector that works with NSHostingController
struct GitInspectorWindowWrapper: View {
    let session: Session
    let onResume: (Session) -> Void

    var body: some View {
        GitInspectorView(session: session, onResume: onResume)
            .frame(minWidth: 680, idealWidth: 680, minHeight: 600, idealHeight: 800)
    }
}
