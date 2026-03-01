import SwiftUI

struct AgentCockpitHUDRowView: View {
    let row: HUDRow
    let rowNumber: Int
    let isSelected: Bool
    let filterText: String
    let isGrouped: Bool
    let onTap: () -> Void
    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Text("\(rowNumber)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.65))
                    .frame(width: 22, alignment: .center)

                AgentCockpitHUDStatusDot(liveState: row.liveState)
                    .frame(width: 9, alignment: .center)
                    .accessibilityLabel(row.liveState == .active ? "Active" : "Idle")

                Text(row.agentType.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(row.agentType.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(row.agentType.background)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(row.agentType.tint.opacity(0.22), lineWidth: 0.5)
                    )

                highlightedText(row.projectName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 165, alignment: .leading)

                Text(row.preview)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(row.liveState == .active ? Color.secondary : Color.secondary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.elapsed)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 40, alignment: .trailing)

                if let shortcutLabel {
                    Text(shortcutLabel)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(width: 56)
                        .background(Color.primary.opacity(isSelected ? 0.10 : 0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(isSelected ? 0.22 : 0.10), lineWidth: 0.5)
                        )
                } else {
                    Color.clear
                        .frame(width: 56, height: 20)
                }
            }
            .padding(.leading, isGrouped ? 24 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(row.liveState == .idle ? 0.55 : 1.0)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.leading, isGrouped ? 24 : 12)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var shortcutLabel: String? {
        if isSelected { return "↩" }
        guard (1...9).contains(rowNumber) else { return nil }
        return "⌘\(rowNumber)"
    }

    private func highlightedText(_ text: String) -> Text {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Text(text)
        }

        guard let swiftRange = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(text)
        }

        let prefix = String(text[..<swiftRange.lowerBound])
        let match = String(text[swiftRange])
        let suffix = String(text[swiftRange.upperBound...])

        return Text(prefix)
            + Text(match).bold().foregroundColor(.accentColor)
            + Text(suffix)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.09)
        }
        if isHovering {
            return Color.primary.opacity(0.035)
        }
        return .clear
    }
}

private struct AgentCockpitHUDStatusDot: View {
    let liveState: HUDLiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(liveState == .active ? Color.green : Color.secondary.opacity(0.55))
            .frame(width: 7, height: 7)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear { updateAnimation() }
            .onChange(of: liveState) { _, _ in updateAnimation() }
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private var scale: CGFloat {
        guard liveState == .active, !reduceMotion else { return 1.0 }
        return animate ? 1.35 : 1.0
    }

    private var opacity: Double {
        guard liveState == .active, !reduceMotion else { return 1.0 }
        return animate ? 0.75 : 1.0
    }

    private func updateAnimation() {
        guard liveState == .active, !reduceMotion else {
            animate = false
            return
        }
        animate = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            animate = true
        }
    }
}
