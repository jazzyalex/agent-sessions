import SwiftUI
import AppKit

@MainActor
final class CodexImagesWindowController: NSObject, NSWindowDelegate {
    static let shared = CodexImagesWindowController()

    private var window: NSWindow?
    private var hostingView: AppearanceHostingView?
    private var currentSession: Session?
    private weak var indexer: SessionIndexer?
    private var distributedObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppAppearanceRaw: String = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue

    func show(session: Session, indexer: SessionIndexer) {
        currentSession = session
        self.indexer = indexer
        let wrapped = AnyView(
            CodexImagesWindowRoot(seedSession: session)
                .environmentObject(indexer)
        )

        if let win = window, let hv = hostingView {
            hv.rootView = wrapped
            applyAppearance(forceRedraw: true)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hv = AppearanceHostingView(rootView: wrapped)
        hv.onAppearanceChanged = { [weak self] in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }

        let win = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.contentView = hv
        win.title = "Images"
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
        self.hostingView = hv
        applyAppearance(forceRedraw: false)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }

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
            currentSession = nil
            if let o = distributedObserver { DistributedNotificationCenter.default().removeObserver(o) }
            distributedObserver = nil
            if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
            defaultsObserver = nil
        }
    }

    func sendToBack() {
        window?.orderBack(nil)
    }
}

private struct CodexImagesWindowRoot: View {
    let seedSession: Session
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue

    var body: some View {
        let content = CodexSessionImagesGalleryView(seedSession: seedSession)
            .id("CodexImagesSeed-\(seedSession.id)")

        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: content.preferredColorScheme(.light)
            case .dark: content.preferredColorScheme(.dark)
            case .system: content
            }
        }
    }
}

private extension CodexImagesWindowController {
    func handleEffectiveAppearanceChange() {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        let appAppearance = AppAppearance(rawValue: raw) ?? .system
        guard appAppearance == .system else { return }
        applyAppearance(forceRedraw: true)
    }

    func handleAppearancePreferenceChange() {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        guard raw != lastAppAppearanceRaw else { return }
        lastAppAppearanceRaw = raw
        applyAppearance(forceRedraw: true)
    }

    func applyAppearance(forceRedraw: Bool) {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        let appAppearance = AppAppearance(rawValue: raw) ?? .system
        switch appAppearance {
        case .system:
            window?.appearance = nil
        case .light:
            window?.appearance = NSAppearance(named: .aqua)
        case .dark:
            window?.appearance = NSAppearance(named: .darkAqua)
        }
        guard forceRedraw, let hv = hostingView else { return }
        hv.needsLayout = true
        hv.setNeedsDisplay(hv.bounds)
        hv.displayIfNeeded()
    }
}
