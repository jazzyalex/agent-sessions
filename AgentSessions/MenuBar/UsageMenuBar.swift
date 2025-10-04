import SwiftUI
import AppKit

struct UsageMenuBarLabel: View {
    @EnvironmentObject var codexStatus: CodexUsageModel
    @EnvironmentObject var claudeStatus: ClaudeUsageModel
    @AppStorage("MenuBarScope") private var scopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var styleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("MenuBarSource") private var sourceRaw: String = MenuBarSource.codex.rawValue
    // Colorization is currently disabled (see TODO below)

    var body: some View {
        let scope = MenuBarScope(rawValue: scopeRaw) ?? .both
        let style = MenuBarStyleKind(rawValue: styleRaw) ?? .bars
        let source = MenuBarSource(rawValue: sourceRaw) ?? .codex
        let claudeEnabled = UserDefaults.standard.bool(forKey: "ShowClaudeUsageStrip")

        return HStack(spacing: 8) {
            switch source {
            case .codex:
                renderSourceView(five: codexStatus.fiveHourPercent, week: codexStatus.weekPercent, scope: scope, style: style, prefixIconName: "MenuIconCodex", fallbackPrefix: nil)
            case .claude:
                if claudeEnabled {
                    renderSourceView(five: claudeStatus.sessionPercent, week: claudeStatus.weekAllModelsPercent, scope: scope, style: style, prefixIconName: "MenuIconClaude", fallbackPrefix: nil)
                }
            case .both:
                renderSourceView(five: codexStatus.fiveHourPercent, week: codexStatus.weekPercent, scope: scope, style: style, prefixIconName: "MenuIconCodex", fallbackPrefix: nil)
                if claudeEnabled {
                    Text("│").foregroundStyle(.secondary)
                    renderSourceView(five: claudeStatus.sessionPercent, week: claudeStatus.weekAllModelsPercent, scope: scope, style: style, prefixIconName: "MenuIconClaude", fallbackPrefix: nil)
                }
            }
        }
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .padding(.horizontal, 4)
            .fixedSize(horizontal: true, vertical: false)
            .onAppear {
                codexStatus.setMenuVisible(true)
                claudeStatus.setMenuVisible(true)
            }
            .onDisappear {
                codexStatus.setMenuVisible(false)
                claudeStatus.setMenuVisible(false)
            }
    }

    // Create a single template image containing both icons side-by-side (12pt each, 2pt gap)
    private func compositeIcon() -> NSImage? {
        guard let a = NSImage(named: "MenuIconCodex"), let b = NSImage(named: "MenuIconClaude") else { return nil }
        let gap: CGFloat = 2
        let side: CGFloat = 12
        let size = NSSize(width: side * 2 + gap, height: side)
        let img = NSImage(size: size)
        img.lockFocus()
        a.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        b.draw(in: NSRect(x: side + gap, y: 0, width: side, height: side))
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func renderSource(five: Int, week: Int, scope: MenuBarScope, style: MenuBarStyleKind, prefix: String?) -> Text {
        let fiveColor: Color = .primary
        let weekColor: Color = .primary

        let prefixText = prefix.map { Text("\($0) ") } ?? Text("")

        switch style {
        case .bars:
            let p5 = segmentBar(for: five)
            let pw = segmentBar(for: week)
            let left = Text("5h ").foregroundColor(fiveColor)
                + Text(p5).foregroundColor(fiveColor)
                + Text(" \(five)%").foregroundColor(fiveColor)
            let right = Text("Wk ").foregroundColor(weekColor)
                + Text(pw).foregroundColor(weekColor)
                + Text(" \(week)%").foregroundColor(weekColor)
            switch scope {
            case .fiveHour: return prefixText + left
            case .weekly: return prefixText + right
            case .both: return prefixText + left + Text("  ") + right
            }
        case .numbers:
            let left = Text("5h \(five)%").foregroundColor(fiveColor)
            let right = Text("Wk \(week)%").foregroundColor(weekColor)
            switch scope {
            case .fiveHour: return prefixText + left
            case .weekly: return prefixText + right
            case .both: return prefixText + left + Text("  ") + right
            }
        }
    }

    // Same as renderSource but returns a View with optional image prefix.
    @ViewBuilder
    private func renderSourceView(five: Int, week: Int, scope: MenuBarScope, style: MenuBarStyleKind, prefixIconName: String, fallbackPrefix: String?) -> some View {
        HStack(spacing: 6) {
            if let img = NSImage(named: prefixIconName) {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 4)
            } else if let fallback = fallbackPrefix {
                Text("\(fallback) ")
            }
            renderSource(five: five, week: week, scope: scope, style: style, prefix: nil)
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
                            Text(resetLine(label: "5h:", percent: codexStatus.fiveHourPercent, reset: displayReset(codexStatus.fiveHourResetText)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: { openPreferencesUsage() }) {
                        HStack(spacing: 6) {
                            Text(resetLine(label: "Wk:", percent: codexStatus.weekPercent, reset: displayReset(codexStatus.weekResetText)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
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
                            Text(resetLine(label: "5h:", percent: claudeStatus.sessionPercent, reset: displayReset(claudeStatus.sessionResetText)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: { openPreferencesUsage() }) {
                        HStack(spacing: 6) {
                            Text(resetLine(label: "Wk:", percent: claudeStatus.weekAllModelsPercent, reset: displayReset(claudeStatus.weekAllModelsResetText)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
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
            Button("Refresh Limits") {
                switch source {
                case .codex:
                    codexStatus.refreshNow()
                case .claude:
                    claudeStatus.refreshNow()
                case .both:
                    codexStatus.refreshNow()
                    claudeStatus.refreshNow()
                }
            }
            Toggle("Show in-app usage strip", isOn: $showUsageStrip)
            Divider()
            Button("Open Preferences…") { PreferencesWindowController.shared.show(indexer: indexer, initialTab: .menuBar) }
        }
        .padding(8)
        .frame(minWidth: 360)
    }

    private func openPreferencesUsage() {
        PreferencesWindowController.shared.show(indexer: indexer, initialTab: .menuBar)
        NSApp.activate(ignoringOtherApps: true)
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

private func displayReset(_ text: String) -> String {
    guard !text.isEmpty else { return "—" }
    var result = text
    if result.hasPrefix("resets ") {
        result = String(result.dropFirst("resets ".count))
    }
    // Strip timezone like "(America/Los_Angeles)"
    if let parenIndex = result.firstIndex(of: "(") {
        result = String(result[..<parenIndex]).trimmingCharacters(in: .whitespaces)
    }
    return result
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

    var barAttr = AttributedString(inlineBar(percent) + " ")
    barAttr.font = .system(size: 13, weight: .regular, design: .monospaced)
    line.append(barAttr)

    var percentAttr = AttributedString("\(percent)%  ")
    percentAttr.font = .system(size: 13, weight: .regular, design: .monospaced)
    line.append(percentAttr)

    var resetAttr = AttributedString(reset)
    resetAttr.font = .system(size: 13)
    line.append(resetAttr)

    return line
}
