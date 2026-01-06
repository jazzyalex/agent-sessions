import SwiftUI

extension PreferencesView {

    var menuBarTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Menu Bar")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Menu Bar Usage")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show menu bar usage", isOn: $menuBarEnabled, help: "Add a menu bar item that displays usage meters")
            }

            sectionHeader("Menu Bar Label")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show Codex reset indicators", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showCodexResetTimes) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showCodexResetTimes) }
                ), help: "Show the ↻ reset indicator next to the Codex meter in the menu bar label")

                toggleRow("Show Claude reset indicators", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showClaudeResetTimes) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showClaudeResetTimes) }
                ), help: "Show the ↻ reset indicator next to the Claude meter in the menu bar label")

                toggleRow("Show pills in menu bar", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showPills) as? Bool ?? false },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showPills) }
                ), help: "Add pill containers around meters. Off by default to keep the menu bar compact.")
            }
            .disabled(!menuBarEnabled)
        }
    }

}
