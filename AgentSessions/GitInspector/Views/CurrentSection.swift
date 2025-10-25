import SwiftUI

/// Displays the current live git status
struct CurrentSection: View {
    let status: CurrentGitStatus
    let onRefresh: () async -> Void

    @State private var isRefreshing = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section header
            HStack(spacing: 8) {
                Text("🔴")
                    .font(.system(size: 18))
                Text("CURRENT STATE")
                    .font(.system(size: 13, weight: .bold))
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundColor(.secondary)

                Spacer()

                // Last refreshed indicator
                if status.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Status may be stale, consider refreshing")
                }

                Text("Last checked: \(status.relativeTimeDescription)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            // Content box
            VStack(alignment: .leading, spacing: 12) {
                // Branch (with comparison indicator)
                HStack {
                    InfoRow(label: "Branch", value: status.branch ?? "—")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Same")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }

                // Commit (with comparison indicator)
                HStack {
                    InfoRow(label: "Commit", value: status.shortCommitHash ?? "—")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("No new")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }

                // Working Tree Status
                if status.isDirty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            InfoRow(label: "Working Tree", value: status.statusDescription)
                                .foregroundStyle(.orange)
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Changed")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                        }

                        // List dirty files (scrollable)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(status.dirtyFiles) { file in
                                    HStack(spacing: 6) {
                                        Text(file.icon)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(colorForChange(file.changeType))
                                            .frame(width: 16)

                                        Text(file.path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.leading, 108)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                } else {
                    InfoRow(label: "Working Tree", value: "Clean")
                        .foregroundStyle(.green)
                }

                // Tracking status
                if let tracking = status.trackingDescription {
                    InfoRow(label: "Remote Tracking", value: tracking)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark ? Color(hex: "#1c1c1e") : Color(hex: "#f9f9f9"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(colorScheme == .dark ? Color(hex: "#38383a") : Color(hex: "#e5e5e7"), lineWidth: 1)
                    )
            )
        }
    }

    private func colorForChange(_ type: FileChangeType) -> Color {
        switch type.displayColor {
        case "orange": return .orange
        case "green": return .green
        case "red": return .red
        case "blue": return .blue
        case "gray": return .gray
        default: return .primary
        }
    }
}

/// Reusable info row component
private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    CurrentSection(
        status: CurrentGitStatus(
            branch: "feature/perf-improvements",
            commitHash: "2f8a9c1",
            isDirty: true,
            dirtyFiles: [
                GitFileStatus(path: "Sources/Session/SessionIndexer.swift", changeType: .modified),
                GitFileStatus(path: "Sources/Models/Session.swift", changeType: .modified),
                GitFileStatus(path: "Tests/SessionTests.swift", changeType: .added)
            ],
            lastCommitMessage: "feat: improve indexing",
            queriedAt: Date().addingTimeInterval(-120) // 2 minutes ago
        ),
        onRefresh: {}
    )
    .padding()
    .frame(width: 600)
}
