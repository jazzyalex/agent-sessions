import SwiftUI

/// Displays the historical git context from when the session was created
struct HistoricalSection: View {
    let context: HistoricalGitContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.blue)
                Text("SNAPSHOT AT SESSION START")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            // Content box (source indicator)
            VStack(alignment: .leading, spacing: 12) {
                Text("Source: Session file snapshot")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

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
                InfoRow(label: "Working Tree", value: context.statusDescription)
                    .foregroundStyle(context.wasClean == true ? .green : .orange)

                // (Optional) Additional fields can be populated in future (e.g., behind/ahead at start)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
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
