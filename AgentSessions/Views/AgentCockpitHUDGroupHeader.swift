import SwiftUI

struct AgentCockpitHUDGroupHeader: View {
    let projectName: String
    let activeCount: Int
    let idleCount: Int
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
                    Text("\(activeCount) active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "30d158"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(hex: "30d158").opacity(colorScheme == .dark ? 0.18 : 0.12))
                        .clipShape(Capsule())
                }

                if idleCount > 0 {
                    Text("\(idleCount) waiting")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600"))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            (colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600"))
                                .opacity(colorScheme == .dark ? 0.16 : 0.12)
                        )
                        .clipShape(Capsule())
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
}
