import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingView<AnyView>?
    private let indexer: SessionIndexer
    private let codexStatus: CodexUsageModel
    private let claudeStatus: ClaudeUsageModel
    private var cancellables: Set<AnyCancellable> = []

    init(indexer: SessionIndexer,
         codexStatus: CodexUsageModel,
         claudeStatus: ClaudeUsageModel) {
        self.indexer = indexer
        self.codexStatus = codexStatus
        self.claudeStatus = claudeStatus
        super.init()
    }

    func setEnabled(_ enabled: Bool) {
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
            DispatchQueue.main.async { [weak self] in self?.updateLength() }

            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        // Keep width in sync with live usage changes.
        cancellables.removeAll()
        codexStatus.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLength() }
            .store(in: &cancellables)
        claudeStatus.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLength() }
            .store(in: &cancellables)

        // No popover; we construct an NSMenu on demand in togglePopover
    }

    private func updateLength() {
        guard let item = statusItem, let hv = hosting else { return }
        let size = hv.fittingSize
        item.length = max(24, size.width)
    }

    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        cancellables.removeAll()
        // nothing else
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
        let desiredSource = MenuBarSource(rawValue: d.string(forKey: "MenuBarSource") ?? MenuBarSource.codex.rawValue) ?? .codex
        let style = MenuBarStyleKind(rawValue: d.string(forKey: "MenuBarStyle") ?? MenuBarStyleKind.bars.rawValue) ?? .bars
        let scope = MenuBarScope(rawValue: d.string(forKey: "MenuBarScope") ?? MenuBarScope.both.rawValue) ?? .both
        let source: MenuBarSource = {
            if codexAgentEnabled && claudeAgentEnabled { return desiredSource }
            if codexAgentEnabled { return .codex }
            if claudeAgentEnabled { return .claude }
            return desiredSource
        }()

        // Reset lines (clicking opens Preferences → Menu Bar)
        if codexAgentEnabled && (source == .codex || source == .both) {
            menu.addItem(makeTitleItem("Codex"))
            menu.addItem(makeActionItem(title: resetLine(label: "5h:", percent: codexStatus.fiveHourRemainingPercent, reset: staleAwareResetText(kind: "5h", source: .codex, raw: codexStatus.fiveHourResetText, lastUpdate: codexStatus.lastUpdate, eventTimestamp: codexStatus.lastEventTimestamp)), action: #selector(openPreferences)))
            menu.addItem(makeActionItem(title: resetLine(label: "Wk:", percent: codexStatus.weekRemainingPercent, reset: staleAwareResetText(kind: "Wk", source: .codex, raw: codexStatus.weekResetText, lastUpdate: codexStatus.lastUpdate, eventTimestamp: codexStatus.lastEventTimestamp)), action: #selector(openPreferences)))
        }
        let claudeEnabled = UserDefaults.standard.bool(forKey: "ClaudeUsageEnabled")
        if source == .both && codexAgentEnabled && claudeAgentEnabled && claudeEnabled { menu.addItem(NSMenuItem.separator()) }
        if claudeAgentEnabled && (source == .claude || source == .both) && claudeEnabled {
            menu.addItem(makeTitleItem("Claude"))
            menu.addItem(makeActionItem(title: resetLine(label: "5h:", percent: claudeStatus.sessionRemainingPercent, reset: staleAwareResetText(kind: "5h", source: .claude, raw: claudeStatus.sessionResetText, lastUpdate: claudeStatus.lastUpdate, eventTimestamp: nil)), action: #selector(openPreferences)))
            menu.addItem(makeActionItem(title: resetLine(label: "Wk:", percent: claudeStatus.weekAllModelsRemainingPercent, reset: staleAwareResetText(kind: "Wk", source: .claude, raw: claudeStatus.weekAllModelsResetText, lastUpdate: claudeStatus.lastUpdate, eventTimestamp: nil)), action: #selector(openPreferences)))
        }

        menu.addItem(NSMenuItem.separator())

        // Menu bar label toggles (saves status-item width; does not affect these menu lines)
        menu.addItem(makeTitleItem("Menu Bar Label"))
        let showCodexResetIndicators = d.object(forKey: PreferencesKey.MenuBar.showCodexResetTimes) as? Bool ?? true
        let showClaudeResetIndicators = d.object(forKey: PreferencesKey.MenuBar.showClaudeResetTimes) as? Bool ?? true
        let codexToggle = makeCheckboxItem(title: "Show Codex reset indicators", checked: showCodexResetIndicators, action: #selector(toggleShowCodexResetTimes))
        codexToggle.isEnabled = codexAgentEnabled
        menu.addItem(codexToggle)
        let claudeToggle = makeCheckboxItem(title: "Show Claude reset indicators", checked: showClaudeResetIndicators, action: #selector(toggleShowClaudeResetTimes))
        claudeToggle.isEnabled = claudeAgentEnabled && claudeEnabled
        menu.addItem(claudeToggle)

        menu.addItem(NSMenuItem.separator())

        // Source
        menu.addItem(makeTitleItem("Source"))
        let srcCodex = makeRadioItem(title: MenuBarSource.codex.title, selected: source == .codex, action: #selector(setSourceCodex))
        srcCodex.isEnabled = codexAgentEnabled
        menu.addItem(srcCodex)
        let srcClaude = makeRadioItem(title: MenuBarSource.claude.title, selected: source == .claude, action: #selector(setSourceClaude))
        srcClaude.isEnabled = claudeAgentEnabled
        menu.addItem(srcClaude)
        let srcBoth = makeRadioItem(title: MenuBarSource.both.title, selected: source == .both, action: #selector(setSourceBoth))
        srcBoth.isEnabled = codexAgentEnabled && claudeAgentEnabled
        menu.addItem(srcBoth)

        // Style
        menu.addItem(makeTitleItem("Style"))
        menu.addItem(makeRadioItem(title: MenuBarStyleKind.bars.title, selected: style == .bars, action: #selector(setStyleBars)))
        menu.addItem(makeRadioItem(title: MenuBarStyleKind.numbers.title, selected: style == .numbers, action: #selector(setStyleNumbers)))

        // Scope
        menu.addItem(makeTitleItem("Scope"))
        menu.addItem(makeRadioItem(title: MenuBarScope.fiveHour.title, selected: scope == .fiveHour, action: #selector(setScope5h)))
        menu.addItem(makeRadioItem(title: MenuBarScope.weekly.title, selected: scope == .weekly, action: #selector(setScopeWeekly)))
        menu.addItem(makeRadioItem(title: MenuBarScope.both.title, selected: scope == .both, action: #selector(setScopeBoth)))

        menu.addItem(NSMenuItem.separator())

        if codexAgentEnabled {
            menu.addItem(makeActionItem(title: "Hard Refresh Codex", action: #selector(refreshCodexHard)))
        }
        if claudeAgentEnabled && claudeEnabled {
            menu.addItem(makeActionItem(title: "Hard Refresh Claude", action: #selector(refreshClaudeHard)))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeActionItem(title: "Open Preferences…", action: #selector(openPreferences)))
        menu.addItem(makeActionItem(title: "Hide Menu Bar Usage", action: #selector(hideMenuBar)))

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
    @objc private func openPreferences() {
        if let updater = UpdaterController.shared {
            PreferencesWindowController.shared.show(indexer: indexer, updaterController: updater, initialTab: .usageTracking)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func refreshCodexHard() {
        guard !codexStatus.isUpdating else { return }
        codexStatus.hardProbeNowDiagnostics { diag in
            if !diag.success { self.presentFailureAlert(title: "Codex Probe Failed", diagnostics: diag) }
        }
    }
    @objc private func refreshClaudeHard() {
        guard !claudeStatus.isUpdating else { return }
        claudeStatus.hardProbeNowDiagnostics { diag in
            if !diag.success { self.presentFailureAlert(title: "Claude Probe Failed", diagnostics: diag) }
        }
    }
    @objc private func hideMenuBar() {
        UserDefaults.standard.set(false, forKey: "MenuBarEnabled")
        // The App listens to this key and hides the status item.
    }
    // Lightweight replica of reset line
    private func resetLine(label: String, percent: Int, reset: String) -> String {
        let mode = UsageDisplayMode.current()
        let clampedLeft = max(0, min(100, percent))
        let displayPercent = mode.numericPercent(fromLeft: clampedLeft)
        let trimmed = reset.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(label) \(displayPercent)% \(mode.suffix)  \(trimmed.isEmpty ? "—" : trimmed)"
    }
}

// MARK: - Stale + Helpers
extension StatusItemController {
    private func staleAwareResetText(kind: String, source: UsageTrackingSource, raw: String, lastUpdate: Date?, eventTimestamp: Date?) -> String {
        return formatResetDisplayForMenu(kind: kind, source: source, raw: raw, lastUpdate: lastUpdate, eventTimestamp: eventTimestamp)
    }

    private func presentFailureAlert(title: String, diagnostics: Any) {
        guard let win = NSApp.windows.first else { return }
        let alert = NSAlert()
        alert.messageText = title
        if let d = diagnostics as? CodexProbeDiagnostics {
            alert.informativeText = "Exit: \(d.exitCode)\nScript: \(d.scriptPath)\nWORKDIR: \(d.workdir)\n\n— stdout —\n\(d.stdout)\n\n— stderr —\n\(d.stderr)"
        } else if let d = diagnostics as? ClaudeProbeDiagnostics {
            alert.informativeText = "Exit: \(d.exitCode)\nScript: \(d.scriptPath)\nWORKDIR: \(d.workdir)\n\n— stdout —\n\(d.stdout)\n\n— stderr —\n\(d.stderr)"
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: win) { _ in }
    }
}
