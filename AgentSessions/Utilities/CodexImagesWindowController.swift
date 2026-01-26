import SwiftUI
import AppKit

@MainActor
final class CodexImagesWindowController: NSObject, NSWindowDelegate {
    static let shared = CodexImagesWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?

    func show(session: Session, indexer: SessionIndexer) {
        let root = CodexSessionImagesGalleryView(seedSession: session)
            .environmentObject(indexer)
        let wrapped = AnyView(root)

        if let win = window, let hosting = hostingController {
            hosting.rootView = wrapped
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: wrapped)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Images"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        let autosaveName = "CodexImagesWindow"
        win.setFrameAutosaveName(autosaveName)
        win.isRestorable = true
        win.minSize = NSSize(width: 720, height: 480)
        if !win.setFrameUsingName(autosaveName) {
            win.setContentSize(NSSize(width: 920, height: 640))
            win.center()
        }
        win.delegate = self
        self.window = win
        self.hostingController = hosting
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? NSWindow, win == window {
            window = nil
            hostingController = nil
        }
    }
}
