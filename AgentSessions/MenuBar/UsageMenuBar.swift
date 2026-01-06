import SwiftUI
import AppKit

struct UsageMenuBarLabel: View {
    @EnvironmentObject var codexStatus: CodexUsageModel
    @EnvironmentObject var claudeStatus: ClaudeUsageModel
    @AppStorage("MenuBarScope") private var scopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var styleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("MenuBarSource") private var sourceRaw: String = MenuBarSource.codex.rawValue
    @AppStorage(PreferencesKey.Agents.codexEnabled) private var codexAgentEnabled: Bool = true
    @AppStorage(PreferencesKey.Agents.claudeEnabled) private var claudeAgentEnabled: Bool = true

    private let itemFont: Font = .system(size: 12, weight: .medium, design: .monospaced)
    private let itemHeight: CGFloat = NSStatusBar.system.thickness

    var body: some View {
        let scope = MenuBarScope(rawValue: scopeRaw) ?? .both
        let style = MenuBarStyleKind(rawValue: styleRaw) ?? .bars
        let desiredSource = MenuBarSource(rawValue: sourceRaw) ?? .codex
        let claudeEnabled = UserDefaults.standard.bool(forKey: "ClaudeUsageEnabled")
        let source: MenuBarSource = {
            if codexAgentEnabled && claudeAgentEnabled { return desiredSource }
            if codexAgentEnabled { return .codex }
            if claudeAgentEnabled { return .claude }
            return desiredSource
        }()

        HStack(spacing: 12) {
            switch source {
            case .codex:
                if codexAgentEnabled {
                    providerItem(
                        iconName: "MenuIconCodex",
                        iconTint: .blue,
                        five: codexStatus.fiveHourRemainingPercent,
                        week: codexStatus.weekRemainingPercent,
                        scope: scope,
                        style: style,
                        showSpinner: codexStatus.isUpdating
                    )
                }
            case .claude:
                if claudeAgentEnabled && claudeEnabled {
                    providerItem(
                        iconName: "MenuIconClaude",
                        iconTint: .orange,
                        five: claudeStatus.sessionRemainingPercent,
                        week: claudeStatus.weekAllModelsRemainingPercent,
                        scope: scope,
                        style: style,
                        showSpinner: claudeStatus.isUpdating
                    )
                }
            case .both:
                if codexAgentEnabled {
                    providerItem(
                        iconName: "MenuIconCodex",
                        iconTint: .blue,
                        five: codexStatus.fiveHourRemainingPercent,
                        week: codexStatus.weekRemainingPercent,
                        scope: scope,
                        style: style,
                        showSpinner: codexStatus.isUpdating
                    )
                }
                if codexAgentEnabled && claudeAgentEnabled && claudeEnabled {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.6))
                        .frame(width: 1, height: 12)
                    providerItem(
                        iconName: "MenuIconClaude",
                        iconTint: .orange,
                        five: claudeStatus.sessionRemainingPercent,
                        week: claudeStatus.weekAllModelsRemainingPercent,
                        scope: scope,
                        style: style,
                        showSpinner: claudeStatus.isUpdating
                    )
                }
            }
        }
        .font(itemFont)
        .frame(height: itemHeight)
        .padding(.horizontal, 6)
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

    @ViewBuilder
    private func providerItem(iconName: String, iconTint: Color, five: Int, week: Int, scope: MenuBarScope, style: MenuBarStyleKind, showSpinner: Bool) -> some View {
        HStack(spacing: 4) {
            Image(iconName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundStyle(iconTint)
            renderUsage(five: five, week: week, scope: scope, style: style)
            if showSpinner {
                SpinningIcon()
            }
        }
    }

    private struct SpinningIcon: View {
        @State private var rotate = false
        var body: some View {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .regular))
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: rotate)
                .onAppear { rotate = true }
        }
    }

    private func renderUsage(five: Int, week: Int, scope: MenuBarScope, style: MenuBarStyleKind) -> Text {
        let fiveColor: Color = .primary
        let weekColor: Color = .primary

        let mode = UsageDisplayMode.current()
        let leftFive = max(0, min(100, five))
        let leftWeek = max(0, min(100, week))
        let barFive = mode.barUsedPercent(fromLeft: leftFive)
        let barWeek = mode.barUsedPercent(fromLeft: leftWeek)
        let displayFive = mode.numericPercent(fromLeft: leftFive)
        let displayWeek = mode.numericPercent(fromLeft: leftWeek)

        switch style {
        case .bars:
            let p5 = segmentBar(for: barFive)
            let pw = segmentBar(for: barWeek)
            let left = Text("5h ").foregroundColor(fiveColor)
                + Text(p5).foregroundColor(fiveColor)
                + Text(" \(displayFive)%").foregroundColor(fiveColor)
            let right = Text("Wk ").foregroundColor(weekColor)
                + Text(pw).foregroundColor(weekColor)
                + Text(" \(displayWeek)%").foregroundColor(weekColor)
            switch scope {
            case .fiveHour: return left
            case .weekly: return right
            case .both: return left + Text("  ") + right
            }
        case .numbers:
            let left = Text("5h \(displayFive)%").foregroundColor(fiveColor)
            let right = Text("Wk \(displayWeek)%").foregroundColor(weekColor)
            switch scope {
            case .fiveHour: return left
            case .weekly: return right
            case .both: return left + Text("  ") + right
            }
        }
    }

    private func segmentBar(for percent: Int, segments: Int = 5) -> String {
        let p = max(0, min(100, percent))
        let filled = min(segments, Int(round(Double(p) / 100.0 * Double(segments))))
        let empty = max(0, segments - filled)
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: empty)
    }

    // TODO(Colorize): MenuBarExtra renders labels as template content, dropping custom colors.
    // Proposal: implement a small NSStatusItem controller that sets a non-template attributedTitle
    // with per-metric colors (green 0–74%, yellow 75–89%, red 90–100%), while keeping the SwiftUI
    // menu content via NSHostingView embedded in an NSMenu. Then re-introduce a Preferences toggle.
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
