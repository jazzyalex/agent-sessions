import AppKit
import Foundation

/// Centralized gate for deciding whether usage probes are allowed to run.
/// Rules:
/// 1) If the menu bar usage is disabled AND no main app window is visible, suppress probes.
/// 2) If the screen is inactive (screensaver / sleep / locked), suppress probes regardless of menu bar state.
final class UsageProbeGate: NSObject {
    static let shared = UsageProbeGate()

    // MARK: Observed state
    private(set) var isMainWindowVisible: Bool = true
    private(set) var isScreenInactive: Bool = false

    private override init() {
        super.init()
        // Initial snapshots
        self.isMainWindowVisible = Self.computeMainWindowVisible()
        self.isScreenInactive = false
        // Observe window/app visibility
        NotificationCenter.default.addObserver(self, selector: #selector(updateWindowVisibility), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateWindowVisibility), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateWindowVisibility), name: NSWindow.didMiniaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateWindowVisibility), name: NSWindow.didDeminiaturizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateWindowVisibility), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateWindowVisibility), name: NSApplication.didResignActiveNotification, object: nil)

        // Observe screen inactivity (sleep / screensaver / lock)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleScreensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleScreensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(handleScreenSaverStart), name: NSNotification.Name("com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(handleScreenSaverStop), name: NSNotification.Name("com.apple.screensaver.didstop"), object: nil)
        dnc.addObserver(self, selector: #selector(handleSessionLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(handleSessionUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Returns true if probes are allowed to run under current conditions.
    func shouldProbe() -> Bool {
        let menuBarEnabled = UserDefaults.standard.bool(forKey: "MenuBarEnabled")

        // Rule 1: menu bar off AND main window hidden → suppress
        if !menuBarEnabled && !isMainWindowVisible {
            #if DEBUG
            print("[UsageProbeGate] Suppress probe: menu bar off + main window hidden")
            #endif
            return false
        }

        // Rule 2: screen inactive (sleep/screensaver/locked) → suppress regardless
        if isScreenInactive {
            #if DEBUG
            print("[UsageProbeGate] Suppress probe: screen inactive (sleep/screensaver/locked)")
            #endif
            return false
        }

        return true
    }

    // MARK: - Observers
    @objc private func updateWindowVisibility() { self.isMainWindowVisible = Self.computeMainWindowVisible() }
    @objc private func handleScreensDidSleep() { isScreenInactive = true }
    @objc private func handleScreensDidWake() { isScreenInactive = false }
    @objc private func handleScreenSaverStart() { isScreenInactive = true }
    @objc private func handleScreenSaverStop() { isScreenInactive = false }
    @objc private func handleSessionLocked() { isScreenInactive = true }
    @objc private func handleSessionUnlocked() { isScreenInactive = false }

    private static func computeMainWindowVisible() -> Bool {
        for window in NSApp.windows {
            if window.isVisible && !window.isMiniaturized { return true }
        }
        return false
    }
}

