import SwiftUI
import AppKit

@MainActor final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?

    func show(indexer: SessionIndexer,
              updaterController: UpdaterController,
              initialTab: PreferencesTab = .general) {
        let root = PreferencesView(initialTab: initialTab)
            .environmentObject(indexer)
            .environmentObject(indexer.columnVisibility)
            .environmentObject(updaterController)
        let wrapped = AnyView(root)

        if let win = window, let hosting = hostingController {
            hosting.rootView = wrapped
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: wrapped)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Preferences"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("PreferencesWindow")
        let size = NSSize(width: 740, height: 520)
        win.setContentSize(size)
        win.contentMinSize = size
        win.delegate = self
        self.window = win
        hostingController = hosting
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep controller but drop the window so it can be rebuilt later
        if let win = notification.object as? NSWindow, win == window {
            window = nil
            hostingController = nil
        }
    }
}
