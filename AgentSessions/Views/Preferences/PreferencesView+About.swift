import SwiftUI
import AppKit

extension PreferencesView {

    var aboutTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("About")
                .font(.title2)
                .fontWeight(.semibold)

            // App Icon
            HStack {
                Spacer()
                if let appIcon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 85, height: 85)
                        .cornerRadius(11)
                        .shadow(radius: 3)
                }
                Spacer()
            }
            .padding(.vertical, 8)

            sectionHeader("Agent Sessions")
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Version:") {
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text(version)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }

                labeledRow("Security & Privacy:") {
                    Button("Security & Privacy") {
                        UpdateCheckModel.shared.openURL("https://github.com/jazzyalex/agent-sessions/blob/main/docs/security.md")
                    }
                    .buttonStyle(.link)
                }

                labeledRow("License:") {
                    Button("MIT License") {
                        UpdateCheckModel.shared.openURL("https://github.com/jazzyalex/agent-sessions/blob/main/LICENSE")
                    }
                    .buttonStyle(.link)
                }

                labeledRow("Website:") {
                    Button("jazzyalex.github.io/agent-sessions") {
                        UpdateCheckModel.shared.openURL("https://jazzyalex.github.io/agent-sessions/")
                    }
                    .buttonStyle(.link)
                }

                labeledRow("GitHub:") {
                    Button("github.com/jazzyalex/agent-sessions") {
                        UpdateCheckModel.shared.openURL("https://github.com/jazzyalex/agent-sessions")
                    }
                    .buttonStyle(.link)
                }

                labeledRow("X (Twitter):") {
                    Button("@jazzyalex") {
                        UpdateCheckModel.shared.openURL("https://x.com/jazzyalex")
                    }
                    .buttonStyle(.link)
                }
            }

            sectionHeader("Updates")
            VStack(alignment: .leading, spacing: 12) {
                if updaterController.hasGentleReminder {
                    PreferenceCallout(
                        iconName: "exclamationmark.circle.fill",
                        tint: .blue,
                        backgroundColor: Color.blue.opacity(0.12)
                    ) {
                        Text("An update is available")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }

                Button("Check for Updates...") {
                    updaterController.checkForUpdates(nil)
                }
                .buttonStyle(.bordered)
                .help("Check for new versions and install updates")
            }

            Spacer()
        }
    }

}
