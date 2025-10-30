import AppKit
import SwiftUI

/// Window controller for the Analytics feature
@MainActor
final class AnalyticsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingView: AppearanceHostingView?
    private let service: AnalyticsService
    private var isShown: Bool = false
    // No NotificationCenter observer: use NSView.viewDidChangeEffectiveAppearance instead
    private var distributedObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var lastAppAppearanceRaw: String = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue

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
        // Create SwiftUI content wrapped to manage appearance switching edge cases
        let contentView = AnalyticsWindowRoot(service: service)

        // Create hosting view (type-erased) and observe appearance changes directly from AppKit
        let hostingView = AppearanceHostingView(rootView: AnyView(contentView))
        hostingView.onAppearanceChanged = { [weak self] in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }
        self.hostingView = hostingView

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
        // Ensure window follows system appearance when AppAppearance == .system
        window.appearance = nil
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

        // Appearance changes are observed via hostingView.viewDidChangeEffectiveAppearance
        // Also observe the system-wide theme toggle as a fallback on some macOS versions
        distributedObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleEffectiveAppearanceChange()
            }
        }

        // Observe in-app preference changes for AppAppearance and refresh immediately
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppearancePreferenceChange()
            }
        }
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        // Keep reference, but mark not shown so toggle() re-shows next time
        isShown = false
        // Nothing to remove; observation is via NSView override
        if let o = distributedObserver { DistributedNotificationCenter.default().removeObserver(o) }
        distributedObserver = nil
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        defaultsObserver = nil
    }
}

// MARK: - Root wrapper to handle appearance transitions cleanly
private struct AnalyticsWindowRoot: View {
    @AppStorage("AppAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    let service: AnalyticsService

    var body: some View {
        let content = AnalyticsView(service: service)
        let appAppearance = AppAppearance(rawValue: appAppearanceRaw) ?? .system
        Group {
            switch appAppearance {
            case .light: content.preferredColorScheme(.light)
            case .dark:  content.preferredColorScheme(.dark)
            case .system: content
            }
        }
        // Force rebuild across explicit↔system boundaries to avoid stale theme until click
        .id("AnalyticsAppearance-\(appAppearanceRaw)")
    }
}

// MARK: - Appearance updates
private extension AnalyticsWindowController {
    func handleEffectiveAppearanceChange() {
        // Only rebuild content when user preference is System to pick up the new scheme immediately
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        let appAppearance = AppAppearance(rawValue: raw) ?? .system
        guard appAppearance == .system else { return }

        // Ensure the window inherits the new system appearance
        window?.appearance = nil

        // Re-apply the root view to force SwiftUI to resolve the new environment immediately
        if let hv = hostingView {
            hv.rootView = AnyView(AnalyticsWindowRoot(service: service))
            hv.needsLayout = true
            hv.setNeedsDisplay(hv.bounds)
            hv.displayIfNeeded()
        }
    }

    func handleAppearancePreferenceChange() {
        let raw = UserDefaults.standard.string(forKey: "AppAppearance") ?? AppAppearance.system.rawValue
        guard raw != lastAppAppearanceRaw else { return }
        lastAppAppearanceRaw = raw

        // Always refresh the root when AppAppearance changes to reflect Light/Dark/System instantly
        window?.appearance = nil
        if let hv = hostingView {
            hv.rootView = AnyView(AnalyticsWindowRoot(service: service))
            hv.needsLayout = true
            hv.setNeedsDisplay(hv.bounds)
            hv.displayIfNeeded()
        }
    }
}

// Custom hosting view that notifies when its effectiveAppearance changes
private final class AppearanceHostingView: NSHostingView<AnyView> {
    var onAppearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}
