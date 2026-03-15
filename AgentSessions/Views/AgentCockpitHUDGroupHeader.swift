import SwiftUI

struct AgentCockpitHUDGroupHeader: View {
    let projectName: String
    let activeCount: Int
    let idleCount: Int
    let isStaleOnly: Bool
    let isCollapsed: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(projectName.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .help(projectName)

                if activeCount > 0 {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: "30d158"))
                            .frame(width: 7, height: 7)
                        Text("\(activeCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: "30d158"))
                    }
                }

                if idleCount > 0 {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(waitingDotColor)
                            .frame(width: 7, height: 7)
                        Text("\(idleCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(waitingDotColor)
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var waitingDotColor: Color {
        let base = colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
        return isStaleOnly ? base.opacity(0.5) : base
    }
}
