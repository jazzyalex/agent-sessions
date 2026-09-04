import AppKit
import SwiftUI
import Combine

/// Boxes a `UsageAuthStatus` so it can ride on an `NSMenuItem.representedObject`
/// (Any?) and be recovered in the click handler that opens the Fix dialog.
private final class AuthStatusBox {
    let status: UsageAuthStatus
    init(status: UsageAuthStatus) { self.status = status }
}

@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingView<AnyView>?
    private let indexer: SessionIndexer
    private let claudeIndexer: ClaudeSessionIndexer
    private let opencodeIndexer: OpenCodeSessionIndexer
    private let activeSessions: CodexActiveSessionsModel
    private let codexStatus: CodexUsageModel
    private let claudeStatus: ClaudeUsageModel
    private var cancellables: Set<AnyCancellable> = []
    private var lengthUpdateScheduled: Bool = false
    var visibilityDidChange: ((Bool) -> Void)?

    init(indexer: SessionIndexer,
         claudeIndexer: ClaudeSessionIndexer,
         opencodeIndexer: OpenCodeSessionIndexer,
         activeSessions: CodexActiveSessionsModel,
         codexStatus: CodexUsageModel,
         claudeStatus: ClaudeUsageModel) {
        self.indexer = indexer
        self.claudeIndexer = claudeIndexer
        self.opencodeIndexer = opencodeIndexer
        self.activeSessions = activeSessions
        self.codexStatus = codexStatus
        self.claudeStatus = claudeStatus
        super.init()
    }

    func setEnabled(_ enabled: Bool) {
        guard !AppRuntime.isRunningTests else {
            if !enabled {
                removeStatusItem()
            }
            return
        }
        if enabled {
            ensureStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            // Clear any default title/image and embed SwiftUI label view
            button.title = ""
            button.image = nil
            let labelView = UsageMenuBarLabel()
                .environment(activeSessions)
                .environmentObject(indexer)
                .environmentObject(claudeIndexer)
                .environmentObject(opencodeIndexer)
                .environmentObject(codexStatus)
                .environmentObject(claudeStatus)
            let hv = NSHostingView(rootView: AnyView(labelView))
            hv.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hv.topAnchor.constraint(equalTo: button.topAnchor),
                hv.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            self.hosting = hv
            scheduleLengthUpdate()
            scheduleVisibilityCheck()

            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        // Keep width in sync with live-session and usage changes.
        //
        // `activeSessions` (an `@Observable` model, post-W6) no longer has a
        // synthesized `objectWillChange` to subscribe to as a single
        // catch-all. `scheduleLengthUpdate` -> `updateLength()` just
        // re-measures `hv.fittingSize` and is cheap + coalesced
        // (`lengthUpdateScheduled` debounce), so — unlike the SwiftUI view
        // bodies this migration scopes down to only their actually-read
        // properties — there is no payoff to narrowing this imperative,
        // off-body Combine subscriber to only `membershipTicks` (the one
        // that actually changes `LiveSessionMenuBarLabel`'s rendered
        // content/width today). Subscribing all three explicit bridge
        // subjects reproduces the old `objectWillChange`-catch-all trigger
        // surface exactly, at negligible cost.
        cancellables.removeAll()
        activeSessions.membershipTicks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleLengthUpdate() }
            .store(in: &cancellables)
        activeSessions.badgeTicks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleLengthUpdate() }
            .store(in: &cancellables)
        activeSessions.presenceUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleLengthUpdate() }
            .store(in: &cancellables)
        codexStatus.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleLengthUpdate() }
            .store(in: &cancellables)
        claudeStatus.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleLengthUpdate() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let isEnabled = UserDefaults.standard.object(forKey: PreferencesKey.menuBarEnabled) as? Bool ?? false
                if isEnabled {
                    self.scheduleLengthUpdate()
                } else {
                    self.removeStatusItem()
                }
            }
            .store(in: &cancellables)

        // No popover; we construct an NSMenu on demand in togglePopover
    }

    private func updateLength() {
        guard let item = statusItem, let hv = hosting else { return }
        let size = hv.fittingSize
        item.length = max(24, size.width)
        scheduleVisibilityCheck()
    }

    private func scheduleLengthUpdate() {
        guard !lengthUpdateScheduled else { return }
        lengthUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lengthUpdateScheduled = false
            self.updateLength()
        }
    }

    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        cancellables.removeAll()
        visibilityDidChange?(false)
        // nothing else
    }

    private func scheduleVisibilityCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self else { return }
            self.visibilityDidChange?(self.statusItem?.button?.window != nil)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let item = statusItem else { return }
        let menu = buildMenu()
        item.menu = menu
        // This will anchor the menu and close it automatically on selection
        button.performClick(nil)
        item.menu = nil
    }

    // MARK: - Menu
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let d = UserDefaults.standard
        let codexAgentEnabled = d.object(forKey: PreferencesKey.Agents.codexEnabled) as? Bool ?? true
        let claudeAgentEnabled = d.object(forKey: PreferencesKey.Agents.claudeEnabled) as? Bool ?? true
        let codexUsageEnabled = d.object(forKey: PreferencesKey.codexUsageEnabled) as? Bool ?? false
        let claudeUsageEnabled = d.object(forKey: PreferencesKey.claudeUsageEnabled) as? Bool ?? false
        let liveSessionsEnabled = d.object(forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled) as? Bool ?? true
        let showLiveSessionIcons = d.object(forKey: PreferencesKey.MenuBar.showLiveSessionIcons) as? Bool ?? true
        let codexTrackingEnabled = codexAgentEnabled && codexUsageEnabled
        let claudeTrackingEnabled = claudeAgentEnabled && claudeUsageEnabled
        let anyUsageTrackingEnabled = codexTrackingEnabled || claudeTrackingEnabled
        let desiredSource = MenuBarSource(rawValue: d.string(forKey: "MenuBarSource") ?? MenuBarSource.codex.rawValue) ?? .codex
        let style = MenuBarStyleKind(rawValue: d.string(forKey: "MenuBarStyle") ?? MenuBarStyleKind.bars.rawValue) ?? .bars
        let scope = MenuBarScope(rawValue: d.string(forKey: "MenuBarScope") ?? MenuBarScope.both.rawValue) ?? .both
        let source: MenuBarSource = {
            if codexTrackingEnabled && claudeTrackingEnabled { return desiredSource }
            if codexTrackingEnabled { return .codex }
            if claudeTrackingEnabled { return .claude }
            return desiredSource
        }()

        // Auth remediation (Task 12): one quiet line per provider whose CLI
        // auth needs attention (signed out / expired / CLI missing). Mirrors
        // the AuthRemediationBanner shown in the usage strips, condensed to
        // a single tappable menu row that opens Usage Tracking preferences.
        var didShowAuthAlert = false
        if codexTrackingEnabled, let codexAuth = codexStatus.authStatus, codexAuth.state.isAlarming {
            menu.addItem(makeAuthAlertItem(provider: .codex, status: codexAuth))
            didShowAuthAlert = true
        }
        if claudeTrackingEnabled, let claudeAuth = claudeStatus.authStatus, claudeAuth.state.isAlarming {
            menu.addItem(makeAuthAlertItem(provider: .claude, status: claudeAuth))
            didShowAuthAlert = true
        }
        if didShowAuthAlert {
            menu.addItem(NSMenuItem.separator())
        }

        if liveSessionsEnabled {
            let summary = AgentCockpitHUDView.liveSessionSummary(
                activeCodex: activeSessions,
                codexIndexer: indexer,
                claudeIndexer: claudeIndexer,
                opencodeIndexer: opencodeIndexer
            )
            menu.addItem(makeTitleItem(String(localized: "Live Sessions", comment: "Heading for active agent sessions in the menu bar menu.")))
            menu.addItem(makeTitleItem(String(localized: "\(summary.activeCount) active • \(summary.waitingCount) waiting", comment: "Menu bar summary of active and waiting agent sessions.")))
            let cockpitVisible = AppWindowRouter.isAgentCockpitWindowVisible
            menu.addItem(makeActionItem(
                title: cockpitVisible ? String(localized: "Hide Quota Meter", comment: "Menu command that hides the Quota Meter window.") : String(localized: "Open Quota Meter", comment: "Menu command that opens the Quota Meter window."),
                action: cockpitVisible ? #selector(hideAgentCockpit) : #selector(openAgentCockpit)
            ))
            let sessionsVisible = AppWindowRouter.isAgentSessionsWindowVisible
            menu.addItem(makeActionItem(
                title: sessionsVisible ? String(localized: "Hide Agent Sessions", comment: "Menu command that hides the main app window.") : String(localized: "Open Agent Sessions", comment: "Menu command that opens the main app window."),
                action: sessionsVisible ? #selector(hideAgentSessions) : #selector(openAgentSessions)
            ))
        }

        let liveSessionsToggle = makeCheckboxItem(
            title: String(localized: "Show Active/Waiting sessions", comment: "Menu toggle for active and waiting session icons."),
            checked: showLiveSessionIcons,
            action: #selector(toggleShowLiveSessionIcons)
        )
        liveSessionsToggle.isEnabled = liveSessionsEnabled
        menu.addItem(liveSessionsToggle)

        if liveSessionsEnabled && anyUsageTrackingEnabled {
            menu.addItem(NSMenuItem.separator())
        }

        if anyUsageTrackingEnabled {
            // Reset lines open Usage Tracking preferences because they control probes and refresh details.
            if codexTrackingEnabled && (source == .codex || source == .both) {
                menu.addItem(makeTitleItem("Codex"))
                menu.addItem(makeActionItem(title: codexResetMenuTitle(label: "5h:", percent: codexStatus.fiveHourRemainingPercent, reset: staleAwareResetText(kind: "5h", source: .codex, raw: codexStatus.fiveHourResetText, lastUpdate: codexStatus.lastUpdate, eventTimestamp: codexStatus.lastEventTimestamp), has: codexStatus.hasFiveHourRateLimit), action: #selector(openUsagePreferences)))
                menu.addItem(makeActionItem(title: codexResetMenuTitle(label: "Wk:", percent: codexStatus.weekRemainingPercent, reset: staleAwareResetText(kind: "Wk", source: .codex, raw: codexStatus.weekResetText, lastUpdate: codexStatus.lastUpdate, eventTimestamp: codexStatus.lastEventTimestamp), has: codexStatus.hasWeekRateLimit), action: #selector(openUsagePreferences)))
                // Reset credits (free "reset your usage now" grants), shown only when present.
                if let creditsSummary = CodexResetCredits.menuSummaryLine(codexStatus.resetCredits, now: Date()) {
                    menu.addItem(makeTitleItem(String(localized: "Reset credits", comment: "Heading for available usage reset credits.")))
                    menu.addItem(makeActionItem(title: creditsSummary, action: #selector(openUsagePreferences)))
                    let expiryLines = CodexResetCredits.menuExpiryLines(codexStatus.resetCredits, now: Date())
                    if expiryLines.count > 1 {
                        for line in expiryLines {
                            menu.addItem(makeTitleItem(line))
                        }
                    }
                }
            }
            if source == .both && codexTrackingEnabled && claudeTrackingEnabled { menu.addItem(NSMenuItem.separator()) }
            if claudeTrackingEnabled && (source == .claude || source == .both) {
                menu.addItem(makeTitleItem("Claude"))
                if claudeStatus.setupRequired {
                    menu.addItem(makeActionItem(title: String(localized: "Copy setup command: claude", comment: "Menu command that copies the verbatim Claude setup command."), action: #selector(copyClaudeCommand)))
                }
                menu.addItem(makeActionItem(title: claudeResetLine(label: "5h:", percent: claudeStatus.sessionRemainingPercent, reset: staleAwareResetText(kind: "5h", source: .claude, raw: claudeStatus.sessionResetText, lastUpdate: claudeStatus.lastUpdate, eventTimestamp: nil)), action: #selector(openUsagePreferences)))
                menu.addItem(makeActionItem(title: claudeResetLine(label: "Wk:", percent: claudeStatus.weekAllModelsRemainingPercent, reset: staleAwareResetText(kind: "Wk", source: .claude, raw: claudeStatus.weekAllModelsResetText, lastUpdate: claudeStatus.lastUpdate, eventTimestamp: nil)), action: #selector(openUsagePreferences)))
                // Model-scoped weekly window ("Current week (Fable)"). The compact meter has
                // a fixed-width Wk column that always shows the all-models figure, so this is
                // where the scoped window gets named — the dropdown has the room the strip
                // does not. Shown only when the server names the model: an unlabelled scoped
                // percentage next to the weekly one reads as a contradiction, not a second
                // window.
                // Only while there is a real number to show. The label survives a fetch
                // failure, and `claudeResetLine` renders a caption instead of a percent in
                // every non-live state — so without this the dropdown would repeat
                // "No active session" a third time under a window nobody can act on.
                if case .live = QuotaData.claude(from: claudeStatus).presentationState,
                   let scopedLabel = claudeStatus.weekScopedLabel,
                   let scopedPercent = claudeStatus.weekOpusRemainingPercent {
                    menu.addItem(makeActionItem(title: claudeResetLine(label: "Wk \(scopedLabel):", percent: scopedPercent, reset: staleAwareResetText(kind: "Wk", source: .claude, raw: claudeStatus.weekOpusResetText ?? "", lastUpdate: claudeStatus.lastUpdate, eventTimestamp: nil)), action: #selector(openUsagePreferences)))
                }
                // Calm idle explainer — the "No active session" reset lines above
                // say what; this one line says when it comes back. Mirrors the
                // footer / HUD idle cells' tooltip.
                if let auth = claudeStatus.authStatus, auth.state == .idle {
                    menu.addItem(makeTitleItem(String(localized: auth.detail)))
                }
                // Calm transient caption (P2) — beneath the Claude meters, no alarm.
                if claudeStatus.transientReason != nil {
                    let caption = QuotaData.claude(from: claudeStatus).reconnectingCaption
                    menu.addItem(makeTitleItem(String(localized: caption)))
                }
                // Honest source label (P4): CLI-probe fallback vs OAuth endpoint.
                if claudeStatus.currentSource == .tmuxUsage {
                    menu.addItem(makeTitleItem(String(localized: "via CLI probe", comment: "Menu label identifying the current usage data source.")))
                }
            }

            menu.addItem(NSMenuItem.separator())

            menu.addItem(makeTitleItem(String(localized: "Menu Bar Label", comment: "Heading for menu bar label settings.")))
            let showCodexResetIndicators = d.object(forKey: PreferencesKey.MenuBar.showCodexResetTimes) as? Bool ?? true
            let showClaudeResetIndicators = d.object(forKey: PreferencesKey.MenuBar.showClaudeResetTimes) as? Bool ?? true
            let codexToggle = makeCheckboxItem(title: String(localized: "Show Codex reset indicators", comment: "Menu toggle for Codex reset indicators."), checked: showCodexResetIndicators, action: #selector(toggleShowCodexResetTimes))
            codexToggle.isEnabled = codexTrackingEnabled
            menu.addItem(codexToggle)
            let claudeToggle = makeCheckboxItem(title: String(localized: "Show Claude reset indicators", comment: "Menu toggle for Claude reset indicators."), checked: showClaudeResetIndicators, action: #selector(toggleShowClaudeResetTimes))
            claudeToggle.isEnabled = claudeTrackingEnabled
            menu.addItem(claudeToggle)

            menu.addItem(NSMenuItem.separator())

            menu.addItem(makeTitleItem(String(localized: "Source", comment: "Heading for menu bar usage source choices.")))
            let srcCodex = makeRadioItem(title: String(localized: MenuBarSource.codex.title), selected: source == .codex, action: #selector(setSourceCodex))
            srcCodex.isEnabled = codexTrackingEnabled
            menu.addItem(srcCodex)
            let srcClaude = makeRadioItem(title: String(localized: MenuBarSource.claude.title), selected: source == .claude, action: #selector(setSourceClaude))
            srcClaude.isEnabled = claudeTrackingEnabled
            menu.addItem(srcClaude)
            let srcBoth = makeRadioItem(title: String(localized: MenuBarSource.both.title), selected: source == .both, action: #selector(setSourceBoth))
            srcBoth.isEnabled = codexTrackingEnabled && claudeTrackingEnabled
            menu.addItem(srcBoth)

            menu.addItem(makeTitleItem(String(localized: "Style", comment: "Heading for menu bar display style choices.")))
            menu.addItem(makeRadioItem(title: String(localized: MenuBarStyleKind.bars.title), selected: style == .bars, action: #selector(setStyleBars)))
            menu.addItem(makeRadioItem(title: String(localized: MenuBarStyleKind.numbers.title), selected: style == .numbers, action: #selector(setStyleNumbers)))

            menu.addItem(makeTitleItem(String(localized: "Scope", comment: "Heading for menu bar quota scope choices.")))
            menu.addItem(makeRadioItem(title: String(localized: MenuBarScope.fiveHour.title), selected: scope == .fiveHour, action: #selector(setScope5h)))
            menu.addItem(makeRadioItem(title: String(localized: MenuBarScope.weekly.title), selected: scope == .weekly, action: #selector(setScopeWeekly)))
            menu.addItem(makeRadioItem(title: String(localized: MenuBarScope.both.title), selected: scope == .both, action: #selector(setScopeBoth)))

            menu.addItem(NSMenuItem.separator())

            if codexTrackingEnabled {
                menu.addItem(makeActionItem(title: String(localized: "Hard Refresh Codex", comment: "Menu command that force-refreshes Codex usage."), action: #selector(refreshCodexHard)))
            }
            if claudeTrackingEnabled {
                menu.addItem(makeActionItem(title: String(localized: "Hard Refresh Claude", comment: "Menu command that force-refreshes Claude usage."), action: #selector(refreshClaudeHard)))
            }
            menu.addItem(NSMenuItem.separator())
        }

        menu.addItem(makeActionItem(title: String(localized: "Open Settings…", comment: "Menu command that opens Settings."), action: #selector(openMenuBarPreferences)))
        menu.addItem(makeActionItem(title: String(localized: "Hide Menu Bar Item", comment: "Menu command that hides the app menu bar item."), action: #selector(hideMenuBar)))
        menu.addItem(makeActionItem(
            title: DockIconPreferenceController.dockIconMenuTitle(defaults: d),
            action: #selector(toggleHideDockIcon)
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeActionItem(title: String(localized: "Quit", comment: "Menu command that quits the app."), action: #selector(quitApp)))

        return menu
    }

    private func makeTitleItem(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }
    private func makeActionItem(title: String, action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }
    private func makeRadioItem(title: String, selected: Bool, action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.state = selected ? .on : .off
        return it
    }
    private func makeCheckboxItem(title: String, checked: Bool, action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.state = checked ? .on : .off
        return it
    }
    private func makeAuthAlertItem(provider: AuthProvider, status: UsageAuthStatus) -> NSMenuItem {
        let it = NSMenuItem(title: authAlertText(provider: provider, state: status.state), action: #selector(handleAuthRemediation(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = AuthStatusBox(status: status)
        let symbolName: String
        let tint: NSColor
        switch status.state {
        case .expired:
            symbolName = "clock.badge.exclamationmark"
            tint = .systemOrange
        case .accountUnavailable:
            symbolName = "person.crop.circle.badge.exclamationmark"
            tint = .systemOrange
        case .cliNotInstalled:
            symbolName = "bolt.horizontal.circle"
            tint = .secondaryLabelColor
        default:
            symbolName = "exclamationmark.triangle.fill"
            tint = .systemRed
        }
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            it.image = symbol.withSymbolConfiguration(.init(paletteColors: [tint]))
        }
        return it
    }
    private func authAlertText(provider: AuthProvider, state: UsageAuthState) -> String {
        let name = provider.displayName
        switch state {
        case .signedOut: return String(localized: "\(name) signed out — Fix…", comment: "Menu command for repairing a signed-out provider; provider name remains verbatim.")
        case .expired: return String(localized: "\(name) session expired — Fix…", comment: "Menu command for repairing an expired provider session; provider name remains verbatim.")
        case .accountUnavailable: return String(localized: "\(name) account access unavailable — Fix…", comment: "Menu command for unavailable provider account access; provider name remains verbatim.")
        case .cliNotInstalled: return String(localized: "\(name) CLI not installed — Fix…", comment: "Menu command for a missing provider CLI; provider name remains verbatim.")
        default: return name
        }
    }

    /// Clicking a menu-bar auth alert opens the shared guided Fix dialog — the
    /// same one the footer/HUD "Fix…" buttons open — so remediation is one
    /// consistent, explained flow rather than a dead-end Preferences pane.
    @objc private func handleAuthRemediation(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? AuthStatusBox else {
            openUsagePreferences(); return
        }
        AuthFixWindowController.shared.show(status: box.status)
    }

    // MARK: - Actions
    @objc private func setSourceCodex() { UserDefaults.standard.set(MenuBarSource.codex.rawValue, forKey: "MenuBarSource"); updateLength() }
    @objc private func setSourceClaude() { UserDefaults.standard.set(MenuBarSource.claude.rawValue, forKey: "MenuBarSource"); updateLength() }
    @objc private func setSourceBoth() { UserDefaults.standard.set(MenuBarSource.both.rawValue, forKey: "MenuBarSource"); updateLength() }
    @objc private func setStyleBars() { UserDefaults.standard.set(MenuBarStyleKind.bars.rawValue, forKey: "MenuBarStyle"); updateLength() }
    @objc private func setStyleNumbers() { UserDefaults.standard.set(MenuBarStyleKind.numbers.rawValue, forKey: "MenuBarStyle"); updateLength() }
    @objc private func setScope5h() { UserDefaults.standard.set(MenuBarScope.fiveHour.rawValue, forKey: "MenuBarScope"); updateLength() }
    @objc private func setScopeWeekly() { UserDefaults.standard.set(MenuBarScope.weekly.rawValue, forKey: "MenuBarScope"); updateLength() }
    @objc private func setScopeBoth() { UserDefaults.standard.set(MenuBarScope.both.rawValue, forKey: "MenuBarScope"); updateLength() }
    @objc private func toggleShowCodexResetTimes() {
        let d = UserDefaults.standard
        let current = d.object(forKey: PreferencesKey.MenuBar.showCodexResetTimes) as? Bool ?? true
        d.set(!current, forKey: PreferencesKey.MenuBar.showCodexResetTimes)
        updateLength()
    }
    @objc private func toggleShowClaudeResetTimes() {
        let d = UserDefaults.standard
        let current = d.object(forKey: PreferencesKey.MenuBar.showClaudeResetTimes) as? Bool ?? true
        d.set(!current, forKey: PreferencesKey.MenuBar.showClaudeResetTimes)
        updateLength()
    }

    @objc private func toggleShowLiveSessionIcons() {
        let d = UserDefaults.standard
        let current = d.object(forKey: PreferencesKey.MenuBar.showLiveSessionIcons) as? Bool ?? true
        d.set(!current, forKey: PreferencesKey.MenuBar.showLiveSessionIcons)
        updateLength()
    }
    @objc private func openUsagePreferences() {
        if let updater = UpdaterController.shared {
            PreferencesWindowController.shared.show(indexer: indexer, updaterController: updater, initialTab: .usageTracking)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openMenuBarPreferences() {
        if let updater = UpdaterController.shared {
            PreferencesWindowController.shared.show(indexer: indexer, updaterController: updater, initialTab: .menuBar)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openAgentCockpit() {
        AppWindowRouter.showAgentCockpitWindow()
    }
    @objc private func hideAgentCockpit() {
        AppWindowRouter.closeAgentCockpitWindow()
    }
    @objc private func openAgentSessions() {
        AppWindowRouter.showAgentSessionsWindow()
    }
    @objc private func hideAgentSessions() {
        AppWindowRouter.closeAgentSessionsWindow()
    }
    @objc private func refreshCodexHard() {
        let d = UserDefaults.standard
        let codexTrackingEnabled = (d.object(forKey: PreferencesKey.Agents.codexEnabled) as? Bool ?? true)
            && (d.object(forKey: PreferencesKey.codexUsageEnabled) as? Bool ?? false)
        guard codexTrackingEnabled else { return }
        ProbeCoordinator.shared.request(.codex) { report in
            guard case .codex(let diag) = report else { return }
            if !diag.success { self.presentFailureAlert(title: "Codex Probe Failed", diagnostics: diag) }
        }
    }
    @objc private func refreshClaudeHard() {
        let d = UserDefaults.standard
        let claudeTrackingEnabled = (d.object(forKey: PreferencesKey.Agents.claudeEnabled) as? Bool ?? true)
            && (d.object(forKey: PreferencesKey.claudeUsageEnabled) as? Bool ?? false)
        guard claudeTrackingEnabled else { return }
        ProbeCoordinator.shared.request(.claude) { report in
            guard case .claude(let diag) = report else { return }
            if !diag.success { self.presentFailureAlert(title: "Claude Probe Failed", diagnostics: diag) }
            else if diag.unavailableMessage != nil { self.presentFailureAlert(title: "Claude Probe Unavailable", diagnostics: diag) }
        }
    }
    @objc private func copyClaudeCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("claude", forType: .string)
    }
    @objc private func hideMenuBar() {
        DockIconPreferenceController.setMenuBarEnabled(false)
        // The App listens to this key and hides the status item.
    }
    @objc private func toggleHideDockIcon() {
        DockIconPreferenceController.toggleDockIconHidden()
    }
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    // Lightweight replica of reset line
    private func resetLine(label: String, percent: Int, reset: String) -> String {
        let trimmed = reset.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == UsageStaleThresholds.unavailableCopy {
            return "\(label) --  \(UsageStaleThresholds.localizedUnavailableCopy)"
        }
        let mode = UsageDisplayMode.current()
        let clampedLeft = max(0, min(100, percent))
        let displayPercent = mode.numericPercent(fromLeft: clampedLeft)
        let suffix = String(localized: mode.suffix)
        return "\(label) \(displayPercent)% \(suffix)  \(trimmed.isEmpty ? "—" : trimmed)"
    }

    /// Per-line presentation for the Codex 5h/Wk menu rows: real data uses the
    /// existing `resetLine`; a recognized absence (provider intentionally
    /// omitted the window, e.g. OpenAI pausing the 5h limit) reads "no limit";
    /// a suspect payload (couldn't confidently classify it) reads "can't verify"
    /// instead of a dead "0%" line. Before the first successful poll we show a
    /// neutral "—" rather than falsely asserting "no limit".
    private func codexResetMenuTitle(label: String, percent: Int, reset: String, has: Bool) -> String {
        if has {
            return resetLine(label: label, percent: percent, reset: reset)
        } else if codexStatus.lastUpdate == nil {
            return String(localized: "\(label) —", comment: "Menu bar quota row before the first successful refresh; the quota label remains verbatim.")
        } else {
            return String(localized: "\(label) \(UsageLimitAbsenceCopy.localizedLabel(suspect: codexStatus.usageFormatSuspect))", comment: "Menu bar quota row for an absent or unverifiable limit; the quota label remains verbatim.")
        }
    }

    private func claudeResetLine(label: String, percent: Int, reset: String) -> String {
        // Same shared state as the footer and menu-bar face, so all three surfaces
        // read alike. Never a misleading "0% / no resets" (reads as exhausted):
        // `.reconnecting` says so, `.needsAction` shows unavailable (the auth-alert
        // row above carries the fix command).
        let quota = QuotaData.claude(from: claudeStatus)
        switch quota.presentationState {
        case .needsAction:
            return String(localized: "\(label) --  Usage unavailable", comment: "Menu bar quota row when usage needs action; the quota label remains verbatim.")
        case .idle:
            return String(localized: "\(label) --  No active session", comment: "Menu bar quota row when there is no active session; the quota label remains verbatim.")
        case .reconnecting:
            let caption = String(localized: quota.reconnectingCaption)
            return String(localized: "\(label) --  \(caption)", comment: "Menu bar quota row while reconnecting; the quota label remains verbatim.")
        case .live:
            return resetLine(label: label, percent: percent, reset: reset)
        }
    }
}

// MARK: - Stale + Helpers
extension StatusItemController {
    private func staleAwareResetText(kind: String, source: UsageTrackingSource, raw: String, lastUpdate: Date?, eventTimestamp: Date?) -> String {
        return formatResetDisplayForMenu(kind: kind, source: source, raw: raw, lastUpdate: lastUpdate, eventTimestamp: eventTimestamp)
    }

    private func presentFailureAlert(title: LocalizedStringResource, diagnostics: Any) {
        guard let win = NSApp.windows.first else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: title)
        if let d = diagnostics as? CodexProbeDiagnostics {
            alert.informativeText = "Exit: \(d.exitCode)\nScript: \(d.scriptPath)\nWORKDIR: \(d.workdir)\n\n— stdout —\n\(d.stdout)\n\n— stderr —\n\(d.stderr)"
        } else if let d = diagnostics as? ClaudeProbeDiagnostics {
            alert.informativeText = "Exit: \(d.exitCode)\nScript: \(d.scriptPath)\nWORKDIR: \(d.workdir)\n\n— stdout —\n\(d.stdout)\n\n— stderr —\n\(d.stderr)"
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", comment: "Confirmation button in a probe failure alert."))
        alert.beginSheetModal(for: win) { _ in }
    }
}
