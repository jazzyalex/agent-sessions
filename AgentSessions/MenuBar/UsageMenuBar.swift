import SwiftUI
import AppKit

struct UsageMenuBarLabel: View {
    @EnvironmentObject var status: CodexUsageModel
    @AppStorage("MenuBarScope") private var scopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var styleRaw: String = MenuBarStyleKind.bars.rawValue
    // Colorization is currently disabled (see TODO below)

    var body: some View {
        let scope = MenuBarScope(rawValue: scopeRaw) ?? .both
        let style = MenuBarStyleKind(rawValue: styleRaw) ?? .bars
        let five = status.fiveHourPercent
        let week = status.weekPercent
        // Colorization disabled: render with default color
        let fiveColor: Color = .primary
        let weekColor: Color = .primary

        let text: Text = {
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
                case .fiveHour: return left
                case .weekly: return right
                case .both: return left + Text("  ") + right
                }
            case .numbers:
                let left = Text("5h \(five)%").foregroundColor(fiveColor)
                let right = Text("Wk \(week)%").foregroundColor(weekColor)
                switch scope {
                case .fiveHour: return left
                case .weekly: return right
                case .both: return left + Text("  ") + right
                }
            }
        }()

        return text
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .padding(.horizontal, 4)
            .onAppear { status.setMenuVisible(true) }
            .onDisappear { status.setMenuVisible(false) }
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
    @EnvironmentObject var status: CodexUsageModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Quick switches as radio-style rows (menu-friendly)
            Text("Style").font(.caption).foregroundStyle(.secondary)
            radioRow(title: MenuBarStyleKind.bars.title, selected: (menuBarStyleRaw == MenuBarStyleKind.bars.rawValue)) {
                menuBarStyleRaw = MenuBarStyleKind.bars.rawValue
            }
            radioRow(title: MenuBarStyleKind.numbers.title, selected: (menuBarStyleRaw == MenuBarStyleKind.numbers.rawValue)) {
                menuBarStyleRaw = MenuBarStyleKind.numbers.rawValue
            }
            Text("Scope").font(.caption).foregroundStyle(.secondary)
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
            if let line = status.usageLine, !line.isEmpty {
                Text(line).font(.caption).foregroundStyle(.primary)
            }
            HStack {
                Text("5h:")
                Text("\(status.fiveHourPercent)%").monospacedDigit()
                Spacer()
                Text(status.fiveHourResetText.isEmpty ? "—" : status.fiveHourResetText)
            }.foregroundStyle(.primary)
            HStack {
                Text("Wk:")
                Text("\(status.weekPercent)%").monospacedDigit()
                Spacer()
                Text(status.weekResetText.isEmpty ? "—" : status.weekResetText)
            }.foregroundStyle(.primary)
            Divider()
            Button("Open Agent Sessions") {
                // Bring main window to front
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "Agent Sessions")
            }
            Button("Refresh Limits") { status.refreshNow() }
            Toggle("Show in-app usage strip", isOn: $showUsageStrip)
            Divider()
            Button("Open Preferences…") { PreferencesWindowController.shared.show(indexer: SessionIndexer()) }
        }
        .padding(8)
        .frame(minWidth: 280)
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
