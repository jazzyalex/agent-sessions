import SwiftUI
import AppKit

extension PreferencesView {

    var aboutTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("About")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let appIcon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 16, height: 16)
                            .cornerRadius(3)
                    }
                    Text("Agent Sessions")
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                Divider()
            }
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

                HStack(spacing: 12) {
                    Toggle("Auto-Update", isOn: Binding(
                        get: { updaterController.autoUpdateEnabled },
                        set: { updaterController.autoUpdateEnabled = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .help("Automatically download and install app updates")
                    .disabled(updaterController.updater == nil)

                    Button("Check for Updates...") {
                        updaterController.checkForUpdates(nil)
                    }
                    .buttonStyle(.bordered)
                    .help("Check for new versions and install updates")
                }
            }

            sectionHeader("Diagnostics")
            VStack(alignment: .leading, spacing: 12) {
                Text("Crash reports are collected locally. Use the email link below to open a pre-filled report email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                labeledRow("Email:") {
                    Button("jazzyalex@gmail.com") {
                        sendPendingCrashReports()
                    }
                    .buttonStyle(.link)
                    .help("Open a pre-filled email draft with the latest crash report in the message body.")
                }

                labeledRow("Pending reports:") {
                    Text("\(crashPendingCount)")
                        .font(.system(.body, design: .monospaced))
                }

                labeledRow("Last detected:") {
                    if let date = crashLastDetectedAt {
                        Text(AppDateFormatting.dateTimeMedium(date))
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                }

                labeledRow("Last email draft:") {
                    if let date = crashLastSendAt {
                        Text(AppDateFormatting.dateTimeMedium(date))
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }

                if let sendError = crashLastSendError, !sendError.isEmpty {
                    PreferenceCallout(
                        iconName: "exclamationmark.triangle.fill",
                        tint: .orange
                    ) {
                        Text(sendError)
                            .font(.caption)
                    }
                }

                HStack(spacing: 12) {
                    Button(isCrashSendRunning ? "Preparing..." : "Email Crash Report") {
                        sendPendingCrashReports()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCrashSendRunning || crashPendingCount == 0)
                    .help("Open the default email app with a pre-filled crash report draft.")

                    Button("Export Report") {
                        exportLatestCrashReport()
                    }
                    .buttonStyle(.bordered)
                    .disabled(crashPendingCount == 0)
                    .help("Export the most recent queued crash report as JSON.")

                    Button("Clear Pending") {
                        showCrashClearConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(crashPendingCount == 0)
                    .help("Delete all queued crash reports from local storage.")
                }

            }

            Spacer()
        }
        .onAppear {
            refreshCrashDiagnosticsState()
        }
        .alert("Crash Reports", isPresented: $showCrashSendResult) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(crashSendResultMessage)
        }
        .alert("Clear Pending Crash Reports?", isPresented: $showCrashClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearPendingCrashReports()
            }
        } message: {
            Text("This removes all queued crash reports from local storage.")
        }
        .alert("Export Failed", isPresented: $showCrashExportError) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(crashExportErrorMessage)
        }
    }

}
