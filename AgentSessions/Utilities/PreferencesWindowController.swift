import SwiftUI
import AppKit

final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var hostingView: AppearanceHostingView?
    private var indexer: SessionIndexer?
    private var updaterController: UpdaterController?
    private var distributedObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppAppearanceRaw: String = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue

    func show(indexer: SessionIndexer,
              updaterController: UpdaterController,
              initialTab: PreferencesTab = .general) {
        self.indexer = indexer
        self.updaterController = updaterController

        let root = PreferencesWindowRoot(
            indexer: indexer,
            updaterController: updaterController,
            initialTab: initialTab
        )

        if let win = window, let hosting = hostingView {
            hosting.rootView = AnyView(root)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create hosting view with appearance observation
        let hostingView = AppearanceHostingView(rootView: AnyView(root))
        hostingView.onAppearanceChanged = { [weak self] in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }
        self.hostingView = hostingView

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 740, height: 520)),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Preferences"
        win.contentView = hostingView
        win.appearance = nil  // Follow system appearance
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("PreferencesWindow")
        let size = NSSize(width: 740, height: 520)
        win.minSize = size
        win.delegate = self
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Observe system-wide theme changes
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }

        // Observe app preference changes
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppearancePreferenceChange()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? NSWindow, win == window {
            window = nil
            hostingView = nil
            if let o = distributedObserver { DistributedNotificationCenter.default().removeObserver(o) }
            distributedObserver = nil
            if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
            defaultsObserver = nil
        }
    }

    // MARK: - Appearance handling
    private func handleEffectiveAppearanceChange() {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        let appAppearance = AppAppearance(rawValue: raw) ?? .system
        guard appAppearance == .system else { return }

        window?.appearance = nil
        if let hv = hostingView, let idx = indexer, let upc = updaterController {
            hv.rootView = AnyView(PreferencesWindowRoot(
                indexer: idx,
                updaterController: upc,
                initialTab: .general
            ))
            hv.needsLayout = true
            hv.setNeedsDisplay(hv.bounds)
            hv.displayIfNeeded()
        }
    }

    private func handleAppearancePreferenceChange() {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        guard raw != lastAppAppearanceRaw else { return }
        lastAppAppearanceRaw = raw

        window?.appearance = nil
        if let hv = hostingView, let idx = indexer, let upc = updaterController {
            hv.rootView = AnyView(PreferencesWindowRoot(
                indexer: idx,
                updaterController: upc,
                initialTab: .general
            ))
            hv.needsLayout = true
            hv.setNeedsDisplay(hv.bounds)
            hv.displayIfNeeded()
        }
    }
}

// MARK: - Root wrapper to handle appearance transitions
private struct PreferencesWindowRoot: View {
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    let indexer: SessionIndexer
    let updaterController: UpdaterController
    let initialTab: PreferencesTab

    var body: some View {
        let content = PreferencesView(initialTab: initialTab)
            .environmentObject(indexer)
            .environmentObject(indexer.columnVisibility)
            .environmentObject(updaterController)

        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: content.preferredColorScheme(.light)
            case .dark:  content.preferredColorScheme(.dark)
            case .system: content
            }
        }
        .id("PreferencesAppearance-\(appAppearanceRaw)")
    }
}

// MARK: - Custom hosting view for appearance observation
private final class AppearanceHostingView: NSHostingView<AnyView> {
    var onAppearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}
