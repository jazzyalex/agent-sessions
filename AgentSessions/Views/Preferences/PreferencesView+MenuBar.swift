import SwiftUI

extension PreferencesView {

    var menuBarTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Menu Bar")
                .font(.title2)
                .fontWeight(.semibold)

            sectionHeader("Menu Bar Item")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show menu bar item", isOn: $menuBarEnabled, help: "Add a menu bar item that shows live session counts and usage details when available")
                Text("The menu bar item shows active and waiting sessions first. Usage controls and reset details appear below when usage tracking is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sectionHeader("Menu Bar Label")
            VStack(alignment: .leading, spacing: 12) {
                toggleRow("Show menu bar icons", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showLiveSessionIcons) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showLiveSessionIcons) }
                ), help: "Show or hide the Active/Waiting session indicators in the menu bar label.")

                toggleRow("Show Codex reset indicators", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showCodexResetTimes) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showCodexResetTimes) }
                ), help: "Show the ↻ reset indicator next to the Codex usage meter when the menu bar label is displaying usage")

                toggleRow("Show Claude reset indicators", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showClaudeResetTimes) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showClaudeResetTimes) }
                ), help: "Show the ↻ reset indicator next to the Claude usage meter when the menu bar label is displaying usage")

                toggleRow("Show pills in menu bar", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: PreferencesKey.MenuBar.showPills) as? Bool ?? false },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.MenuBar.showPills) }
                ), help: "Add pill containers around usage meters. Off by default to keep the menu bar compact.")
            }
            .disabled(!menuBarEnabled)
        }
    }

}
