import SwiftUI

/// Displays the historical git context from when the session was created
struct HistoricalSection: View {
    let context: HistoricalGitContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section header
            HStack(spacing: 8) {
                Text("SNAPSHOT AT SESSION START")
                    .font(.system(size: 13, weight: .bold))
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundColor(.secondary)

                Spacer()

                Text(context.relativeTimeDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            // Content box
            VStack(alignment: .leading, spacing: 12) {
                // Branch
                InfoRow(label: "Branch", value: context.branch ?? "—")

                // Commit
                if let commitHash = context.commitHash {
                    InfoRow(
                        label: "Commit",
                        value: "\(context.shortCommitHash ?? commitHash.prefix(7).description) \"\(context.sessionCreated.formatted(.relative(presentation: .numeric)))\""
                    )
                }

                // Working Tree Status
                if let clean = context.wasClean {
                    InfoRow(label: "Working Tree", value: clean ? "Clean" : "Had uncommitted changes")
                        .foregroundStyle(clean ? .green : .orange)
                } else {
                    HStack(alignment: .top) {
                        Text("Working Tree:")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)

                        HStack(spacing: 8) {
                            Text("Not captured")
                                .font(.system(size: 13, weight: .medium))
                            Text("Unknown at start")
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(hex: "#8e8e9315"))
                                .foregroundStyle(Color(hex: "#6e6e73"))
                                .cornerRadius(6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
    HistoricalSection(context: HistoricalGitContext(
        branch: "feature/perf-improvements",
        commitHash: "2f8a9c1d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b",
        wasClean: true,
        cwd: "/Users/alexm/Repository/Codex-History",
        sessionCreated: Date().addingTimeInterval(-7200) // 2 hours ago
    ))
    .padding()
    .frame(width: 600)
}
