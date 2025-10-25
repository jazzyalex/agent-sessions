import SwiftUI

/// Hero section displaying the safety check status prominently
/// This is the primary focus of the Git Inspector - answering "Can I resume safely?"
struct StatusHeroSection: View {
    let check: GitSafetyCheck
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header with icon and title
            HStack(spacing: 16) {
                Text(check.status.iconEmoji)
                    .font(.system(size: 42))

                VStack(alignment: .leading, spacing: 8) {
                    // Badge
                    Text(check.status.badgeText)
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(badgeBackgroundColor)
                        .foregroundColor(statusColor)
                        .cornerRadius(6)

                    // Title
                    Text(check.status.displayTitle)
                        .font(.system(size: 24, weight: .bold))
                }
            }

            // Checks list
            VStack(alignment: .leading, spacing: 12) {
                ForEach(check.checks) { checkItem in
                    HStack(alignment: .top, spacing: 12) {
                        Text(checkItem.icon)
                            .font(.system(size: 20))

                        Text(checkItem.message)
                            .font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Recommendation box
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("💡")
                        .font(.system(size: 20))
                    Text("RECOMMENDATION")
                        .font(.system(size: 12, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundColor(.secondary)
                }

                Text(check.recommendation)
                    .font(.system(size: 14))
                    .lineSpacing(4)
            }
            .padding(20)
            .background(recommendationBackgroundColor)
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        }
        .padding(28)
        .background(backgroundGradient)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(statusColor, lineWidth: 2)
        )
        .cornerRadius(14)
    }

    // MARK: - Styling Helpers

    private var statusColor: Color {
        switch check.status {
        case .safe: return Color(hex: "#34c759")
        case .caution: return Color(hex: "#ff9500")
        case .warning: return Color(hex: "#f5a623")  // Yellow/amber instead of red
        case .unknown: return .gray
        }
    }

    private var badgeBackgroundColor: Color {
        statusColor.opacity(0.15)
    }

    private var recommendationBackgroundColor: Color {
        colorScheme == .dark ? Color(hex: "#1c1c1e") : Color.white
    }

    private var backgroundGradient: LinearGradient {
        let isDark = colorScheme == .dark

        switch check.status {
        case .safe:
            return LinearGradient(
                colors: isDark
                    ? [Color(hex: "#1a3a24"), Color(hex: "#0f2817")]
                    : [Color(hex: "#e8f8ed"), Color(hex: "#d4f4dd")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .caution:
            return LinearGradient(
                colors: isDark
                    ? [Color(hex: "#3a2f1a"), Color(hex: "#2d2414")]
                    : [Color(hex: "#fff8e6"), Color(hex: "#fff5d6")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .warning:
            return LinearGradient(
                colors: isDark
                    ? [Color(hex: "#3a321a"), Color(hex: "#2d2714")]
                    : [Color(hex: "#fff9e6"), Color(hex: "#fff3cc")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .unknown:
            return LinearGradient(
                colors: isDark
                    ? [Color(hex: "#2c2c2e"), Color(hex: "#1c1c1e")]
                    : [Color(hex: "#f5f5f7"), Color(hex: "#e5e5e7")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

#Preview("Changes Detected") {
    StatusHeroSection(check: GitSafetyCheck(
        status: .caution,
        checks: [
            .init(icon: "✓", message: "Branch unchanged — still on main", passed: true),
            .init(icon: "📝", message: "New commits detected since session start", passed: false),
            .init(icon: "📝", message: "26 uncommitted changes in working tree", passed: false)
        ],
        recommendation: "Review uncommitted changes before resuming. The agent may conflict with your work in progress. Consider committing or stashing changes first."
    ))
    .padding()
    .frame(width: 800)
}

#Preview("Safe") {
    StatusHeroSection(check: GitSafetyCheck(
        status: .safe,
        checks: [
            .init(icon: "✓", message: "Branch unchanged — still on main", passed: true),
            .init(icon: "✓", message: "No new commits since session start", passed: true),
            .init(icon: "✓", message: "Working tree is clean", passed: true)
        ],
        recommendation: "No changes detected. Safe to resume this session."
    ))
    .padding()
    .frame(width: 800)
}

#Preview("Conflict Risk") {
    StatusHeroSection(check: GitSafetyCheck(
        status: .warning,
        checks: [
            .init(icon: "⚠️", message: "Branch changed: main → feature/new-work", passed: false),
            .init(icon: "📝", message: "New commits detected since session start", passed: false),
            .init(icon: "✓", message: "Working tree is clean", passed: true)
        ],
        recommendation: "Git state has changed significantly. Review changes carefully and ensure you're on the correct branch before resuming."
    ))
    .padding()
    .frame(width: 800)
}
