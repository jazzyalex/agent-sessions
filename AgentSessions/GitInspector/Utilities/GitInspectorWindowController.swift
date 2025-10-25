import SwiftUI
import AppKit

/// Window controller for the Git Context Inspector
/// Manages a separate, non-blocking window that updates when session selection changes
@MainActor
class GitInspectorWindowController: NSObject, NSWindowDelegate {
    static let shared = GitInspectorWindowController()

    private struct WindowRecord {
        let window: NSWindow
        let host: NSHostingController<GitInspectorWindowWrapper>
    }
    private var windows: [String: WindowRecord] = [:] // keyed by SessionKey.rawValue

    /// Show the Git Inspector window for a specific session
    /// - Parameters:
    ///   - session: The session to inspect
    ///   - onResume: Callback when user clicks Resume button
    func show(for session: Session, onResume: @escaping (Session) -> Void) {
        let key = SessionKey(session).rawValue

        if let rec = windows[key] {
            rec.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create new window for this session key
        let contentView = GitInspectorWindowWrapper(
            session: session,
            onResume: { [weak self] sess in
                onResume(sess)
                // Close only this session window
                self?.windows[key]?.window.close()
                self?.windows.removeValue(forKey: key)
            }
        )

        let host = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Git Context"
        window.contentViewController = host
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("GitInspectorWindow.\(key)")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 600)
        window.maxSize = NSSize(width: 1000, height: 1200)
        window.setContentSize(NSSize(width: 850, height: 800))

        // CRITICAL: Ensure window follows system appearance
        window.appearance = nil

        window.makeKeyAndOrderFront(nil)

        windows[key] = WindowRecord(window: window, host: host)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close all Git Inspector windows
    func close() {
        for (_, rec) in windows { rec.window.close() }
        windows.removeAll()
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        // Clean up closed windows
        if let win = notification.object as? NSWindow {
            windows = windows.filter { $0.value.window != win }
        }
    }
}

/// Wrapper view for the Git Inspector that works with NSHostingController
struct GitInspectorWindowWrapper: View {
    let session: Session
    let onResume: (Session) -> Void

    // Observe system appearance changes to force SwiftUI re-evaluation
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearanceToggle: Bool = false

    var body: some View {
        GitInspectorView(session: session, onResume: onResume)
            // Force a distinct identity so SwiftUI state never bleeds across sessions
            .id(SessionKey(session).rawValue)
            .frame(minWidth: 700, idealWidth: 850, maxWidth: 1000, minHeight: 600, idealHeight: 800, maxHeight: 1200)
            // Force re-render when color scheme changes
            .onChange(of: colorScheme) { _, _ in
                appearanceToggle.toggle()
            }
            .id("\(SessionKey(session).rawValue)-\(appearanceToggle)")
    }
}
