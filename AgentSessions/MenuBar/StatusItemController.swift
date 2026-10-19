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
    private let indexer: SessionIndexer
    private let claudeIndexer: ClaudeSessionIndexer
    private let opencodeIndexer: OpenCodeSessionIndexer
    private let activeSessions: CodexActiveSessionsModel
    private let codexStatus: CodexUsageModel
    private let claudeStatus: ClaudeUsageModel

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

    /// The status item is retired: the menu bar strip shows this menu on click
    /// (`QuotaStripController.menuProvider`). Kept so existing callers stay valid.
    func setEnabled(_ enabled: Bool) {}

    /// The strip's click menu: the old menu bar item's menu without its label options.
    func makeMenu() -> NSMenu { buildMenu() }

    // MARK: - Menu
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let d = UserDefaults.standard
        let codexAgentEnabled = d.object(forKey: PreferencesKey.Agents.codexEnabled) as? Bool ?? true
        let claudeAgentEnabled = d.object(forKey: PreferencesKey.Agents.claudeEnabled) as? Bool ?? true
        let codexUsageEnabled = d.object(forKey: PreferencesKey.codexUsageEnabled) as? Bool ?? false
        let claudeUsageEnabled = d.object(forKey: PreferencesKey.claudeUsageEnabled) as? Bool ?? false
        let liveSessionsEnabled = d.object(forKey: PreferencesKey.Cockpit.codexActiveSessionsEnabled) as? Bool ?? true
        let codexTrackingEnabled = codexAgentEnabled && codexUsageEnabled
        let claudeTrackingEnabled = claudeAgentEnabled && claudeUsageEnabled
        let anyUsageTrackingEnabled = codexTrackingEnabled || claudeTrackingEnabled
        // The strip shows both providers, so the menu lists every tracked one.
        let source: MenuBarSource = .both

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
            let sessionsVisible = AppWindowRouter.isAgentSessionsWindowVisible
            menu.addItem(makeActionItem(
                title: sessionsVisible ? String(localized: "Hide Agent Sessions", comment: "Menu command that hides the main app window.") : String(localized: "Open Agent Sessions", comment: "Menu command that opens the main app window."),
                action: sessionsVisible ? #selector(hideAgentSessions) : #selector(openAgentSessions)
            ))
        }

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

            if codexTrackingEnabled {
                menu.addItem(makeActionItem(title: String(localized: "Hard Refresh Codex", comment: "Menu command that force-refreshes Codex usage."), action: #selector(refreshCodexHard)))
            }
            if claudeTrackingEnabled {
                menu.addItem(makeActionItem(title: String(localized: "Hard Refresh Claude", comment: "Menu command that force-refreshes Claude usage."), action: #selector(refreshClaudeHard)))
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Always present: the strip's way back to the floating window, whatever is enabled.
        menu.addItem(makeActionItem(
            title: String(localized: "Move to Floating Window", comment: "Menu command that switches the Quota Meter from the menu bar strip to the floating window."),
            action: #selector(moveToFloatingWindow)
        ))
        menu.addItem(makeActionItem(title: String(localized: "Open Settings…", comment: "Menu command that opens Settings."), action: #selector(openQuotaMeterPreferences)))
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
    @objc private func openQuotaMeterPreferences() {
        if let updater = UpdaterController.shared {
            PreferencesWindowController.shared.show(indexer: indexer, updaterController: updater, initialTab: .agentCockpit)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func moveToFloatingWindow() {
        UserDefaults.standard.set(QuotaMeterPlacement.floating.rawValue, forKey: PreferencesKey.quotaMeterPlacement)
    }
    @objc private func openUsagePreferences() {
        if let updater = UpdaterController.shared {
            PreferencesWindowController.shared.show(indexer: indexer, updaterController: updater, initialTab: .usageTracking)
        }
        NSApp.activate(ignoringOtherApps: true)
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
        let alert = NSAlert()
        alert.messageText = String(localized: title)
        if let d = diagnostics as? CodexProbeDiagnostics {
            alert.informativeText = "Exit: \(d.exitCode)\nScript: \(d.scriptPath)\nWORKDIR: \(d.workdir)\n\n— stdout —\n\(d.stdout)\n\n— stderr —\n\(d.stderr)"
        } else if let d = diagnostics as? ClaudeProbeDiagnostics {
            alert.informativeText = "Exit: \(d.exitCode)\nScript: \(d.scriptPath)\nWORKDIR: \(d.workdir)\n\n— stdout —\n\(d.stdout)\n\n— stderr —\n\(d.stderr)"
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK", comment: "Confirmation button in a probe failure alert."))
        // Sheet on a real titled window when one is visible; the strip's borderless panel can
        // be the first window and cannot host a sheet, so fall back to an app-modal alert.
        if let win = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            alert.beginSheetModal(for: win) { _ in }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
