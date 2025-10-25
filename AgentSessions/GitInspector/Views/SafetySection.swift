import SwiftUI

/// Displays the safety check results and recommendations
struct SafetySection: View {
    let check: GitSafetyCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.yellow)
                Text("RESUME SAFETY CHECK")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            // Content box with status-specific styling
            VStack(alignment: .leading, spacing: 16) {
                // Status banner
                HStack(spacing: 12) {
                    Image(systemName: check.status.icon)
                        .font(.system(size: 24))
                        .foregroundStyle(colorForStatus(check.status))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(check.status.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(colorForStatus(check.status))

                        if !check.isSafeToResume {
                            Text("\(check.failedCheckCount) issue\(check.failedCheckCount == 1 ? "" : "s") detected")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.bottom, 8)

                // Individual checks
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(check.checks) { checkResult in
                        HStack(alignment: .top, spacing: 8) {
                            Text(checkResult.icon)
                                .font(.system(size: 13))
                                .frame(width: 20)

                            Text(checkResult.message)
                                .font(.system(size: 13))
                                .foregroundStyle(checkResult.passed ? .primary : .secondary)
                        }
                    }
                }

                Divider()

                // Recommendation
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 13))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("RECOMMENDATION")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)

                        Text(check.recommendation)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColorForStatus(check.status))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(colorForStatus(check.status).opacity(0.3), lineWidth: 2)
                    )
            )
        }
    }

    private func colorForStatus(_ status: GitSafetyCheck.SafetyStatus) -> Color {
        switch status {
        case .safe: return .green
        case .caution: return .orange
        case .warning: return .red
        case .unknown: return .gray
        }
    }

    private func backgroundColorForStatus(_ status: GitSafetyCheck.SafetyStatus) -> Color {
        switch status {
        case .safe: return Color.green.opacity(0.05)
        case .caution: return Color.orange.opacity(0.05)
        case .warning: return Color.red.opacity(0.05)
        case .unknown: return Color.gray.opacity(0.05)
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        // Caution state
        SafetySection(check: GitSafetyCheck(
            status: .caution,
            checks: [
                .init(icon: "✓", message: "Branch unchanged (still on feature/perf-improvements)", passed: true),
                .init(icon: "✓", message: "No new commits locally", passed: true),
                .init(icon: "⚠️", message: "3 uncommitted changes detected in working tree", passed: false)
            ],
            recommendation: "Review uncommitted changes before resuming. The agent may conflict with your work. Consider committing or stashing changes first."
        ))

        // Safe state
        SafetySection(check: GitSafetyCheck(
            status: .safe,
            checks: [
                .init(icon: "✓", message: "Branch unchanged", passed: true),
                .init(icon: "✓", message: "No new commits", passed: true),
                .init(icon: "✓", message: "Working tree clean", passed: true)
            ],
            recommendation: "Safe to resume - no changes detected"
        ))
    }
    .padding()
    .frame(width: 600)
}
