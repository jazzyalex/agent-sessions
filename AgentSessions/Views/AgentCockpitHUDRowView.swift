import SwiftUI

struct AgentCockpitHUDRowView: View {
    let row: HUDRow
    let rowNumber: Int
    let isSelected: Bool
    let filterText: String
    let isGrouped: Bool
    let isCompact: Bool
    let onTap: () -> Void
    @AppStorage(PreferencesKey.Cockpit.hudShowAgentNameInCompact) private var showAgentNameInCompact: Bool = true
    @AppStorage(PreferencesKey.Cockpit.showTabSubtitleInFullMode) private var showTabSubtitleInFullMode: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Text("\(rowNumber)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(isSelected ? 0.9 : 0.65))
                    .frame(width: 22, alignment: .center)

                AgentCockpitHUDStatusDot(
                    liveState: row.liveState,
                    lastSeenAt: row.lastSeenAt
                )
                .accessibilityLabel(row.liveState == .active ? "Active" : "Idle")

                if !isCompact || showAgentNameInCompact {
                    agentLabelBlock
                }

                if !isGrouped {
                    highlightedText(row.projectName)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 165, alignment: .leading)
                }

                Text(row.preview)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(previewColor)
                    .lineLimit(isCompact ? 1 : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: !isCompact)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isCompact {
                    Text(row.elapsed)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(elapsedColor)
                        .lineLimit(1)
                        .frame(width: 32, alignment: .trailing)
                        .help(row.lastActivityTooltip ?? "Last activity unavailable")
                }

                if !isCompact {
                    if let shortcutLabel {
                        Text(shortcutLabel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? Color.primary.opacity(0.84) : Color.secondary.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(width: 56)
                            .background(Color.primary.opacity(isSelected ? 0.12 : 0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(isSelected ? 0.20 : 0.10), lineWidth: 0.5)
                            )
                    } else {
                        Color.clear
                            .frame(width: 56, height: 20)
                    }
                }
            }
            .padding(.leading, isGrouped ? 24 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(row.liveState == .idle ? 0.60 : 1.0)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.leading, isGrouped ? 24 : 12)
            }
        }
        .buttonStyle(.plain)
    }

    private var shortcutLabel: String? {
        if isSelected { return "↩" }
        guard (1...9).contains(rowNumber) else { return nil }
        return "⌘\(rowNumber)"
    }

    @ViewBuilder
    private var agentLabelBlock: some View {
        if isCompact {
            agentBadge
                .frame(width: 64, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                agentBadge
                if showTabSubtitleInFullMode, let tabTitle = normalizedTabTitle {
                    Text(tabTitle)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(elapsedColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(tabTitle)
                }
            }
            .frame(width: 148, alignment: .leading)
        }
    }

    private var normalizedTabTitle: String? {
        guard let raw = row.tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private var previewColor: Color {
        if colorScheme == .dark {
            return row.liveState == .active ? Color(hex: "8e8e93") : Color(hex: "636366")
        }
        return row.liveState == .active ? Color(hex: "6e6e73") : Color(hex: "aeaeb2")
    }

    private var elapsedColor: Color {
        colorScheme == .dark ? Color(hex: "6e6e73") : Color(hex: "8e8e93")
    }

    private var agentBadge: some View {
        let style = row.agentType.badgeStyle(for: colorScheme)
        return Text(row.agentType.label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(style.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(style.background)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(style.border, lineWidth: 0.75)
            )
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
            return Color.primary.opacity(0.055)
        }
        return .clear
    }
}

private struct AgentCockpitHUDStatusDot: View {
    let liveState: HUDLiveState
    let lastSeenAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: 7, height: 7)
            .scaleEffect(scale)
            .opacity(opacity)
            .shadow(color: haloColor.opacity(haloOpacity), radius: haloRadius)
            .onAppear { updateAnimation() }
            .onChange(of: liveState) { _, _ in updateAnimation() }
            .onChange(of: lastSeenAt) { _, _ in updateAnimation() }
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private var baseColor: Color {
        switch liveState {
        case .active:
            return Color(hex: "30d158")
        case .idle:
            return idleBaseColor
        }
    }

    private var idleBaseColor: Color {
        colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
    }

    private var shouldPulse: Bool {
        liveState == .idle && !reduceMotion
    }

    private var scale: CGFloat {
        guard shouldPulse else { return 1.0 }
        return animate ? 1.25 : 1.0
    }

    private var opacity: Double {
        guard shouldPulse else { return 1.0 }
        return animate ? 1.0 : 0.88
    }

    private var fillColor: Color {
        baseColor
    }

    private var haloColor: Color {
        idleBaseColor
    }

    private var haloOpacity: Double {
        guard liveState == .idle else { return 0 }
        guard shouldPulse else { return 0 }
        return animate ? 0.65 : 0.22
    }

    private var haloRadius: CGFloat {
        guard liveState == .idle else { return 0 }
        guard shouldPulse else { return 0 }
        return animate ? 4.8 : 3.2
    }

    private func updateAnimation() {
        guard shouldPulse else {
            animate = false
            return
        }
        animate = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            animate = true
        }
    }
}
