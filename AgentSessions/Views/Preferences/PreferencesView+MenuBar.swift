import SwiftUI

extension PreferencesView {

    var menuBarTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Menu Bar")
                .font(.title2)
                .fontWeight(.semibold)

            // Status item settings (no extra section header per request)
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show menu bar usage", isOn: $menuBarEnabled, help: "Add a menu bar item that displays usage meters")

                labeledRow("Source") {
                    Picker("", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: PreferencesKey.MenuBar.source) ?? MenuBarSource.codex.rawValue },
                        set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.source) }
                    )) {
                        ForEach(MenuBarSource.allCases) { s in
                            Text(s.title).tag(s.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!menuBarEnabled)
                    .frame(maxWidth: 360)
                    .help("Choose which agent usage the menu bar item displays")
                    .accessibilityLabel(Text("Menu bar source"))
                }

                labeledRow("Scope") {
                    Picker("", selection: $menuBarScopeRaw) {
                        ForEach(MenuBarScope.allCases) { s in
                            Text(s.title).tag(s.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!menuBarEnabled)
                    .frame(maxWidth: 360)
                    .help("Select whether the menu bar shows 5-hour, weekly, or both usage windows")
                    .accessibilityLabel(Text("Menu bar scope"))
                }

                labeledRow("Style") {
                    Picker("", selection: $menuBarStyleRaw) {
                        ForEach(MenuBarStyleKind.allCases) { k in
                            Text(k.title).tag(k.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!menuBarEnabled)
                    .frame(maxWidth: 360)
                    .help("Switch between bar graphs and numeric usage in the menu bar")
                    .accessibilityLabel(Text("Menu bar style"))
                }

                labeledRow("Label") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show Codex reset indicators", isOn: Binding(
                            get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showCodexResetTimes) as? Bool ?? true },
                            set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showCodexResetTimes) }
                        ))
                        .toggleStyle(.switch)
                        .disabled(!menuBarEnabled)

                        Toggle("Show Claude reset indicators", isOn: Binding(
                            get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showClaudeResetTimes) as? Bool ?? true },
                            set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showClaudeResetTimes) }
                        ))
                        .toggleStyle(.switch)
                        .disabled(!menuBarEnabled)

                        Toggle("Show pills in menu bar", isOn: Binding(
                            get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showPills) as? Bool ?? false },
                            set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showPills) }
                        ))
                        .toggleStyle(.switch)
                        .disabled(!menuBarEnabled)
                        .help("Adds the pill containers used in the cockpit footer. Off by default to keep the menu bar compact.")
                    }
                }

                Text("Source: Codex, Claude, or Both. Style: Bars or numbers. Scope: 5h, weekly, or both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

}
