import SwiftUI
import AppKit

struct UsageMenuBarLabel: View {
    @EnvironmentObject var codexStatus: CodexUsageModel
    @EnvironmentObject var claudeStatus: ClaudeUsageModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("MenuBarScope") private var scopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var styleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("MenuBarSource") private var sourceRaw: String = MenuBarSource.codex.rawValue
    @AppStorage(PreferencesKey.MenuBar.showCodexResetTimes) private var showCodexResetIndicators: Bool = true
    @AppStorage(PreferencesKey.MenuBar.showClaudeResetTimes) private var showClaudeResetIndicators: Bool = true
    @AppStorage(PreferencesKey.MenuBar.showPills) private var showPills: Bool = false
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true

    var body: some View {
        let menuScope = MenuBarScope(rawValue: scopeRaw) ?? .both
        let menuStyle = MenuBarStyleKind(rawValue: styleRaw) ?? .bars
        let desiredSource = MenuBarSource(rawValue: sourceRaw) ?? .codex
        let claudeEnabled = UserDefaults.standard.bool(forKey: "ClaudeUsageEnabled")
        let source: MenuBarSource = {
            if codexAgentEnabled && claudeAgentEnabled { return desiredSource }
            if codexAgentEnabled { return .codex }
            if claudeAgentEnabled { return .claude }
            return desiredSource
        }()

        let quotas: [QuotaData] = {
            var out: [QuotaData] = []
            out.reserveCapacity(2)
            if codexAgentEnabled, source == .codex || source == .both {
                out.append(QuotaData.codex(from: codexStatus))
            }
            if claudeAgentEnabled, claudeEnabled, source == .claude || source == .both {
                out.append(QuotaData.claude(from: claudeStatus))
            }
            return out
        }()

        let scope: CockpitQuotaScope = {
            switch menuScope {
            case .fiveHour: return .fiveHour
            case .weekly: return .week
            case .both: return .both
            }
        }()

        let style: CockpitQuotaStyle = (menuStyle == .numbers) ? .numbers : .bars

        HStack(spacing: 10) {
            ForEach(Array(quotas.enumerated()), id: \.offset) { _, q in
                CockpitQuotaWidget(
                    data: q,
                    isDarkMode: colorScheme == .dark,
                    scope: scope,
                    style: style,
                    modeOverride: nil,
                    baseForeground: .primary,
                    showResetIndicators: (q.provider == .codex) ? showCodexResetIndicators : showClaudeResetIndicators,
                    showPill: showPills
                )
            }
        }
        .frame(height: NSStatusBar.system.thickness)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            codexStatus.setMenuVisible(codexAgentEnabled)
            claudeStatus.setMenuVisible(claudeAgentEnabled)
        }
        .onDisappear {
            codexStatus.setMenuVisible(false)
            claudeStatus.setMenuVisible(false)
        }
    }
}

struct UsageMenuBarMenuContent: View {
    @EnvironmentObject var indexer: SessionIndexer
    @EnvironmentObject var codexStatus: CodexUsageModel
    @EnvironmentObject var claudeStatus: ClaudeUsageModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("MenuBarSource") private var menuBarSourceRaw: String = MenuBarSource.codex.rawValue

