import AppKit
import Foundation

/// Centralized gate for deciding whether usage probes are allowed to run.
/// Rules:
/// 1) If the menu bar usage is disabled AND no main app window is visible, suppress probes.
/// 2) If the screen is inactive (screensaver / sleep / locked), suppress probes regardless of menu bar state.
actor ProbeBudgetManager {
    private var timestamps: [Date] = []
    private let defaultsKey = "UsageProbeRecentTimestamps"
    let maxProbesPerDay = 24
    let window: TimeInterval = 24 * 60 * 60

    init() {
        // Load persisted timestamps
        if let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [Double] {
            timestamps = raw.map { Date(timeIntervalSince1970: $0) }
        }
        pruneLocked(now: Date())
    }

    private func pruneLocked(now: Date) {
        timestamps = timestamps.filter { now.timeIntervalSince($0) <= window }
    }

    private func persistLocked() {
        let arr = timestamps.map { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(arr, forKey: defaultsKey)
    }

    func hasQuota(now: Date = Date()) -> Bool {
        pruneLocked(now: now)
        return timestamps.count < maxProbesPerDay
    }

    func record(now: Date = Date()) {
        pruneLocked(now: now)
        timestamps.append(now)
        persistLocked()
    }

    func remaining(now: Date = Date()) -> Int {
        pruneLocked(now: now)
        return max(0, maxProbesPerDay - timestamps.count)
    }
}

final class UsageProbeGate: NSObject {
    static let shared = UsageProbeGate()

    // MARK: Observed state
    private(set) var isMainWindowVisible: Bool = true
    private(set) var isScreenInactive: Bool = false
    private let budget = ProbeBudgetManager()

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

    /// Returns true if probes are allowed to run under current UI/visibility rules.
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

    /// Combined check for automatic probes: gate + daily budget (24 per rolling 24h).
    func canProbeAutomatic() async -> Bool {
        guard shouldProbe() else { return false }
        let ok = await budget.hasQuota()
        if !ok {
            #if DEBUG
            print("[UsageProbeGate] Suppress probe: daily budget exhausted (\(await budget.remaining()) remaining)")
            #endif
        }
        return ok
    }

    /// Record that a probe attempt was made (counts toward budget). Use for both auto/manual unless explicitly excluded.
    func recordProbeAttempt() async { await budget.record() }

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
