import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingView<AnyView>?
    private let indexer: SessionIndexer
    private let codexStatus: CodexUsageModel
    private let claudeStatus: ClaudeUsageModel

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
        let source = MenuBarSource(rawValue: d.string(forKey: "MenuBarSource") ?? MenuBarSource.codex.rawValue) ?? .codex
        let style = MenuBarStyleKind(rawValue: d.string(forKey: "MenuBarStyle") ?? MenuBarStyleKind.bars.rawValue) ?? .bars
        let scope = MenuBarScope(rawValue: d.string(forKey: "MenuBarScope") ?? MenuBarScope.both.rawValue) ?? .both

        // Reset lines (clicking opens Preferences → Menu Bar)
        if source == .codex || source == .both {
            menu.addItem(makeTitleItem("Codex"))
            menu.addItem(makeActionItem(title: resetLine(label: "5h:", percent: codexStatus.fiveHourPercent, reset: codexStatus.fiveHourResetText), action: #selector(openPreferences)))
            menu.addItem(makeActionItem(title: resetLine(label: "Wk:", percent: codexStatus.weekPercent, reset: codexStatus.weekResetText), action: #selector(openPreferences)))
        }
        let claudeEnabled = UserDefaults.standard.bool(forKey: "ShowClaudeUsageStrip")
        if source == .both && claudeEnabled { menu.addItem(NSMenuItem.separator()) }
        if (source == .claude || source == .both) && claudeEnabled {
            menu.addItem(makeTitleItem("Claude"))
            menu.addItem(makeActionItem(title: resetLine(label: "5h:", percent: claudeStatus.sessionPercent, reset: claudeStatus.sessionResetText), action: #selector(openPreferences)))
            menu.addItem(makeActionItem(title: resetLine(label: "Wk:", percent: claudeStatus.weekAllModelsPercent, reset: claudeStatus.weekAllModelsResetText), action: #selector(openPreferences)))
        }

        menu.addItem(NSMenuItem.separator())

        // Source
        menu.addItem(makeTitleItem("Source"))
        menu.addItem(makeRadioItem(title: MenuBarSource.codex.title, selected: source == .codex, action: #selector(setSourceCodex)))
        menu.addItem(makeRadioItem(title: MenuBarSource.claude.title, selected: source == .claude, action: #selector(setSourceClaude)))
        menu.addItem(makeRadioItem(title: MenuBarSource.both.title, selected: source == .both, action: #selector(setSourceBoth)))

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

        menu.addItem(makeActionItem(title: "Refresh Limits", action: #selector(refreshLimits)))
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
    @objc private func openPreferences() { PreferencesWindowController.shared.show(indexer: indexer, initialTab: .usageTracking); NSApp.activate(ignoringOtherApps: true) }
    @objc private func refreshLimits() {
        let src = UserDefaults.standard.string(forKey: "MenuBarSource") ?? MenuBarSource.codex.rawValue
        if src == MenuBarSource.codex.rawValue || src == MenuBarSource.both.rawValue { codexStatus.refreshNow() }
        if src == MenuBarSource.claude.rawValue || src == MenuBarSource.both.rawValue { claudeStatus.refreshNow() }
    }
    @objc private func hideMenuBar() {
        UserDefaults.standard.set(false, forKey: "MenuBarEnabled")
        // The App listens to this key and hides the status item.
    }
    // Lightweight replica of reset line
    private func resetLine(label: String, percent: Int, reset: String) -> String {
        let trimmed = reset.replacingOccurrences(of: "resets ", with: "")
        return "\(label) \(percent)%  \(trimmed.isEmpty ? "—" : trimmed)"
    }
}
