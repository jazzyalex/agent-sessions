import SwiftUI
import AppKit

struct UsageMenuBarLabel: View {
    @EnvironmentObject var status: CodexUsageModel
    @AppStorage("MenuBarScope") private var scopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var styleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("MenuBarColorize") private var colorize: Bool = true

    var body: some View {
        let scope = MenuBarScope(rawValue: scopeRaw) ?? .both
        let style = MenuBarStyleKind(rawValue: styleRaw) ?? .bars
        let (text, color) = render(scope: scope, style: style)
        Text(text)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundColor(colorize ? color : .primary)
            .padding(.horizontal, 4)
    }

    private func render(scope: MenuBarScope, style: MenuBarStyleKind) -> (String, Color) {
        let five = status.fiveHourPercent
        let week = status.weekPercent
        let sevFive = severity(for: five)
        let sevWeek = severity(for: week)
        let maxColor = maxSeverityColor(sevFive, sevWeek, considering: scope)
        switch style {
        case .bars:
            let p5 = segmentBar(for: five)
            let pw = segmentBar(for: week)
            switch scope {
            case .fiveHour:
                return ("5h \(p5) \(five)%", colorFromSeverity(maxColor))
            case .weekly:
                return ("Wk \(pw) \(week)%", colorFromSeverity(maxColor))
            case .both:
                return ("5h \(p5) \(five)% | Wk \(pw) \(week)%", colorFromSeverity(maxColor))
            }
        case .numbers:
            switch scope {
            case .fiveHour:
                return ("5h \(five)%", colorFromSeverity(maxColor))
            case .weekly:
                return ("W \(week)%", colorFromSeverity(maxColor))
            case .both:
                return ("5h \(five)% | W \(week)%", colorFromSeverity(maxColor))
            }
        }
    }

    private func segmentBar(for percent: Int, segments: Int = 5) -> String {
        let p = max(0, min(100, percent))
        let filled = min(segments, Int(round(Double(p) / 100.0 * Double(segments))))
        let empty = max(0, segments - filled)
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: empty)
    }

    private enum Severity: Int { case low = 0, warn = 1, high = 2 }
    private func severity(for percent: Int) -> Severity {
        if percent >= 90 { return .high }
        if percent >= 75 { return .warn }
        return .low
    }
    private func maxSeverityColor(_ a: Severity, _ b: Severity, considering scope: MenuBarScope) -> Severity {
        switch scope {
        case .fiveHour: return a
        case .weekly: return b
        case .both: return (a.rawValue >= b.rawValue) ? a : b
        }
    }
    private func colorFromSeverity(_ s: Severity) -> Color {
        switch s {
        case .low: return .green
        case .warn: return .yellow
        case .high: return .red
        }
    }
}

struct UsageMenuBarMenuContent: View {
    @EnvironmentObject var status: CodexUsageModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ShowUsageStrip") private var showUsageStrip: Bool = false
    @AppStorage("MenuBarScope") private var menuBarScopeRaw: String = MenuBarScope.both.rawValue
    @AppStorage("MenuBarStyle") private var menuBarStyleRaw: String = MenuBarStyleKind.bars.rawValue
    @AppStorage("MenuBarColorize") private var menuBarColorize: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Quick switches
            Group {
                Text("Style").font(.caption).foregroundStyle(.secondary)
                Picker("Style", selection: $menuBarStyleRaw) {
                    ForEach(MenuBarStyleKind.allCases) { k in
                        Text(k.title).tag(k.rawValue)
                    }
                }.pickerStyle(.segmented)
                Text("Scope").font(.caption).foregroundStyle(.secondary)
                Picker("Scope", selection: $menuBarScopeRaw) {
                    ForEach(MenuBarScope.allCases) { s in
                        Text(s.title).tag(s.rawValue)
                    }
                }.pickerStyle(.segmented)
                Toggle("Colorize", isOn: $menuBarColorize)
            }
            Divider()
            if let line = status.usageLine, !line.isEmpty {
                Text(line).font(.caption)
            }
            HStack {
                Text("5h:")
                Text("\(status.fiveHourPercent)%").monospacedDigit()
                Spacer()
                Text(status.fiveHourResetText.isEmpty ? "—" : status.fiveHourResetText)
            }
            HStack {
                Text("Wk:")
                Text("\(status.weekPercent)%").monospacedDigit()
                Spacer()
                Text(status.weekResetText.isEmpty ? "—" : status.weekResetText)
            }
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
