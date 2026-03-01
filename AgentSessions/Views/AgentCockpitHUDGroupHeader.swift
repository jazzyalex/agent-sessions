import SwiftUI

struct AgentCockpitHUDGroupHeader: View {
    let projectName: String
    let summary: String
    let hasActive: Bool
    let isCollapsed: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(projectName.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary.opacity(0.9))

                Text(summary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hasActive ? Color.green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((hasActive ? Color.green : Color.secondary).opacity(0.12))
                    .clipShape(Capsule())

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
}
