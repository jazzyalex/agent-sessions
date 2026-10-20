import AppKit
import Combine

/// The single owner of where the Quota Meter appears: the existing floating window or the
/// menu bar strip. Re-resolves on launch, placement change, debounced screen change and wake;
/// never on a window drag.
@MainActor
final class QuotaMeterPresentationCoordinator: ObservableObject {
    static let shared = QuotaMeterPresentationCoordinator()

    @Published private(set) var decision: PlacementDecision = .floating

    var isStripPresented: Bool { strip?.isPresented ?? false }
    var isStarted: Bool { strip != nil }

    /// Called after every re-resolve. `userInitiated` is false for display and wake changes,
    /// which must not rewrite the user's stored preferences.
    var onDecisionChange: ((_ userInitiated: Bool) -> Void)?

    /// Written after every re-resolve: "strip" or "floating". Dock reachability reads it.
    nonisolated static let decisionKey = "QuotaMeterPresentationDecision"

    private var strip: QuotaStripController?
    private var openWindow: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var defaultsSubscription: AnyCancellable?
    private var pendingScreenWork: DispatchWorkItem?
    private var lastPlacementRaw: String?
    private var lastStripHidden = false
    /// Set when the strip left the built-in display only because that display went away
    /// (lid closed); `automatic` then returns to it when it comes back. Cleared by any user
    /// placement change.
    private var returnToBuiltinWhenBack = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start(stripController: QuotaStripController, openWindow: @escaping () -> Void) {
        guard strip == nil else { return }
        strip = stripController
        self.openWindow = openWindow
        lastPlacementRaw = defaults.string(forKey: PreferencesKey.quotaMeterPlacement)
        lastStripHidden = defaults.bool(forKey: PreferencesKey.quotaMeterStripHidden)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScreenReresolve() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScreenReresolve() }
        })
        defaultsSubscription = center.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.defaultsChanged() }
            }
        reresolve(reason: "start", userInitiated: false)
    }

    /// True when the current settings and screens put the Quota Meter in the strip.
    func resolvesToStrip() -> Bool {
        if case .strip = resolve() { return true }
        return false
    }

    /// View-menu toggle: in strip mode it hides or shows the strip; otherwise it opens or
    /// closes the floating window as before.
    func setQuotaMeterVisible(_ visible: Bool) {
        if case .strip = decision {
            defaults.set(!visible, forKey: PreferencesKey.quotaMeterStripHidden)
            reresolve(reason: "toggle", userInitiated: true)
        } else if visible {
            openWindow?()
        } else {
            AppWindowRouter.closeAgentCockpitWindow()
        }
        CockpitWindowVisibility.shared.refresh()
    }

    /// Show the Quota Meter wherever it belongs (onboarding, menus).
    /// Resolves first, so the caller gets the placement that applies to the current screens
    /// and settings, not a decision made before they changed.
    func showQuotaMeter() {
        if defaults.bool(forKey: PreferencesKey.quotaMeterStripHidden) {
            defaults.set(false, forKey: PreferencesKey.quotaMeterStripHidden)
            lastStripHidden = false
        }
        reresolve(reason: "show", userInitiated: true)
        if case .floating = decision {
            AppWindowRouter.showAgentCockpitWindow()
        }
    }

    /// Puts the Quota Meter in the notch and makes it visible, also when it was hidden from
    /// the View menu. A placement that already resolves to the notch (Notch, or Automatic on
    /// the built-in display) is kept: only the hidden flag is cleared, so Automatic stays
    /// Automatic and still uses the desktop on external monitors.
    func moveToNotch() {
        defaults.set(false, forKey: PreferencesKey.quotaMeterStripHidden)
        guard !resolvesToStrip() else { return }
        defaults.set(QuotaMeterPlacement.menuBar.rawValue, forKey: PreferencesKey.quotaMeterPlacement)
    }

    /// Opens the notch panel briefly once the strip is on screen. Always starts after
    /// `startDelay`, so the dialog that asked for it has finished closing even when the strip
    /// is already up. A placement change presents the strip asynchronously, so this then
    /// waits up to `presentTimeout` and gives up silently (for example when no screen can
    /// take the strip).
    func peekStrip(duration: TimeInterval = 3, startDelay: TimeInterval = 0.4,
                   presentTimeout: TimeInterval = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.peekWhenPresented(duration: duration, attemptsLeft: Int(presentTimeout / 0.1))
            }
        }
    }

    private func peekWhenPresented(duration: TimeInterval, attemptsLeft: Int) {
        guard let strip else { return }
        if strip.isPresented {
            strip.peek(duration: duration)
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.peekWhenPresented(duration: duration, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    // MARK: - Resolution

    /// Placement does not depend on usage tracking (the wings observe it themselves), so only
    /// the placement choice and the strip-hidden flag trigger a re-resolve.
    private func defaultsChanged() {
        let raw = defaults.string(forKey: PreferencesKey.quotaMeterPlacement)
        let hidden = defaults.bool(forKey: PreferencesKey.quotaMeterStripHidden)
        guard raw != lastPlacementRaw || hidden != lastStripHidden else { return }
        if raw != lastPlacementRaw {
            // A new placement choice always shows the meter there, even if the strip was
            // hidden from the View menu earlier, and forgets any pending lid-reopen return.
            returnToBuiltinWhenBack = false
            if hidden { defaults.set(false, forKey: PreferencesKey.quotaMeterStripHidden) }
            // The user has chosen where the Quota Meter goes; the notch intro would only ask again.
            defaults.set(true, forKey: QuotaMeterNotchIntro.shownKey)
        }
        lastPlacementRaw = raw
        lastStripHidden = defaults.bool(forKey: PreferencesKey.quotaMeterStripHidden)
        reresolve(reason: "preference", userInitiated: true)
    }

    private func scheduleScreenReresolve() {
        pendingScreenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reresolve(reason: "screens", userInitiated: false) }
        }
        pendingScreenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The strip is shown whether or not usage tracking is on: it also carries the app menu,
    /// the live-session line and Dock-hidden reachability (wings are muted when untracked).
    private func resolve() -> PlacementDecision {
        let choice = QuotaMeterPlacement.current(raw: defaults.string(forKey: PreferencesKey.quotaMeterPlacement)).choice
        let screens = NSScreen.screens.compactMap { screen -> PlacementScreen? in
            guard let id = QuotaStripController.displayID(screen) else { return nil }
            return PlacementScreen(id: id, frame: screen.frame, isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
        return QuotaMeterPlacementResolver.resolve(choice, screens: screens, floatingFrame: floatingFrame(),
                                                   preferBuiltin: returnToBuiltinWhenBack)
    }

    /// The floating window's live frame, else its autosaved frame.
    private func floatingFrame() -> CGRect? {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppWindowRouter.cockpitWindowIdentifier }) {
            return window.frame
        }
        guard let saved = defaults.string(forKey: "NSWindow Frame AgentCockpitHUDWindow.limits") else { return nil }
        let parts = saved.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func reresolve(reason: String, userInitiated: Bool) {
        guard let strip else { return }
        let next = resolve()
        let stripHidden = defaults.bool(forKey: PreferencesKey.quotaMeterStripHidden)
        let wasStrip = strip.isPresented
        let wasWindow = AppWindowRouter.isAgentCockpitWindowVisible
        switch next {
        case .strip(let screenID):
            returnToBuiltinWhenBack = false
            if stripHidden { strip.dismiss() } else { strip.present(on: screenID) }
            if wasWindow { AppWindowRouter.closeAgentCockpitWindow() }
        case .floating:
            let switchedFromStrip: Bool
            if case .strip = decision { switchedFromStrip = true } else { switchedFromStrip = false }
            // The built-in display went away under an `automatic` strip: come back to it later.
            if !userInitiated, switchedFromStrip, strip.screenID.map(Self.isBuiltin) == true,
               QuotaMeterPlacement.current(raw: defaults.string(forKey: PreferencesKey.quotaMeterPlacement)) == .automatic {
                returnToBuiltinWhenBack = true
            }
            // Keep the meter visible: open the window before the strip goes away.
            if (wasStrip || (userInitiated && switchedFromStrip && !stripHidden)) && !wasWindow {
                openWindow?()
            }
            strip.dismiss()
        }
        decision = next
        if case .strip = next {
            defaults.set("strip", forKey: Self.decisionKey)
        } else {
            defaults.set("floating", forKey: Self.decisionKey)
        }
        CockpitWindowVisibility.shared.refresh()
        onDecisionChange?(userInitiated)
    }

    private static func isBuiltin(_ id: UInt32) -> Bool {
        CGDisplayIsBuiltin(id) != 0
    }
}
