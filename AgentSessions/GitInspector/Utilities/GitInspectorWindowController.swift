import SwiftUI
import AppKit

/// Window controller for the Git Context Inspector
/// Manages a separate, non-blocking window that updates when session selection changes
@MainActor
class GitInspectorWindowController: NSObject, NSWindowDelegate {
    static let shared = GitInspectorWindowController()

    private var windows: [String: NSWindow] = [:] // keyed by SessionKey.rawValue

    /// Show the Git Inspector window for a specific session
    /// - Parameters:
    ///   - session: The session to inspect
    ///   - onResume: Callback when user clicks Resume button
    func show(for session: Session, onResume: @escaping (Session) -> Void) {
        let key = SessionKey(session).rawValue

        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create new window for this session key
        let contentView = GitInspectorWindowWrapper(
            session: session,
            onResume: { [weak self] sess in
                onResume(sess)
                // Close only this session window
                self?.windows[key]?.close()
                self?.windows.removeValue(forKey: key)
            }
        )

        // Use NSHostingView directly like Analytics window does
        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Git Context"
        window.contentView = hostingView
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("GitInspectorWindow.\(key)")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 600)
        window.maxSize = NSSize(width: 1000, height: 1200)
        window.setContentSize(NSSize(width: 850, height: 800))

        // Let window follow system appearance naturally
        window.appearance = nil

        window.makeKeyAndOrderFront(nil)
        windows[key] = window
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close all Git Inspector windows
    func close() {
        for (_, window) in windows { window.close() }
        windows.removeAll()
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        // Clean up closed windows
        if let win = notification.object as? NSWindow {
            windows = windows.filter { $0.value != win }
        }
    }
}

/// Wrapper view for the Git Inspector that works with NSHostingView
struct GitInspectorWindowWrapper: View {
    let session: Session
    let onResume: (Session) -> Void
    // Track the app-wide appearance preference
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    var body: some View {
        // Base content
        let content = GitInspectorView(session: session, onResume: onResume)
            // Force a distinct identity so SwiftUI state never bleeds across sessions
            .id(SessionKey(session).rawValue)
            .frame(minWidth: 700, idealWidth: 850, maxWidth: 1000, minHeight: 600, idealHeight: 800, maxHeight: 1200)

        // Apply preferredColorScheme only for explicit Light/Dark modes.
        // For System mode, omit the modifier entirely to avoid SwiftUI bugs when passing nil.
        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: content.preferredColorScheme(.light)
            case .dark:  content.preferredColorScheme(.dark)
            case .system: content
            }
        }
    }
}

// Local helper is intentionally minimal to avoid cross-file coupling.