    var body: some View {
        let source = MenuBarSource(rawValue: menuBarSourceRaw) ?? .codex

        VStack(alignment: .leading, spacing: 10) {
            // Reset times at the top as enabled buttons so they render as normal menu items.
            // Tapping opens the Usage-related preferences pane.
            if source == .codex || source == .both {
                VStack(alignment: .leading, spacing: 2) {
                    if source == .both {
                        Text("Codex").font(.headline).padding(.bottom, 2)
                    } else {
                        Text("Reset times").font(.body).fontWeight(.semibold).foregroundStyle(.primary).padding(.bottom, 2)
                    }

                    Button(action: { openPreferencesUsage() }) {
                        HStack(spacing: 6) {
                            Text(resetLine(label: "5h:", percent: codexStatus.fiveHourRemainingPercent, reset: displayReset(codexStatus.fiveHourResetText, kind: "5h", source: .codex, lastUpdate: codexStatus.lastUpdate, eventTimestamp: codexStatus.lastEventTimestamp)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: { openPreferencesUsage() }) {
                        HStack(spacing: 6) {
                            Text(resetLine(label: "Wk:", percent: codexStatus.weekRemainingPercent, reset: displayReset(codexStatus.weekResetText, kind: "Wk", source: .codex, lastUpdate: codexStatus.lastUpdate, eventTimestamp: codexStatus.lastEventTimestamp)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    // Last updated time
                    if let lastUpdate = codexStatus.lastUpdate {
                        Text("Updated \(timeAgo(lastUpdate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }

                    // Last-turn usage removed from menu for now
                }
            }

            if source == .both {
                Divider()
            }

            if source == .claude || source == .both {
                VStack(alignment: .leading, spacing: 2) {
                    if source == .both {
                        Text("Claude").font(.headline).padding(.bottom, 2)
                    } else {
                        Text("Reset times").font(.body).fontWeight(.semibold).foregroundStyle(.primary).padding(.bottom, 2)
                    }

                    Button(action: { openPreferencesUsage() }) {
                        HStack(spacing: 6) {
                            Text(resetLine(label: "5h:", percent: claudeStatus.sessionRemainingPercent, reset: displayReset(claudeStatus.sessionResetText, kind: "5h", source: .claude, lastUpdate: claudeStatus.lastUpdate)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: { openPreferencesUsage() }) {
                        HStack(spacing: 6) {
                            Text(resetLine(label: "Wk:", percent: claudeStatus.weekAllModelsRemainingPercent, reset: displayReset(claudeStatus.weekAllModelsResetText, kind: "Wk", source: .claude, lastUpdate: claudeStatus.lastUpdate)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    // Last updated time
                    if let lastUpdate = claudeStatus.lastUpdate {
                        Text("Updated \(timeAgo(lastUpdate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
            }

            Divider()

            // Quick switches as radio-style rows (menu-friendly)
            Text("Source").font(.body).fontWeight(.semibold).foregroundStyle(.primary)
            radioRow(title: MenuBarSource.codex.title, selected: (menuBarSourceRaw == MenuBarSource.codex.rawValue)) {
                menuBarSourceRaw = MenuBarSource.codex.rawValue
            }
            radioRow(title: MenuBarSource.claude.title, selected: (menuBarSourceRaw == MenuBarSource.claude.rawValue)) {
                menuBarSourceRaw = MenuBarSource.claude.rawValue
            }
            radioRow(title: MenuBarSource.both.title, selected: (menuBarSourceRaw == MenuBarSource.both.rawValue)) {
                menuBarSourceRaw = MenuBarSource.both.rawValue
            }

            Text("Style").font(.body).fontWeight(.semibold).foregroundStyle(.primary)
            radioRow(title: MenuBarStyleKind.bars.title, selected: (menuBarStyleRaw == MenuBarStyleKind.bars.rawValue)) {
                menuBarStyleRaw = MenuBarStyleKind.bars.rawValue
            }
            radioRow(title: MenuBarStyleKind.numbers.title, selected: (menuBarStyleRaw == MenuBarStyleKind.numbers.rawValue)) {
                menuBarStyleRaw = MenuBarStyleKind.numbers.rawValue
            }
            Text("Scope").font(.body).fontWeight(.semibold).foregroundStyle(.primary)
            radioRow(title: MenuBarScope.fiveHour.title, selected: (menuBarScopeRaw == MenuBarScope.fiveHour.rawValue)) {
                menuBarScopeRaw = MenuBarScope.fiveHour.rawValue
            }
            radioRow(title: MenuBarScope.weekly.title, selected: (menuBarScopeRaw == MenuBarScope.weekly.rawValue)) {
                menuBarScopeRaw = MenuBarScope.weekly.rawValue
            }
            radioRow(title: MenuBarScope.both.title, selected: (menuBarScopeRaw == MenuBarScope.both.rawValue)) {
                menuBarScopeRaw = MenuBarScope.both.rawValue
            }
            Divider()
            Button("Open Agent Sessions") {
                // Bring main window to front
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "Agent Sessions")
            }
            // Dynamic label: warn when Claude probes will consume tokens
            let refreshLabel: some View = AnyView(Text("Refresh Limits"))
            Button(action: {
                switch source {
                case .codex:
                    codexStatus.refreshNow()
                case .claude:
                    claudeStatus.refreshNow()
                case .both:
                    codexStatus.refreshNow()
                    claudeStatus.refreshNow()
                }
            }) { refreshLabel }
            Toggle("Show in-app usage strip", isOn: $showUsageStrip)
            Divider()
            Button("Open Preferences…") {
                if let updater = UpdaterController.shared {
                    PreferencesWindowController.shared.show(indexer: indexer, updaterController: updater, initialTab: .usageTracking)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 360)
    }

    private func openPreferencesUsage() {
        if let updater = UpdaterController.shared {
            PreferencesWindowController.shared.show(indexer: indexer, updaterController: updater, initialTab: .usageTracking)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct RadioRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                let col: Color = selected ? .accentColor : .secondary
                Image(systemName: selected ? "checkmark" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(col)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private func radioRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    RadioRow(title: title, selected: selected, action: action)
}

// MARK: - Coloring helpers (menu content supports colors)
private func colorFor(percent: Int) -> Color {
    if percent >= 90 { return .red }
    if percent >= 76 { return .yellow }
    return .green
}

private func displayReset(_ text: String, kind: String, source: UsageTrackingSource, lastUpdate: Date?, eventTimestamp: Date? = nil) -> String {
    return formatResetDisplay(kind: kind, source: source, raw: text, lastUpdate: lastUpdate, eventTimestamp: eventTimestamp)
}

private func inlineBar(_ percent: Int, segments: Int = 5) -> String {
    let p = max(0, min(100, percent))
    let filled = min(segments, Int(round(Double(p) / 100.0 * Double(segments))))
    let empty = max(0, segments - filled)
    return String(repeating: "▰", count: filled) + String(repeating: "▱", count: empty)
}

private func resetLine(label: String, percent: Int, reset: String) -> AttributedString {
    var line = AttributedString("")
    var labelAttr = AttributedString(label + " ")
    labelAttr.font = .system(size: 13, weight: .semibold)
    line.append(labelAttr)
    let mode = UsageDisplayMode.current()
    let clampedLeft = max(0, min(100, percent))
    // Bar always shows "used" (filled = used) for consistency
    let percentUsed = mode.barUsedPercent(fromLeft: clampedLeft)
    let displayPercent = mode.numericPercent(fromLeft: clampedLeft)

    var barAttr = AttributedString(inlineBar(percentUsed) + " ")
    barAttr.font = .system(size: 13, weight: .regular, design: .monospaced)
    line.append(barAttr)

    var percentAttr = AttributedString("\(displayPercent)% \(mode.suffix)  ")
    percentAttr.font = .system(size: 13, weight: .regular, design: .monospaced)
    line.append(percentAttr)

    var resetAttr = AttributedString(reset)
    resetAttr.font = .system(size: 13)
    line.append(resetAttr)

    return line
}
